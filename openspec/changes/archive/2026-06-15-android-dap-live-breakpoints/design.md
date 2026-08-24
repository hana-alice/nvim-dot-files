# Design: android-dap-live-breakpoints

## Context

UE Android DAP 调试当前**唯一能命中**的断点路径是 attach-time preseed：
`preseed_breakpoints_into_attach_commands`（`android.lua:1021-1044`）把当前 nvim 断点
转成 `?breakpoint set -f "<basename>" -l <line>` 烤进 `attachCommands`，在
`configurationDone` 之前、进程恢复之前一次性植入。会话开始后再按 F9 只更新 nvim-dap
本地表，经 DAP `setBreakpoints` 到达 lldb-dap，后者回 `verified=true`，但断点
**永不命中**——`dap.lua:2031-2044` 的诚实-warning 明确告诉用户必须 `:UEDAPReattach`。

历史上试过两种"即时"做法（commit `361b9e7`/`33fb69b`/`32c156f`）：3s 防抖
detach+reattach。它"看起来"即时，实则偷偷重连整个会话，掩盖了 attach-time preseed 与
session-time 变更的本质区别，已在 working tree 被推翻为诚实-warning（见
`fix-android-f9-breakpoint-hit` change）。

`361b9e7` 的 commit message 记录了一个关键观测（需复验）：
> lldb-server on this device/Android-version cannot reliably write breakpoint
> instructions into process memory after the attach sequence completes — whether
> via DAP setBreakpoints or evaluate-based replant. Both resolve symbols
> correctly (verified=true, resolved=1) but the memory write is silently dropped.

若该观测在当前 K30 platform route + 3.5 匹配符号下仍成立，则"会话中即时下断点"在本
设备**物理上不可行**，本 change 的根因解可能不存在——必须先证伪/证实这一点，再决定
方向。这是 design 的头号 open question，也是整个 change 的成立前提。

约束（来自 `docs/CONSTRAINTS.md`）：
- K30：platform 模式 + serial-form connect URL 是唯一 attach 正解。
- K33：`breakpoint set -f` 可能崩溃 lldb-dap 22.1.6（`3221226505`），需按路线复验。
- K34/K35：必须先 `target create <symbol-rich libUE4.so>` 再 attach。
- P4/C2：work around 必须隔离到 `lua/workarounds/`；但本 change 的目标是**消除** work
  around 改正解，正解放主逻辑（C2 "何时不该隔离"）。
- host adapter 维持 LLVM 22.1.6+ forward-only；真机仅 `ANDROID-SERIAL-B`。

## Goals / Non-Goals

**Goals:**
- 用真机证据**确定** session-time `breakpoint set` 在当前路线下是否可行（头号目标）。
- 若可行：接通 live 通道，F9 运行时即时 resolve + 命中，删除 reattach warning + gate。
- 若不可行：诚实记录"本设备 attach 后无法写断点"为平台约束（K 条目），保留诚实-warning
  作为**正解**（不是 work around，是物理限制的诚实暴露），并把精力转向清理其余可移除绕路。
- 无条件清理：冗余 ASLR slide、死代码 `if false`、`_persist_bp` 空参 no-op、过时注释。
- 收敛三处合成帧绕路到单一 chokepoint 并标注上游根因。

**Non-Goals:**
- 不实现"自动 detach+reattach"伪即时（已证为掩盖真相的 work around，永久禁止）。
- 不删除确属 load-bearing 的项（terminate→detach、step 防护、stopOnEntry、
  auto_continue 标志、env 数组化、source-map 去重）。
- 不强求删除合成帧绕路本身（删除依赖 nvim-dap 上游修复，超出本仓范围）。
- 不改 host adapter 版本、不引入新依赖。

## Decisions

### D1：先做"可行性闸门"真机实验，再写实现代码

在写任何 live 下发代码前，先用 `tools/nvim_android_dap_smoketest.lua` 的扩展跑一个
受控实验：attach（不 preseed 目标断点）→ continue → 会话中经三种通道各试一次，记录
`breakpoint list resolved` + 是否命中 + adapter 是否存活：

1. **通道 A — DAP `setBreakpoints`**：`dap.session():set_breakpoints()` 在 live 会话发。
2. **通道 B — evaluate 命令**：`dap.session():request("evaluate", {expression="`breakpoint set -f ... -l ...", context="repl"})`（lldb-dap backtick = command）。
3. **通道 C — address 断点**：先 `image lookup --file <f> --line <n>` 取 runtime address，再 `breakpoint set --address 0x...`。

闸门结论决定后续：A/B 任一命中 → live 路径成立（选不崩的那条）；全失败但 resolved=1 →
确认 `361b9e7` 的"memory write silently dropped"，session-time 物理不可行；C 命中而 A/B
不中 → address 通道是唯一 live 解。

*Why over 直接写实现*：K33/`361b9e7` 都警告过"碰巧不崩/UI 变绿"的假象。先拿判据再写码，
避免第三次落入同一陷阱。

### D2：live 通道优先级 file:line(B) → DAP(A) → address(C)

若闸门证明可行，优先 evaluate 命令通道（B）下发 `breakpoint set -f/-l`：它复用 attach-time
preseed 已验证的 file:line 形态与 basename 重写逻辑（`current_breakpoint_commands` 可复用），
语义最接近"已知能 resolve 的路径"。DAP setBreakpoints（A）次之（受 basename 重写 + 响应
remap 双向变换牵制）。address（C）最后，因为它需要额外证明源行语义等价（K34），且 ASLR
slide 变动时需重算。

*Why*：复用已证可 resolve 的 file:line 形态，最小化新变量。

### D3：preseed 降级而非删除

`preseed_breakpoints_into_attach_commands` 保留为"会话前初始快照"。会话中变更走 live。
判定"会话是否已 configurationDone"复用现有 `session._ue_android_configuration_done` 标志：
- gate 之前的 setBreakpoints = 初始 sync（已 preseed，不重复下发）。
- gate 之后的 setBreakpoints = live 下发（走 D2 通道，**取代** warning）。

*Why over 全删 preseed*：attach 前已有断点仍需在进程恢复前就位（stopOnEntry 窗口），
preseed 是该窗口的正确机制；删了会丢初始断点。

### D4：清理项分"无条件"与"依赖闸门"两批

- **无条件**（不依赖闸门，纯去 work around，先做）：
  - 死代码 `_common.lua:137-142` `if false and …` → 删除或改成真实 env-refresh。
  - `_persist_bp.lua:151-156` 空参 `set_breakpoints({[bufnr]=nil})` → 删除（无效）或改真实推送。
  - `dap.terminate` monkey-patch 过时注释（"launch"→"attach"）→ 修正注释。
  - 合成帧三绕路（stackTrace `line=-1`、`_frame_set` patch、basename remap）→ 收敛 +
    标注上游 issue，不删功能。
- **依赖闸门**（live 成立后才做）：
  - 删 reattach warning + configurationDone gate 的 warning 分支。
  - 冗余 ASLR slide（`android.lua:923-932`）→ 真机确认自动重定位后删除 + 清 plumbing。

*Why 分批*：无条件项无风险可立即收益；依赖项必须等闸门，避免删了发现 live 不可行还得加回。

### D5：冗余 ASLR slide 的删除判据

`module_rebase_command` 注释（`android.lua:924-929`）自述"5/22 bp_truth.txt 无 slide 也
resolved，`target create`+platform attach 自动重定位"。删除前置条件：真机复验一次
**不下发** slide，确认 `breakpoint list resolved=1` 且命中。证实才删，连带清理
`read_so_base_hex`/`module_rebase_command`/`_module_rebase_cmd`/`_finalize_session` L1302-1316。

*Why*：注释是单次观测（5/22），删 load-bearing 嫌疑代码前要当前路线复验，不靠旧笔记。

## Risks / Trade-offs

- **[闸门证明 session-time 物理不可行]** → 这是最大风险但也是合法结论：把它记成 K 条目
  （"本设备 attach 后内核拒绝写断点指令"），诚实-warning 升格为正解。change 转向纯清理 +
  文档，spec 的 live 需求标注为"受平台限制不适用本设备"。不算失败，是用证据关掉一条死路。
- **[file:line 通道崩溃 lldb-dap（K33 复现）]** → 回退 address 通道（D2-C），且仅在语义等
  价被证明后采用。
- **[address 断点 ASLR 漂移]** → address 在 slide 变动时失效；address 通道须每次按当前
  runtime address 下发，不缓存跨 continue。
- **[删冗余 slide 后断点回退到错地址]** → D5 的真机复验是硬门槛；不复验不删。
- **[合成帧收敛引入 UI 回归]** → 收敛只合并 chokepoint 不改外部行为，dap_spec 现有合成帧
  断言（`line=-1`、`<synthetic>` 名）作为回归网；改动后必跑 `dap` filter。
- **[无真机时推进]** → 闸门与真机验证项无授权设备不得标完成；无机时只能落地 D4 无条件清理 +
  文档，spec 的 live 需求保持未验证状态。

## Migration Plan

1. **阶段 0（无机可做）**：D4 无条件清理 + 合成帧收敛 + 文档骨架。跑 `dap` + 全量回归。
2. **阶段 1（需真机）**：跑 D1 闸门实验，产出 `tools/evidence/android-f9/live-bp-gate.*.json`。
3. **阶段 2（分支）**：
   - live 可行 → 接通 D2 通道、删 warning/gate、按 D5 删冗余 slide、补 spec 验证。
   - live 不可行 → 记 K 条目、spec 标平台限制、保留 warning 为正解。
4. **回归门禁**：每阶段 `nvim --headless -l tests/run.lua dap`；提交前全量 +
   `openspec validate android-dap-live-breakpoints`。
5. **回滚**：阶段 0 改动独立可回滚（git revert）；阶段 2 live 接通若真机回归不过，回到
   阶段 0 状态 + 诚实-warning（已是当前 working tree 状态，零风险回滚点）。

## Open Questions

1. **（阻塞）** session-time `breakpoint set` 在当前 K30 route + 3.5 匹配符号下是否能写入
   并命中？`361b9e7` 说不能，但那是旧路线/旧符号的观测——必须 D1 闸门复验。
   **已解（2026-06-15 真机 `ANDROID-SERIAL-B` 闸门实验）：可行。** 目标
   `MobileShadingRenderer.cpp:1367`、3.5 匹配符号、attach 后 continue、不 preseed 目标断点，
   两条通道均 **命中**：
   - 通道 B（evaluate backtick `breakpoint set -f/-l`）：`live_plant_sent=true`、
     `resolved_after_plant=1`、`saw_breakpoint=true`、`stop.reason="breakpoint"`、
     `hitBreakpointIds=[1]`、`adapter_alive=true`（无 `3221226505`）。
     → `tools/evidence/android-f9/livebp-gate.evaluate.result.json`
   - 通道 A（DAP `setBreakpoints` live）：`saw_breakpoint=true`、`stop.reason="breakpoint"`、
     `hitBreakpointIds=[1]`、`adapter_alive=true`。
     → `tools/evidence/android-f9/livebp-gate.setbreakpoints.result.json`
   结论：**走 2A（live 可行）分支**。`361b9e7` 的 "memory write silently dropped" 在当前
   K30 platform route + 3.5 匹配符号下 **不复现**——那是旧 gdb-remote 直连路线/旧符号的观测。
   B 是首选通道（D2：复用已证可 resolve 的 file:line 形态、且 `resolved` 可从 evaluate
   结果文本回读）；A 作为 nvim-dap 原生 fallback。C（address）无需启用。
2. file:line 命令通道（D2-B）在当前 lldb-dap 22.1.6 是否复现 K33 崩溃？
   **已解：不复现。** 闸门 evaluate 通道 `adapter_alive=true`、无 `3221226505`/`0xC0000409`。
   K33 崩溃是旧 gdb-remote 直连 attach 路径的产物，K30 platform route 下安全。
3. 冗余 ASLR slide 是否真可删？（D5 复验）
   **已解：不删（证据不支持删除）。** 2026-06-15 真机 `ANDROID-SERIAL-B` 跑 `UE_DAP_NO_SLIDE=1`
   三次（含设备清场 `pkill lldb-server` + `adb forward --remove-all`），不下发
   `target modules load --slide` 时 attach 在 `android_attach_start` 后即超时、adapter
   早退 `3221226505`，从未到 `initialized`/命中；而紧随其后的 slide-present baseline
   立即命中（`slide-recheck.result.json` status=ok）。D5 的删除前置条件是「不下发 slide
   仍 `resolved=1` 且命中」——当前证据不满足，故 **保留** `module_rebase_command` /
   `read_so_base_hex` / `_module_rebase_cmd` plumbing，仅新增 `UE_DAP_NO_SLIDE` 复验开关
   备后续在不同设备/版本上再验。证据：`tools/evidence/android-f9/noslide-preseed.result.json`
   （timeout）vs `slide-recheck.result.json`（ok）。
4. evaluate backtick 命令通道的输出能否被现有 `event_output` 监听器可靠捕获以判定 resolved？
5. 合成帧三绕路收敛到哪个 chokepoint 最稳——stackTrace 响应层还是 `_frame_set` 层？
   **已解（D-OQ5）**：选 **stackTrace 响应层**（`before.stackTrace["ue_source_path_rewrite"]`）。
   理由：它在 nvim-dap 内建 `event_stopped` 消费 stackTrace 响应**之前**运行，把合成帧
   置为 `line=-1` 占位即可在源头掐断 `jump_to_frame` 的坏 UI 跳转，对所有下游消费者生效。
   `_frame_set` monkey-patch 与 setBreakpoints 响应 basename→local-path remap 降级为
   **薄 defence-in-depth**：前者只兜手动切帧绕过 stackTrace rewrite 的稀有路径，后者与帧
   逻辑正交（改的是 setBreakpoints 响应的 source path，不是 stop frame）。三处共用
   `frame_is_synthetic_or_invalid` 分类器，代码内以 `ANCHOR(ue-synthetic-frame-guard)` +
   `ANCHOR-USE:*` 交叉标注同一上游根因（nvim-dap `jump_to_frame` 不尊重
   `preserveFocusHint`/`threadCausedFocus` 且对 `line=0`+`sourceReference` 喂坐标）。
   彻底删除依赖上游修复，超出本仓范围。
