## Why

之前的 Android DAP 修改没有解决 F9 断不住的问题：当前路径已经能围绕 platform attach
继续推进，但断点是否真实下发、是否 resolved、是否能命中停在源码行仍缺少一条闭环证据链。
这次 change 重新聚焦 F9：不再把 UI 断点标记或合成 `verified=true` 当成成功，而是要求从
nvim 断点状态到 LLDB `breakpoint list` 再到真机命中的端到端证明。

## What Changes

- 重新定义 Android F9 断点的成功标准：DAP 响应、LLDB resolved location、实际 stop
  事件、源码行定位必须一致。
- 增加 apply 前的硬规则：每个方案必须先对应到当前代码行为；若代码行为与方案假设冲突，
  必须先修正方案，不允许边写边猜。
- 清理 F9 断点设计中的 workaround 形态：重复 preseed、未被证据支撑的 `verified=true`、
  自动 reattach 当作断点下发机制等都必须重新评估，保留的路径必须是语义正解。
- 梳理并修正断点生命周期：attach 前已有断点、attach 后新增/删除断点、重新 attach 时的
  preseed 行为分别有明确路径。
- 在保留当前 platform-mode attach 路线的前提下，诊断并修复断点未命中的真实原因：
  source path 映射、symbol-rich `libUE4.so` 目标创建、ASLR relocation、preseed 插入顺序、
  DAP `setBreakpoints` 合成短路与 LLDB 崩溃风险。
- 增加可复现 probe / headless smoke / 真机验证步骤，避免再次只凭 UI 或旧日志判断成功。
- 同步 `android-dap-attach` spec 中已经过时的连接约束，使断点修复建立在当前 K30
  serial-form platform route 上。

## Capabilities

### New Capabilities
- `android-f9-breakpoint-hit`: 覆盖 UE Android F9 file:line 断点从编辑器设置到真机命中的
  端到端契约，包括 preseed、动态 breakpoint 更新、resolved 判定、命中停顿与日志证据。

### Modified Capabilities
- `android-dap-attach`: 修正现有 attach 契约中与当前实现/约束不一致的连接描述，并把
  “F9 断点真实 resolved”扩展为“真实命中并停在正确源码行”。

## Impact

- 运行时代码：`lua/ue/dap/android.lua`、`lua/ue/dap.lua`，必要时涉及 `lua/ue/dap/_persist_bp.lua`。
- 平台工具链发现：必要时只读复核 `lua/utils/platform/windows.lua` 的 lldb-dap /
  lldb-server 优先级，不引入新依赖。
- 诊断脚本：可能新增或扩展 `tools/dap_*probe*.py` / `tools/nvim_android_dap_smoketest.lua`
  以捕获 breakpoint request、`breakpoint list`、stop event 与 adapter 存活状态。
- 文档与约束：`docs/CONSTRAINTS.md`、`docs/TOOLING.md`、`docs/changelog.md`、
  `openspec/specs/android-dap-attach/spec.md`。
- 设备验证：仍限定在 `a3ad86f3`；host adapter 维持 LLVM 22.1.6+ forward-only；不引入新依赖。
