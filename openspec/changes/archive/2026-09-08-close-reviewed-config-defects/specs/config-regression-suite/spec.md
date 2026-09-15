## MODIFIED Requirements

### Requirement: DAP 平台注册覆盖

回归套件 SHALL 验证 DAP 平台注册表与各平台模块的 `attach`/`launch` 导出。

#### Scenario: 平台注册与查找

- **WHEN** 用例对 `ue.dap.platforms` 注册测试处理器并查找
- **THEN** `register_attach` 后 `attach_handler` 返回可调用 function
- **AND** 未注册的 `launch_handler` 返回 nil
- **AND** `_reset_for_test` 可清空注册状态

#### Scenario: 各平台模块导出 attach/launch

- **WHEN** 用例遍历 `win64`、`mac`、`linux`、`ios`、`android`
- **THEN** 每个平台模块的 `attach` 与 `launch` 均为 function
- **AND** `ue.setup()` 后只有真实 host/target matrix 支持的平台操作会注册；不兼容的 attach/launch handler SHALL 为 nil

## ADDED Requirements

### Requirement: CI 与本地维护同一回归入口

CI SHALL 在隔离配置目录恢复仓库 lock 中的既有依赖及必需 parser，并执行 `tests/run.lua` 全量回归；旧 smoke 与 lint MAY 同时保留，但不能替代全量行为门禁。

#### Scenario: 全新 CI checkout
- **WHEN** runner 没有已有 Neovim 用户配置或插件缓存
- **THEN** checkout、stdpath(config) 与依赖初始化 SHALL 指向同一隔离目录
- **AND** 全量回归 SHALL 检验该 checkout，不读取其他用户配置

#### Scenario: DAP 环境与 host capability smoke
- **WHEN** smoke 检查 adapter 注册与 spawn 环境
- **THEN** SHALL 使用真实 host matrix，并按 libuv 的 KEY=VALUE 数组检查环境值
- **AND** 不注入假宿主让不兼容操作看似受支持
