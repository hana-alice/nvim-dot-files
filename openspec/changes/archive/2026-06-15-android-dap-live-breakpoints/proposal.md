# Proposal: android-dap-live-breakpoints

## Why

UE Android 调试目前**唯一能命中**的断点路径是 attach 时把 `breakpoint set` 烤进
`attachCommands`（attach-time preseed）。一旦 attach 完成、会话进行中再按 F9，断点只
更新 nvim-dap 本地表，`lldb-dap` 返回 `verified=true` 却**永不命中**——系统只能弹
warning 让用户 `:UEDAPReattach` 重连整个会话。这套"重连才生效"是典型 work around：
它把"运行时下断点"这个最基本的调试动作降级成"重启调试器"。用户明确要求消除 work
around，回到根因解。除此之外，断点路径上还堆了一批互相重叠的绕路（合成帧 `line=-1`、
`_frame_set` monkey-patch、basename 重写 + 响应 remap 的双向变换、冗余 ASLR slide、
死代码 `if false` 分支、`_persist_bp` 空参 no-op push），需要分级清理。

## What Changes

- **新增 session-time 即时下断点路径**：证明并接通在活跃会话中直接向 LLDB 下发
  `breakpoint set`（经 DAP `setBreakpoints` 或 lldb-dap evaluate 命令通道），让 F9
  在运行时即时 resolve 并命中，**不再要求 `:UEDAPReattach`**。这是本 change 的基石；
  若真机复验证明 K33（`breakpoint set -f` 崩溃 lldb-dap 22.1.6）在当前 K30 platform
  route 下不复现，则采用 file:line 命令通道；若仍崩溃，则采用
  `image lookup --line` → `breakpoint set --address` 的 address 通道（须证明源行语义等价）。
- **降级 attach-time preseed 为"初始种子"**：preseed 从"唯一路径"变为"会话开始前的初
  始断点快照"，会话中新增/删除断点改走 live 路径。
- **移除诚实-warning 绕路**：live 路径接通后，删除 `configurationDone` gate +
  active-session F9 warning（dap.lua:1981-1985 / 2031-2044）。`verified` 仍 MUST 反映
  真实 LLDB 状态，**MUST NOT 假成功**。
- **清理可移除绕路**（不改行为，纯去 work around）：
  - 删除冗余 ASLR `target modules load --slide`（android.lua:923-932）及其专属 plumbing
    （`read_so_base_hex` / `module_rebase_command` / `_module_rebase_cmd`），前提是真机复验
    确认 `target create` + platform attach 的自动重定位成立。
  - 删除死代码 `_common.lua:137-142` 的 `if false and …` 分支。
  - 修复 `_persist_bp.lua:151-156` 的空参 `set_breakpoints({ [bufnr] = nil })` no-op
    （要么真正推送已恢复断点，要么删除）。
  - 修正 `dap.terminate` monkey-patch（dap.lua:1846-1851）的过时注释（"launch" → "attach"）。
- **合成帧绕路收敛**：把三处防御同一上游缺陷的绕路（stackTrace `line=-1` 占位、
  `_frame_set` monkey-patch、basename 响应 remap）收敛到单一 chokepoint 并标注上游
  根因（nvim-dap `jump_to_frame` 对 `line=0`+`sourceReference` 的处理、未尊重
  `threadCausedFocus`）。本 change 范围内**收敛 + 标注**，不强求删除（删除依赖上游修复）。
- **保留确属 load-bearing 的项**（明确不动）：`dap.terminate`→detach（K5）、step 重入
  防护、`stopOnEntry=true` 握手要求、`auto_continue_if_many_stopped=false`、env 数组化、
  source-map 单 backslash 入口去重。

## Capabilities

### New Capabilities
- `android-dap-live-breakpoints`: 活跃会话中即时下发/移除 Android file:line 断点并真实命
  中的行为契约——live 路径成功/失败判据、preseed 降级为初始种子、`verified` 真实性、
  不再依赖 reattach。

### Modified Capabilities
- `android-dap-attach`: 修改 "F9 断点真实 resolved 并命中" 需求，使其覆盖
  **session-time**（运行时新增）断点而不仅是 attach-time preseed；移除"必须 reattach
  才能应用会话中 F9 变更"的隐含约束。

## Impact

- **代码**：`lua/ue/dap.lua`（setBreakpoints listener、configurationDone gate、warning、
  合成帧守卫收敛）、`lua/ue/dap/android.lua`（preseed 降级、冗余 slide 清理、live 下发
  helper）、`lua/ue/dap/_common.lua`（死代码）、`lua/ue/dap/_persist_bp.lua`（no-op push）。
- **测试**：`tests/cases/dap_spec.lua` 需新增 live-breakpoint 路径断言、warning 移除断言、
  冗余 slide 移除断言；冻结清单按需同步。
- **真机验证**：需在授权设备 `2e2df4cb` / `<android-package>` 上复验 K33 崩溃是否复现，
  这是选 file:line 还是 address 通道的决定性证据；无真机时本 change 不得标记完成。
- **文档**：`docs/CONSTRAINTS.md`（K33/K34 状态更新、新增 live 路径约束）、`docs/TOOLING.md`、
  `docs/changelog.md`；`openspec/specs/android-dap-attach/spec.md` delta。
- **依赖**：无新依赖。host adapter 维持 LLVM 22.1.6+ forward-only。
- **风险**：live `breakpoint set` 在 K30 route 下可能仍崩溃 lldb-dap（K33 未最终证伪）——
  design.md 必须给出 file:line / address 双方案与回退判据，避免再次落入"碰巧不崩=正解"陷阱。
