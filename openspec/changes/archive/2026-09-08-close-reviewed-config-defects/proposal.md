## Why

全仓审查及后续独立复现确认了项目状态串写、并发锁、编译上下文、索引发布和编辑交互缺陷；此前 Android DAP 修复也已有实现和验证记录，但尚未通过一个活动 change 收口。本 change 在实施与验证之后补录，用于真实记录现有改动、同步行为契约并交接归档，**不是事前方案或尚待实施的计划**。

## What Changes

- 修复桌面 DAP 路径输入、断点项目交接、watcher 保存重试和 iOS 异步完成的项目归属。
- 保证 writer lease 的独占性，索引读取不提升暂存文件，reset/add 失败保留上一份完整索引。
- derived CDB 仅消费 active command 的显式语义输入，unity 无法证明兼容时使用 exact fallback。
- 修正 LSP 编码位置、同一行目标过滤、过期 header 回调和保存源码后的 sidecar 缓存失效。
- 修正当前 Visual 选区替换、picker 后正常移动和 Git NUL 路径解析；阻止继承的 Mason 自动安装及只读 health 的插件安装。
- 使旧 smoke 遵循真实宿主能力与环境数组契约，CI 接入隔离依赖初始化、全量 Lua 与 Go 回归。
- 纳入此前 Android Target/Configuration、DWARF/SONAME 符号选择、成功会话快照和握手分层诊断修复；保留真实设备仍受握手限制的结论。

## Capabilities

### New Capabilities

无；本 change 更新既有能力，不增加新 capability。

### Modified Capabilities

- `android-dap-attach`：统一构建与 DAP identity，严格选择符号源，并区分 host 符号名与 runtime SONAME。
- `android-dap-handshake-diagnostics`：限定同设备、同 binary 的 app uid / shell control 诊断结论，禁止把 control 当作 attach 回退。
- `config-regression-suite`：按真实宿主矩阵验证注册，CI 与本地执行同一全量入口。
- `cpp-contextual-definition-navigation`：精确编码位置、异步副作用新鲜度及已保存输入的缓存失效。
- `cpp-semantic-index-coverage`：derived CDB 保留 active command 编译语义，拒绝缺失或矛盾输入。
- `editor-behavior-regression`：保持显式工具安装，保留真实光标移动及 Git 文件路径语义。
- `keymap-command-regression`：Visual 替换读取当前选区并正确定位 replacement 字段。
- `multi-instance-state-isolation`：安全锁交接、项目绑定保存、断点和 iOS 结果隔离。
- `nvim-core-functionality-audit`：只读启动缺少 lazy.nvim 时明确失败，不安装或等待交互。
- `ue-code-search`：索引可用性检查只读且校验格式，失败发布保留上一份完整产物。

## Impact

涉及 `lua/ue/`、`lua/utils/`、配置与插件层、CDB Python 工具、Go cindex 工具、测试及 CI。维持既有插件和模块依赖，CI 仅初始化仓库已有工具前置；锁协议升级需要旧 Neovim 实例重启后才共同生效。

delta spec 以补录时的 `HEAD` 主规格与当前工作区主规格为依据，保留被修改 requirement 的完整场景。此次已验证内容与设备、GUI、远程 CI 的未验证边界见 `design.md`；归档、提交和推送未在本补录任务中执行。
