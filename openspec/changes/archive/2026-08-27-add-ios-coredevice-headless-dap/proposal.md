## Why

现有 Neovim iOS DAP 只实现 pre-iOS17 的 legacy MobileDevice/`ios-deploy` bridge，已选择的
iOS 17+ CoreDevice 真机因此会在 runtime gate 被拒绝。独立真机操作已经证明 selected Xcode 的
`devicectl --start-stopped`、LLDB `device select` 与 `device process attach -p` 能在同一台
CoreDevice 上完成启动和附加，现在需要把这条已证实路径纳入 Neovim 的 headless 可验证工作流。

## What Changes

- 为 IOS DAP 增加独立的 CoreDevice backend，并在 session 开始时冻结 project tuple、bundle、设备、
  PID、local Mach-O/dSYM 与 selected Xcode adapter；legacy backend 保持原有路径，不做会话中 fallback。
- `UEDAPLaunch ios` 使用 `devicectl --start-stopped` 创建 launch-owned suspended process，解析并复验正
  PID 后，通过 Apple `lldb-dap` 执行 `target create`、`device select` 与
  `device process attach -p`；`UEDAPAttach ios` 对已运行进程执行同样的 identity gate。
- 在首次 continue 前校验 host binary/dSYM/loaded image identity，并沿用 verified breakpoint、真实
  breakpoint stop、source frame 与 expression 结果作为 debug-ready 判据。
- 扩展 `tools/nvim_ios_dap_smoketest.lua`，让 `nvim --headless` 能从显式环境参数运行 production
  CoreDevice handler、生成脱敏证据并执行 owner-scoped 幂等 cleanup。
- 更新 iOS DAP 文档、架构说明、约束索引与 changelog；不增加依赖，不改变普通 `:UELaunch` 的非调试语义。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `ios-device-debug-workflow`: 明确 iOS 17+ CoreDevice 的 debug-launch/attach 命令、不可变 identity、
  headless 真机 gate 与 cleanup 行为，同时保留 legacy backend 的独立性。

## Impact

- 主要实现面：`lua/ue/dap/ios.lua`、`lua/ue/dap/_ios_process.lua`，必要时复用或扩展
  `lua/ue/targets/ios*.lua` 的纯 planner/parser。
- 验证面：`tests/cases/dap_spec.lua`、`tests/cases/ios_dap_probe_spec.lua`、
  `tools/nvim_ios_dap_smoketest.lua` 与脱敏 `tools/evidence/ios-dap/` 真机证据。
- 契约与说明：`openspec/specs/ios-device-debug-workflow/spec.md`、`docs/architecture/overview.md`、
  `docs/TOOLING.md`、README 与 `docs/changelog.md`。
- 外部系统：selected Xcode 的 `devicectl`、`lldb-dap`、LLDB CoreDevice commands 和已配对、已启用
  Developer Mode 的物理 iOS 设备；无新第三方依赖。
