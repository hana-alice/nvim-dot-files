# Android DAP session-time live breakpoints · 架构决策记录 (ADR)

> 日期: 2026-06-15
> 设备: **仅在 `ANDROID-SERIAL-B` 上验证**（`<android-package>`, arm64-v8a, Android, SELinux Enforcing）
> 路线: K30 platform 模式 + serial-form `connect://[<serial>]:<port>`（宪法级，见 CONSTRAINTS K30）
> 关联 change: `openspec/changes/archive/2026-06-15-android-dap-live-breakpoints/`
> 关联代码: `lua/ue/dap.lua`、`lua/ue/dap/android.lua`
> 关联约束: CONSTRAINTS K33/K34（成功判据 + source-file 崩溃复验）、**K36**（live 正解）、**K37**（slide load-bearing）
> 证据: `tools/evidence/android-f9/livebp-gate.*.json`、`livebp-e2e.result.json`、`noslide-preseed.result.json` vs `slide-recheck.result.json`

---

## 0. 一句话结论

会话中（attach 完成、`configurationDone` 之后）按 F9 新增/修改的 file:line 断点，**经
lldb-dap evaluate backtick `breakpoint set -f/-l` 通道即时下发即可 resolve 并命中**——
在当前 K30 platform route + 3.5 匹配符号下经真机闸门 + 端到端实证。历史
`361b9e7` 记录的「attach 后写断点被内核静默丢弃、session-time live 物理不可行」是**旧
gdb-remote 直连路线/旧符号的观测，不适用当前路线**。因此「会话中改断点必须
`:UEDAPReattach` 重连」的 work around 被**删除**，live 通道是正解（非 workaround，放主逻辑）。

---

## 1. 背景与问题

UE Android 调试此前**唯一能命中**的断点路径是 attach-time preseed：
`preseed_breakpoints_into_attach_commands`（`android.lua`）把当前 nvim 断点转成
`?breakpoint set -f "<basename>" -l <line>` 烤进 `attachCommands`，在 `configurationDone`
之前、进程恢复之前一次性植入。会话开始后再按 F9 只更新 nvim-dap 本地表，经 DAP
`setBreakpoints` 到达 lldb-dap，后者回 `verified=true` 但**永不命中**——只能弹 warning 让用户
`:UEDAPReattach` 重连整个会话。

历史上试过「3s 防抖 detach+reattach」伪即时（commit `361b9e7`/`33fb69b`/`32c156f`），它
偷偷重连整个会话掩盖了 attach-time preseed 与 session-time 变更的本质区别，已被推翻为
诚实-warning。用户要求**消除 work around 回到根因解**。但根因解是否存在，取决于一个尚未
在当前路线复验的物理问题：**attach 后能不能把断点指令真正写进进程内存**。

---

## 2. 决策

### D1（方法论）：先做「可行性闸门」真机实验，再写实现代码

在写任何 live 下发代码前，先用受控实验确定可行性：attach（不 preseed 目标断点）→ continue
过 entry SIGSTOP burst → 等 app 进入稳定 render state → 经通道各试一次，记录
`breakpoint list resolved` + 是否命中 + adapter 是否存活。

- **通道 A**：DAP `setBreakpoints`（nvim-dap native）。
- **通道 B**：evaluate backtick `breakpoint set -f/-l`（lldb-dap 把 backtick 当 raw 命令）。
- **通道 C**：`image lookup --line` → `breakpoint set --address`（备用，需证源行语义等价）。

*Why over 直接写实现*：K33/K34/`361b9e7` 都警告过「碰巧不崩 / UI 变绿」的假象。先拿判据再写
码，避免第三次落入同一陷阱。

**闸门结论（2026-06-15 真机）**：通道 A 与 B **均命中**（`resolved=1`、`reason="breakpoint"`、
`adapter_alive`，无 `3221226505`）。→ live 可行，走 2A 分支。证据
`livebp-gate.evaluate.result.json` / `livebp-gate.setbreakpoints.result.json`。

### D2：live 通道优先级 evaluate(B) → DAP(A) → address(C)

优先 evaluate 命令通道：它复用 attach-time preseed 已验证的 file:line + basename 形态
（`ue_android_breakpoint_source` 重写），语义最接近「已知能 resolve 的路径」，且 evaluate
结果文本携带 `resolved=N`，可作为**诚实 verified 信号**回读。DAP setBreakpoints（A）作为
nvim-dap 原生 fallback。address（C）未启用（A/B 均命中）。

### D3：preseed 降级而非删除

`preseed_breakpoints_into_attach_commands` 保留为「会话前初始快照」（stopOnEntry 窗口内
进程恢复前就位的正确机制）。会话中变更走 live。判定边界复用
`session._ue_android_configuration_done`：
- gate 之前的 setBreakpoints = 初始 sync（已 preseed，不重复下发）。
- gate 之后的 setBreakpoints = live 下发（走 D2 通道，**取代** warning）。

### D4：`verified` 必须诚实

live 下发后回读 `breakpoint list` 的 `resolved=N`；`resolved=0` 或命令报错 →
`vim.notify` 给可定位反馈（命令未发 / pending / 路径不匹配 / adapter 退出），节流复用
`D._ue_android_bp_notice_until_ms`。**MUST NOT 假成功、MUST NOT detach+reattach 伪装即时。**

### D5（被否决）：删除冗余 ASLR slide

design 原假设 `target modules load --slide` 冗余（旧注释「5/22 无 slide 也 resolved，
`target create`+platform attach 自动重定位」）。**真机复验否决**：`UE_DAP_NO_SLIDE=1`
跳过 slide 时 attach 在 `android_attach_start` 后即超时 / adapter 早退 `3221226505`、从不
命中；紧随的 slide-present baseline 立即命中。→ **slide 在本设备 load-bearing，保留**
（CONSTRAINTS K37）。新增 `UE_DAP_NO_SLIDE` 开关供后续在其他设备/版本复验。

### D-OQ5：合成帧三绕路收敛到 stackTrace 层

三处防御同一 nvim-dap 上游缺陷（`jump_to_frame` 不尊重 `preserveFocusHint`/
`threadCausedFocus`、对 `line=0`+`sourceReference` 喂坐标 → `E474` / `dap-src://`）：
- **chokepoint** = `before.stackTrace["ue_source_path_rewrite"]`（在 nvim-dap 内建
  `event_stopped` 消费 stackTrace 之前把合成帧置 `line=-1` 占位，源头掐断坏跳转）。
- 薄 defence-in-depth = `_frame_set` monkey-patch（兜手动切帧绕过 rewrite 的稀有路径）。
- 正交 = setBreakpoints 响应 basename→local-path remap（改的是断点标记 source，不是 stop frame）。

三处共用 `frame_is_synthetic_or_invalid` 分类器，代码内 `ANCHOR(ue-synthetic-frame-guard)`
+ `ANCHOR-USE:*` 交叉标注。彻底删除依赖上游修复，超出本仓范围。

---

## 3. 实现要点（防腐蚀的关键不变量）

| 不变量 | 出处 | 测试守护 |
|---|---|---|
| live 命令用 basename 形态（与 preseed 一致） | `ue_android_live_plant_command` | dap_spec「live-plant command uses the proven basename form」 |
| `resolved>0` 是唯一诚实 verified 信号 | `scan_breakpoint_resolved` | dap_spec「resolved-parser is the honest-verified signal」 |
| nvim-dap `before.setBreakpoints` 在**响应**管线触发，无 before-request hook | nvim-dap `session.lua handle_body` | dap_spec「INVARIANT: ... RESPONSE pipeline」 |
| live plant 不假成功、不 detach+reattach | `ue_android_live_plant_via_evaluate` | dap_spec「INVARIANT: live plant never fakes success」 |
| ASLR slide load-bearing + `UE_DAP_NO_SLIDE` reverify 开关 | `android.lua` attach_commands | dap_spec「INVARIANT: explicit ASLR slide stays load-bearing」 |
| 合成帧收敛单 chokepoint + ANCHOR 交叉标注 | `dap.lua` 三处 | dap_spec「synthetic-frame guards converge」 |

---

## 4. 踩过的坑（写实现时真实付出的成本）

1. **nvim-dap 没有 before-request hook**：`listeners.before.setBreakpoints` 在
   `handle_body` 的响应管线触发（签名 `session, err, response, request, seq`），**不能**改
   outgoing `args.source`。原 `ue_android_bp_source_rewrite` 命名误导；wire 侧 basename 匹配
   由 attachCommands + DWARF 负责。恢复请求行须读 `request` payload（`message_requests[seq]`），
   它同时传给 before/after 两个 listener。改名为 `ue_android_bp_record_request`。
2. **闸门 ≠ 接通**：D1 闸门用自己的通道代码下发，闸门绿不代表**接线后的生产 listener**生效。
   首次 E2E 跑出 `line_count=0`（从错误字段恢复），加 `request`-payload 恢复后才到
   `production_live_plant_diag=true`。故另写 `livebp-e2e.lua` 驱动真实 F9 流
   （`dap.breakpoints.set` + `session:set_breakpoints`）并断言 `saw_reattach_warning=false`。
3. **teardown 的 `3221226505` 是预期**：disconnect 时 lldb-dap 退出会报这个码；它**不是** K34
   崩溃——`adapter_alive=true` 在 teardown 前采样，断点命中先于它。
4. **设备残留致 D5 假阴性**：stray `lldb-server` + 累积 `adb forward` 会让 no-slide 误超时；
   D5 测量前须 `pkill -f lldb-server` + `adb forward --remove-all` 清场。

---

## 5. 被否决/不做的方案

- **自动 detach+reattach 伪即时**（`361b9e7` 系）：掩盖真相的 work around，永久禁止。
- **删除冗余 ASLR slide**（D5）：真机复验否决，slide load-bearing。
- **address 通道（C）作为主路**：A/B 均命中，C 无需启用；address 还需证源行语义等价 + ASLR
  漂移每次重算，复杂度更高。
- **删除合成帧三绕路本身**：依赖 nvim-dap 上游修复 `jump_to_frame`，超出本仓范围；本 change
  范围内只收敛 + 标注。

---

## 6. 回滚点

阶段 0 清理（死代码 / no-op / 注释 / 合成帧收敛）独立可 revert。live 接通若在其他设备回归
不过，回到诚实-warning（即本 change 之前的 working tree 状态）是零风险回滚点——但注意：在
**本设备** `ANDROID-SERIAL-B` 上 live 已实证可行，回滚意味着退回到更差的 UX，仅在新设备证伪 live 时
才考虑。
