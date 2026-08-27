## 1. 冻结兼容面与现有行为

- [x] 1.1 在测试 fixture 中记录当前 `ue.*` 公共 API、用户命令、keymap、持久状态键、cache path 与 `lua/ue.lua` 12,002 行基线，并用 `ue_api`、`commands`、`keymaps`、`structure` filters 证明清单可重复生成。
- [x] 1.2 将 Android install、APK discovery、Gradle cleanup 与 SO deploy/launch 的 `ue.lua` 源码片段断言改为输入 context/driver plan 后的 argv、cwd、progress、错误与 cleanup 行为断言，并运行 `ue_target_integration`、`ue_target_tasks`、`android_device` filters。
- [x] 1.3 将 iOS semantic、signing、device、install、launch 的 `ue.lua` 源码位置断言改为 registry/注入 seam 的 plan、callback、状态持久化与 terminal completion 行为断言，并运行 `ue_target_drivers`、`ue_target_integration`、`cpp_semantic_index` filters。
- [x] 1.4 为 project、target、Android serial、iOS device/signing identity 在异步 workflow 开始后发生 live selection 变更补回归，验证运行中任务继续使用启动 snapshot，新 invocation 才读取新选择，并运行 `multi_instance_state` filter。
- [x] 1.5 生成基于 Lua Tree-sitter AST 的初始 boundary report，逐条登记现存违规的规则编号、精确文件、owner 与移除阶段；验证报告能发现审计已知的 `clipboard`、`code_search`、`index`、semantic sidecar 与 `ue.lua` 泄漏，且不使用目录级白名单。

## 2. 收口 host capability、shell 与工具解析

- [x] 2.1 为 Windows、macOS、Linux、stub driver 补齐同形基础接口及显式 optional capability 查询，保留只读 `platform.id/is_*` 兼容面，并用 `platform` filter 验证缺失能力结构化 fail closed。
- [x] 2.2 固化 `shell.lua` 只接受显式 shell kind/executable 并只返回 quote/argv plan 的 contract，迁移 driver 选择 PowerShell/cmd/POSIX shell 的入口，并用 `platform` filter 验证 helper 不探测 OS、不执行命令、不猜 fallback。
- [x] 2.3 实现统一 host tool resolver，按 env → config → driver 顺序返回首个可用候选、选中来源及被跳过 override 的诊断，并用 table-driven `platform` tests 覆盖有效覆盖、无效高优先级候选、optional capability 缺失与四类 driver。
- [x] 2.4 将 `lua/config/clipboard.lua` 的直接 `vim.fn.has('win32')` 分支迁到 host capability，并运行相关 config/clipboard 用例与 architecture boundary filter，验证通用模块不再直接探测 OS。
- [x] 2.5 将 `lua/utils/code_search/init.lua` 的 `.exe`、PATH separator 与 PowerShell/sh 决策迁到 host tool/shell capability，并运行 `utils`、`grep_cache`、`csearch_build_guard`、`ue_goto_behavior`、`ue_paths`、`platform` 与 architecture boundary filters，验证搜索行为与现有工具优先级不变。
- [x] 2.6 将 `lua/ue/index/_build.lua`、`lua/ue/index/_generation.lua` 与 `lua/ue/clangd_commands.lua` 的 Python、clangd-indexer、后缀和 WSL/Windows 路径决策迁到统一 resolver，并运行 `index_generation`、`cpp_semantic_index`、`clangd_commands`、`ue_api` filters。
- [x] 2.7 将 `lua/utils/ue_goto/semantic_sidecar_libclang.lua` 的 host 动态库名/后缀分支迁到 driver capability，并运行 semantic navigation 对应 filter 与 architecture boundary filter，验证 libclang 候选顺序和失败信息不变。
- [x] 2.8 在 host 收口完成后将初始 report 中相应例外删为零，并运行 `platform`、`code_search`、`index_generation`、`clangd_commands` filters；任一 filter 未绿不得开始 workflow 切换。

## 3. 建立 target workflow controller 基础层

- [x] 3.1 创建 `lua/ue/workflows/` registry、policy-free `_runtime.lua` 及该目录的 `AGENTS.md`/`CLAUDE.md` 单一规则入口，验证 `structure` filter 能发现目录且所有新 Lua 文件不超过 800 行。
- [x] 3.2 实现 immutable operation snapshot，冻结 canonical project、target、configuration、host、device/signing/runtime identity 与 operation owner；用注入测试验证 callback、poller、cleanup 和 persistence 不会重读 live selection。
- [x] 3.3 实现 workflow runtime 的 task execution、progress completion、project-change guard、cancel/cleanup 与 state seam，使用 fake runner 覆盖 success、task-start failure、async failure、cancel、project change，并运行 `ue_target_tasks` filter。
- [x] 3.4 实现按 `(target, operation)` 注册和查找的 workflow registry，dispatch 前强制复用 `targets.resolve()` / `host_operations` 验证组合；用 table-driven tests 证明 unsupported 组合 fail closed、无跨 target fallback、通用 registry 不含 target literal 执行分支。
- [x] 3.5 在 `ue.lua` 增加保持签名不变的薄 façade，使尚未迁移的 operation 仍走原 owner、已注册 operation 可委托新 registry，并用 `ue_api`、`commands`、`smoke` filters 证明用户入口和返回/回调语义不变。

## 4. 迁移 Android workflow ownership

- [x] 4.1 将 Android APK artifact discovery、Gradle cleanup、install plan 消费和可操作错误迁入 `workflows/android/install.lua` 或等价 operation owner，并用 fixture 覆盖零/单/多 artifact、clean failure、install success/failure 与 captured serial。
- [x] 4.2 将 root adbd、verified `su 0` 与 debuggable app-private transport probe/选择迁入 Android deploy owner，验证两类 transport、能力均缺失、离线 serial 与 pre-mutation failure 均符合 `android-so-quick-deploy`。
- [x] 4.3 将 SO staging、generation publish、hash/metadata 校验、rollback 与操作锁迁入 Android deploy owner，使用 fake filesystem/ADB runner 覆盖成功、并发拒绝、部分写入、hash failure 与首次部署 cleanup。
- [x] 4.4 将 app-private startup-agent launch、ClassLoader redirect 前置校验、maps 证明、错误进程 force-stop 与普通 APK launch 分支迁入 Android launch owner，并验证 staging absent、staging corrupt、双映射、稳定性复查失败与显式 launch-only 语义。
- [x] 4.5 让 Android install/deploy/launch 的所有异步步骤和 cleanup 只使用 invocation 捕获的 serial/package/project snapshot，并用 `android_device`、`multi_instance_state` tests 证明运行中切换设备不改投。
- [x] 4.6 逐 operation 切换 `ue.lua` façade 后删除对应旧 Android implementation 与双 owner 路径，下调 `ue.lua` ratchet，并运行 `android_device`、`ue_target_drivers`、`ue_target_integration`、`ue_target_tasks`、`commands` filters。

## 5. 迁移 iOS workflow ownership

- [x] 5.1 将 Apple semantic source generation 与 `UEPrepare` readiness 委托迁入 iOS semantic owner，保留 build evidence/receipt migration、source signature reuse 和 no-compile 约束，并运行 `cpp_semantic_index`、`ue_target_drivers` filters。
- [x] 5.2 将 prepared signing、identity/key access、entitlement/profile 预检和错误解释迁入 iOS signing owner，使用注入的 host capabilities 覆盖可用、拒绝访问、identity 缺失、project change 与 terminal progress。
- [x] 5.3 将 iOS device discovery/selection、route setup 与 device-scoped state 迁入 iOS device owner，验证多个/零设备、取消选择、captured owner 和与 Android/Mac 无 fallback。
- [x] 5.4 将 iOS artifact/script discovery、install/reset 流程迁入 iOS install owner，验证 structured plan、artifact ambiguity、task-start/async failure、cleanup 与现有状态键/cache path 不变。
- [x] 5.5 将 iOS launch、process ownership、DAP handoff 前置条件与失败清理迁入 iOS launch owner，验证 launch-owned 与 attach-owned process 语义、device disconnect、VimLeave 与重复 invocation。
- [x] 5.6 逐 operation 切换 `ue.lua` façade 后删除对应旧 iOS/Apple implementation 与双 owner 路径，下调 `ue.lua` ratchet，并运行 `ue_target_drivers`、`ue_target_integration`、`ue_target_tasks`、`dap`、`multi_instance_state` filters。

## 6. 按 session owner 收口 DAP dispatch

- [x] 6.1 扩展 matrix-filtered DAP registry，使每个 attach/launch session 注册 target、operation、device/process 与 cleanup owner metadata，并用 `dap` tests 验证只注册 `host_operations` 支持的 handler。
- [x] 6.2 将 DAP stop、status、terminated/exited、adapter error、device disconnect 与 VimLeave cleanup 改为按活跃 session owner 分派，验证 live platform/device selection 变化不会改变 cleanup target。
- [x] 6.3 将 reattach 入口改为只重建同一 session owner 的显式 operation，unsupported 或无 owner 时返回结构化 unavailable；验证 iOS 不回退 Mac、Android 不回退其他 target、stop 不猜 `M.current_platform()`。
- [x] 6.4 对齐 Android live breakpoint owner，移除仍提示 reattach 的 F9 旧分支，并用 `dap` tests 证明 active-session add/remove 即时走 live 通道、真实 `verified`、无静默或提示式 reattach。
- [x] 6.5 运行 `dap`、`android_device`、`multi_instance_state`、`ue_target_integration` filters，确认 attach/launch/stop/status/reattach、session cleanup 与 captured serial 全绿后再删除旧 dispatch compatibility implementation。

## 7. 建立可执行架构门禁并清理核心

- [x] 7.1 将初始 boundary report 固化为 Tree-sitter AST contract test，分别实现 direct OS probe、compat boolean 行为分支、target literal condition、host executable/path 构造、target-specific policy literal、concrete/cross-target import 六类规则，并用正反 fixture 验证每条规则能独立报错。
- [x] 7.2 为 registry 数据、命令声明、UI 展示文本建立精确 AST context allowlist，要求每项含规则编号、文件与理由；用故意违规 fixture 证明 allowlist 不能放过 executable branch 或整个目录。
- [x] 7.3 迁出 `ue.lua` 仍存的 target artifact、script、signing、device、command/error policy，删除重复 `driver.default_target()` block，并用 architecture boundary、`ue_api`、`commands` filters 证明核心只保留 context/registry/façade/generic dispatch。
- [x] 7.4 清理 generic helper 中剩余 host/target policy 和 load-time `require("ue")` 循环风险，验证依赖图只按 host capability/target plan → workflow → runner → façade 方向，且 target driver contract tests 仍保持 pure plan/parser。
- [x] 7.5 将 `ue.lua` 最大行数 ratchet 从 12,002 下调到迁移后的实际值并禁止上调，为所有新增 workflow 文件保留 800 行上限；用 `structure` filter 验证当前值通过、任意增长 fixture 失败。
- [x] 7.6 删除所有阶段性违规例外和旧/新 owner 双路开关，运行 architecture boundary filter 确认 production Lua 零已知违规，并以 `rg` 只作人工复核、不作为规范门禁。

## 8. 修正规格与项目指导的双真相

- [x] 8.1 更新 Android F9/attach/handshake 诊断文档，使 live breakpoint 不再建议 reattach、当前 route 使用 `lldb-server platform`、probe serial 显式捕获；运行 `openspec validate establish-ue-platform-workflow-boundaries --strict` 与 `structure` filter。
- [x] 8.2 更新 `docs/architecture/overview.md` 的五层依赖、workflow owner、lldb-dap 事实与 boundary guard，并将过时 platform ADR/iteration log 标为 historical/superseded；运行 `structure` filter 验证链接和状态标记。
- [x] 8.3 更新 `lua/ue/AGENTS.md`，删除“故意 monolithic”许可并写明 façade/workflow/target driver allowed/forbidden responsibilities；为受影响子目录同步本地规则 stub，并运行 `structure` filter。
- [x] 8.4 同步 `docs/CONSTRAINTS.md`、`tests/AGENTS.md`、`docs/testing-regression.md` 的 canonical capability、AST boundary filter、ratchet 与 change-to-filter mapping，验证两个测试映射表一致且 `structure` filter 全绿。
- [x] 8.5 修正 `lua/ue/config.lua` 工具优先级注释与 `utils.platform` capability 类型注释，删除或落实无 consumer 的 platform schema key；用 `platform`、`ue_api` 与 config 相关 tests 验证注释/类型契约和运行行为一致。
- [x] 8.6 在 `docs/changelog.md` Unreleased 按模板记录边界迁移、兼容性与全部 Validation 结果；运行 `structure` filter 验证 changelog 格式。

## 9. 分层验证与完成门禁

- [x] 9.1 运行 host/tool 范围 `platform`、`utils`、`grep_cache`、`csearch_build_guard`、`ue_goto_behavior`、`ue_paths`、`index_generation`、`cpp_semantic_index`、`clangd_commands`，逐项记录全绿输出且零已知错误。
- [x] 9.2 运行 workflow/core 范围 `ue_target_drivers`、`ue_target_integration`、`ue_target_tasks`、`android_device`、`multi_instance_state`、`ue_project_context`、`ue_api`、`commands`、`smoke`，逐项记录全绿输出且零已知错误。
- [x] 9.3 运行 DAP 与结构范围 `dap`、architecture boundary、`structure`、`keymaps` filters，确认 session owner dispatch、命令冻结、AST 门禁、line ratchet 与文档结构全绿。
- [x] 9.4 运行仓库既有 lint/type/static-analysis 入口、`git diff --check` 与 `openspec validate establish-ue-platform-workflow-boundaries --strict`，修完所有本 change 引入的告警和错误。
- [x] 9.5 运行提交/合并前全量 `nvim --headless -l tests/run.lua`，把命令、结果与任何不可运行的硬件验证边界写入 changelog Validation；全量未绿不得宣告完成。
