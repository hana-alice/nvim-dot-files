## Why

现有 host driver、target driver 与 DAP registry 已形成平台分层骨架，但平台专属的工具选择、产物发现、设备状态机和错误策略仍持续回流 `lua/ue.lua` 及其他通用模块。平台宪法又被埋在 Apple semantic spec 中，测试甚至按源码位置锁定这些泄漏，导致后续开发容易只修当前平台而遗漏相邻边界。

现在需要把平台归属从“文档约定”升级为独立 canonical capabilities、明确 target workflow 合法落点，并以可执行回归阻止继续回流；否则 `ue.lua` 已出现的 12,002 行单体和 host/target 双真相会继续扩大。

## What Changes

- 建立独立的 host driver、shell planning、tool resolution、target driver、target workflow 与 DAP dispatch capability specs，不再由 Apple/iOS 功能规格代管全局平台宪法。
- 在 `lua/ue/` 下建立 target-owned workflow controller 层：target driver 继续负责纯 policy/plan，workflow controller 负责 target-specific 的异步任务、UI、progress、设备状态机与 cleanup，通用 runner 负责执行结构化计划。
- 将 `lua/ue.lua` 收敛为公共 API façade、context、命令注册、registry lookup 与通用 dispatch；迁出 iOS/Android lifecycle、Apple semantic workflow、host-specific tool/path resolution 和 DAP stop/status policy，同时保持现有命令、公共 Lua API、状态键、缓存布局与用户行为兼容。
- 将源码位置型测试改为 driver/workflow contract 与行为测试，并增加 AST/结构化架构回归：阻止通用层出现直接 OS probe、target literal executable branch、target-specific script/path/backend/error policy 或跨 target fallback。
- 对 `ue.lua` 引入只减不增的存量 ratchet；新 workflow 模块继续遵守现有 800 行上限，不能用新增白名单转移巨模块。
- 收口散落在 `index`、`code_search`、`config` 等模块中的 Python、Go tool、PATH separator、shell executable、动态库后缀与 path identity 决策，使调用方只消费 host driver capability。
- 把 `macos-ios-cdb-semantic-prepare` 中的全局平台边界移到新 capabilities，并澄清 `UEPrepare` 与 iOS readiness setup 的组合关系；本 change 默认保持现有 Build/Prepare/Package/Install/Launch/DAP 用户流程，不借重构改变外部语义。
- 标记旧平台 ADR/iteration log 为 historical/superseded，修正 `lua/ue/AGENTS.md` 对“故意 monolithic”的错误许可，并同步 architecture、CONSTRAINTS、测试映射与 changelog。

## Capabilities

### New Capabilities

- `host-platform-driver`: 定义直接 OS detection 的唯一归属、host driver 基础接口、optional capability 与兼容 boolean。
- `shell-command-planning`: 定义 host 选择 executable、shell helper 只负责 quote/argv 的边界。
- `platform-tool-resolution`: 定义 env → config → host driver 的工具解析优先级及 Python/clangd/lldb/Go tool、path identity 的所有权。
- `ue-target-driver-boundary`: 定义 host-target 正交、`host_operations` matrix、纯 target policy/plan、无跨 target fallback。
- `ue-target-workflow-boundary`: 定义 target-specific workflow controller、通用 runner 与 `ue.lua` façade 的职责和依赖方向。
- `dap-platform-dispatch`: 定义 matrix-filtered DAP 注册、session-owner dispatch，以及 attach/launch/stop/status/reattach 不按当前平台猜测的契约。

### Modified Capabilities

- `macos-ios-cdb-semantic-prepare`: 移除其代管的全局 host/target/core 边界要求，改为消费新的平台 capabilities；澄清 semantic prepare 与 iOS readiness workflow 的委托关系而不改变用户流程。
- `ios-build-run-workflow`: 改为消费 target driver/workflow 边界，明确 iOS policy、workflow controller 与通用 runner 的归属，不再以 `ue.lua` 内部实现作为验收锚点。
- `android-so-quick-deploy`: 改为消费 target workflow 与 tool-resolution 边界，保持 SO build/deploy/launch 行为不变，但禁止核心层拥有 Android transport 和 APK/SO lifecycle 实现。
- `multi-instance-state-isolation`: 补充长任务与 DAP session 必须按启动时捕获的 target/device/session owner dispatch，禁止切换 live selection 后改投其他 workflow。
- `android-f9-breakpoint-hit`: 删除仍允许用户 reattach 的过时分支，统一为既有 live-breakpoint 即时下发契约。
- `android-dap-attach-diagnostics`: 将历史 sandbox gdbserver 排查文字改为当前 `lldb-server platform` route，并明确旧诊断只作为历史证据。
- `android-dap-handshake-diagnostics`: 移除固定真机 serial 的规范化要求，改为每次 probe 显式捕获并贯穿当前 serial。

## Impact

- 运行时代码：`lua/ue.lua`、`lua/ue/targets/`、新增 `lua/ue/workflows/`、`lua/ue/dap/platforms.lua`、`lua/ue/index/`、`lua/utils/platform/`、`lua/utils/code_search/`、`lua/config/clipboard.lua`。
- 测试：`ue_target_*`、`platform`、`dap`、`commands`、`ue_api`、`multi_instance_state`，以及新增 architecture boundary filter；源码片段断言将改为 contract/behavior 断言。
- 文档与规格：architecture、CONSTRAINTS、AGENTS、testing map、changelog、旧 ADR 状态标记、Android DAP 过时诊断约束和上述 main specs。
- 兼容性：不删除或改名用户命令、keymap、`ue.*` 公共 API、持久状态键与 cache path；不引入新依赖。
- 风险：迁移涉及异步 callback、progress lifecycle、设备选择冻结、临时文件清理和跨进程 writer 语义，必须按 workflow 分批迁移并在每批后跑对应回归，最终执行全量门禁。
