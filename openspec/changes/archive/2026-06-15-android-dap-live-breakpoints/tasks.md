# Tasks: android-dap-live-breakpoints

## 1. 阶段 0 — 无条件清理（不依赖真机，先做）

- [x] 1.1 删除死代码 `lua/ue/dap/_common.lua:137-142` 的 `if false and …` 分支；若该分支只为强制刷新 `LLDBDAP_LOG`，改成真实的 env-refresh 逻辑并加注释说明。
- [x] 1.2 修复 `lua/ue/dap/_persist_bp.lua:151-156` 的空参 `set_breakpoints({ [bufnr] = nil })` no-op：要么真正推送已恢复断点、要么删除该 pcall，并对齐注释与实际行为。
- [x] 1.3 修正 `lua/ue/dap.lua:1846-1851` `dap.terminate` monkey-patch 的过时注释（"launch" → "attach"，对齐 `android.lua:1049` 的 `request="attach"`）。
- [x] 1.4 跑 `nvim --headless -l tests/run.lua dap` 确认上述清理不破坏现有断言。

## 2. 阶段 0 — 合成帧三绕路收敛 + 上游标注

- [x] 2.1 梳理三处防御同一上游缺陷的绕路：`dap.lua:2060-2109` 的 stackTrace `line=-1` 占位、`dap.lua:1872-1887` 的 `_frame_set` monkey-patch、`dap.lua:151-162` 的 basename 响应 remap；在代码与 design 注释中标注它们防的同一个 nvim-dap 根因（`jump_to_frame` 对 `line=0`+`sourceReference` 的处理 / 未尊重 `threadCausedFocus`）。
- [x] 2.2 在不改外部行为的前提下，把合成帧防御收敛到单一 chokepoint（design D-OQ5 决定 stackTrace 层还是 `_frame_set` 层），保留另两处为薄转发或删除冗余层。
- [x] 2.3 确认 `tests/cases/dap_spec.lua` 现有合成帧断言（`copy.line = -1`、`<synthetic>` 名）仍通过；按收敛结果更新断言指向。
- [x] 2.4 跑 `nvim --headless -l tests/run.lua dap`。

## 3. 阶段 1 — live 可行性闸门实验（需真机 ANDROID-SERIAL-B）

- [x] 3.1 扩展 `tools/nvim_android_dap_smoketest.lua`：支持 attach 后（continue 之后）在活跃会话经三通道各下发一次断点并采集结果（通道 A=DAP setBreakpoints / B=evaluate backtick `breakpoint set -f/-l` / C=image lookup→breakpoint set --address）。【实现为独立闸门 harness `tools/nvim_android_dap_livebp_gate.lua`，由 `NVIM_DAP_LIVEBP_CHANNEL` 选通道；smoketest 也补了 image lookup / address 采集 plumbing】
- [x] 3.2 真机跑闸门实验，目标 `MobileShadingRenderer.cpp:1367`，匹配 3.5 符号；每通道记录 `breakpoint list resolved`、是否命中 `reason="breakpoint"`、adapter 是否存活（无 `3221226505`），落 `tools/evidence/android-f9/live-bp-gate.*.json`。【证据：`livebp-gate.evaluate.result.json` / `livebp-gate.setbreakpoints.result.json`】
- [x] 3.3 判定闸门结论：A/B 命中 → live 可行；全失败但 resolved=1 → 确认 `361b9e7` 的 "memory write silently dropped"，session-time 物理不可行；仅 C 命中 → address 是唯一 live 解。把结论写入 design.md Open Questions #1 的解答。【结论：A+B 均命中 → live 可行，走 2A 分支；已写入 design.md OQ#1/#2】

## 4. 阶段 2A — live 可行分支（仅当闸门证明可行）

- [x] 4.1 实现 live 下发 helper：复用 `current_breakpoint_commands` 的 file:line + basename 形态，按 design D2 优先级（B→A→C）选通道；放入主逻辑（非 workarounds，因为是正解）。【`ue_android_live_plant_via_evaluate`，复用 `ue_android_breakpoint_source` basename 形态，evaluate backtick 通道(B)】
- [x] 4.2 改 `dap.lua` 的 `after.setBreakpoints["ue_android_bp_local_response"]`：`configurationDone` 之后的 setBreakpoints 改为经 live 通道下发，**取代** warning；保留 `ue-dap-bp-diag.log` 真实响应记录。
- [x] 4.3 删除 active-session F9 warning（`dap.lua:2031-2044`）与其专属节流 `D._ue_android_bp_notice_until_ms`；保留 configurationDone gate 仅用于区分初始 sync vs live 下发。【warning 已删；`_ue_android_bp_notice_until_ms` 复用为 live 失败诚实反馈的节流（仅失败时触发，非"会话中变更"警告）】
- [x] 4.4 确保 `verified` 反映真实 LLDB 状态：live 下发后回读 `breakpoint list resolved`，失败回 `verified=false` 且给可定位反馈，MUST NOT 假成功、MUST NOT detach+reattach。【live plant 回读 `breakpoint list` 的 `resolved=N`；resolved=0 或命令报错 → vim.notify 诚实反馈，不 detach+reattach】
- [x] 4.5 真机验证会话中新增断点即时命中、会话中删除断点即时移除、live 失败诚实反馈（对应三条 spec scenario）。【真机 `ANDROID-SERIAL-B` 跑 `tools/nvim_android_dap_livebp_e2e.lua` 驱动真实 F9 流：`production_live_plant_diag=true`、`saw_reattach_warning=false`、`breakpoint list resolved=1`、`stop.reason="breakpoint"` hit；证据 `livebp-e2e.result.json`】

## 5. 阶段 2A — 冗余 ASLR slide 删除（仅当 D5 复验通过）

- [x] 5.1 真机复验一次**不下发** `target modules load --slide`，确认 `breakpoint list resolved=1` 且命中（design D5 前置条件）。【真机 `ANDROID-SERIAL-B` 跑 `UE_DAP_NO_SLIDE=1` ×3（含设备清场）：不下发 slide → attach 超时/adapter `3221226505`、从未命中；slide-present baseline 立即命中。证据 `noslide-preseed.result.json`(timeout) vs `slide-recheck.result.json`(ok)】
- [~] 5.2 复验通过则删除 `android.lua:923-932` 的 slide 追加，并清理 `read_so_base_hex`、`module_rebase_command`、`_module_rebase_cmd`、`_finalize_session` 内 base 解析 plumbing。【**复验未通过 → 不删除**。slide 在本设备 load-bearing；仅新增 `UE_DAP_NO_SLIDE` 复验开关供后续在其他设备/版本再验。design OQ#3 已记结论】
- [~] 5.3 跑 `nvim --headless -l tests/run.lua dap`，补/改断言反映 slide 已移除。【N/A — slide 未移除；保留现有 slide 相关断言不变】

## 6. 阶段 2B — live 不可行分支（仅当闸门证明不可行）

> **N/A — 闸门证明 live 可行（见 §3.3 / design OQ#1），走 2A 分支，2B 整段不适用。**

- [~] 6.1 在 `docs/CONSTRAINTS.md` §二新增 K 条目：本设备/Android 版本 attach 后内核拒绝写断点指令，session-time live 断点物理不可行（含闸门证据指针）。【N/A — live 可行，反结论不成立】
- [~] 6.2 `openspec/changes/android-dap-live-breakpoints/specs/android-dap-live-breakpoints/spec.md` 标注 live 需求"受平台限制不适用本设备"，诚实-warning 升格为正解（非 work around）。【N/A — live 可行，spec 需求成立】
- [~] 6.3 保留 attach-time preseed 为初始路径 + 诚实-warning + `:UEDAPReattach` 为会话中变更的明确手段。【部分保留：preseed 仍为初始路径（D3），但会话中变更已走 live 通道，warning 已删除（4.3）】

## 7. spec / 文档 / 回归收尾

- [x] 7.1 同步 `openspec/specs/android-dap-attach/spec.md`（按本 change 的 MODIFIED delta），与最终落地分支一致。【新增「会话中 F9 变更经 live 通道即时下发」需求 + 两条 scenario，与 2A 落地一致】
- [x] 7.2 `docs/CONSTRAINTS.md` / `docs/TOOLING.md` 更新 K33/K34 状态与 live 路径结论。【K34 标注当前路线不复现崩溃；新增 K36（live 可行正解）、K37（slide load-bearing）；TOOLING 会话中 F9 段改为 live 通道描述】
- [x] 7.3 `docs/changelog.md` Unreleased 追加条目，Validation 写明所跑回归范围、闸门结论与真机结果。
- [x] 7.4 提交/合并前跑全量 `nvim --headless -l tests/run.lua` 全绿。【369/369 passed】
- [x] 7.5 跑 `openspec validate android-dap-live-breakpoints` 通过。【Change is valid】
