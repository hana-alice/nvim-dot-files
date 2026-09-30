# macos-ios-cdb-semantic-prepare Specification

## Purpose

定义 macOS 宿主为 Unreal `Mac`/`IOS` 目标产生真实编译证据，并将其转换为 Neovim/clangd 语义
上下文（compile_commands.json / index）的行为契约。不包含应用打包与设备操作（见
`ios-build-run-workflow`）。核心边界：语法解析（Tree-sitter）与编译器语义（clangd）是两个独立
状态；构建（`:UEBuild`）与语义准备（`:UEPrepare`）是显式两阶段流程，`:UEPrepare` 本身不得触发
编译，但对声明 `semantic_cdb` capability 的 IOS target，必须显式委托 iOS readiness workflow
完成签名/设备前置条件后再生成语义源。

## Requirements

### Requirement: 语法解析与编译器语义必须保持独立状态

MUST：系统不得声称 `compile_commands.json` 是 Tree-sitter 工作的前置条件；没有有效 CDB 时语法
高亮仍必须工作，只将 clangd 导航/诊断/补全/索引标记为未准备。

#### Scenario: 编译数据库不可用但 Tree-sitter 可用

- **WHEN** 当前工程没有有效 CDB，但 Tree-sitter parser 已加载
- **THEN** 系统必须允许语法高亮继续工作，只将 clangd 能力标记为未准备

### Requirement: 构建与语义准备必须是显式两阶段，IOS 需委托 readiness workflow

MUST：正常流程先以 `:UEBuild` 执行宿主原生 UBT 增量编译，再由 `:UEPrepare` 生成 CDB 并刷新
clangd；`:UECompileForNvim` MAY 作为顺序执行两阶段的兼容入口，但 Apple semantic CDB 生成的所有权
必须归 `:UEPrepare`。对 macOS 上声明 `semantic_cdb` 的 IOS target，`:UEPrepare` 必须先确认当前
tuple 已有成功 build evidence，再显式委托 iOS readiness workflow 完成 prepared signing、私钥访问
与设备 route setup，然后才规划不含 compile action 的 UBT `GenerateClangDatabase`；该委托不得改变
现有 `:UEPrepare` / `<leader>up` 的用户可观察行为，也不得改变 build/package/install/launch 语义。

#### Scenario: macOS 上编译 IOS 目标

- **WHEN** 宿主为 macOS，当前 platform 为 `IOS`，工程/target/configuration 均有效
- **THEN** 系统必须使用 `Engine/Build/BatchFiles/Mac/Build.sh`，以 argv 数组传参
- **AND** 不得调用 Windows path converter、PowerShell 或 `UnrealBuildTool.exe`

#### Scenario: Apple target 缺少当前 tuple build evidence

- **WHEN** 当前 IOS tuple 没有成功 build evidence
- **THEN** `UEPrepare` 必须失败并建议先运行 `<leader>ub`，不得自动执行编译

#### Scenario: IOS 首次 prepare 显式委托 readiness workflow

- **WHEN** 当前 IOS tuple 已有成功 build evidence，但 prepared signing、私钥访问或 device route
  setup 尚未完成
- **THEN** `UEPrepare` 必须先显式委托 iOS readiness workflow 完成这些前置条件，成功后才继续
  semantic source 生成
- **AND** 用户观察到的 `:UEPrepare` / `<leader>up` 行为必须与现有流程一致

#### Scenario: 重复 prepare 复用当前 build 的 Apple semantic source

- **WHEN** project/uproject/target/platform/configuration 与 build completion evidence 均精确匹配，
  且已验证的 tuple-scoped CDB source 路径、大小与纳秒 mtime 均未变化
- **THEN** `UEPrepare` 必须直接复用该 semantic source，不得再次启动 `Build.sh` 或 UnrealBuildTool

### Requirement: 编译上下文必须严格隔离且可追溯

MUST：系统必须按 project/target/platform/configuration 精确选择 response files 或 tuple-scoped
CDB source，并保留编译器真实 argv 与 cwd；诊断兼容转换 MAY 派生语义 argv，但 MUST 保留原始构建
输入及其 provenance，最终命令必须经同一 prepare 事务封存。系统必须记录当前 tuple、provenance、
输入/输出指纹与 clangd 工具链身份；输入输出均未变化时必须报告 no-op，不得重写 CDB 或重启 clangd；
内容变化时必须原子发布新数据库，仅在发布成功后刷新 clangd。

#### Scenario: 同时存在 Mac 与 IOS 响应文件

- **WHEN** 当前 platform 为 `IOS` 且扫描结果同时包含 `Mac` 与 `IOS` 候选
- **THEN** 系统必须只消费可证明属于当前 IOS tuple 的候选，并统计被拒绝的 foreign-platform 候选

#### Scenario: 输入和输出均未变化

- **WHEN** response files 指纹与最后成功记录一致，生成 CDB 内容也一致
- **THEN** 系统必须报告 no-op，不得重写 CDB、切换 current shard 或重启 clangd

### Requirement: clangd 工具链必须经过版本预检且启动绑定受控 CDB

MUST：系统必须按仓库声明的约束验证实际 clangd 路径和版本，不得静默接受不兼容版本或自动安装
工具链；当前生产预检限定 `22.1.x`，clangd/libclang/C ABI shim 必须使用一致的工具链身份。clangd
命令必须在 LSP root 已解析后选择当前 project bucket 与 tuple 对应的 active controlled CDB，不得
在静态配置加载时把 CDB 固化到配置仓库或 engine root。

#### Scenario: 系统 clangd 版本不足

- **WHEN** 探测到 clangd 但其版本不满足仓库约束
- **THEN** 系统必须阻止语义准备发布并报告实际路径、版本与所需约束，不得误报为 Tree-sitter 失败

### Requirement: 编译与准备必须异步且可取消

MUST：系统必须在不阻塞 Neovim UI 的任务生命周期中执行预检、编译、准备与刷新。

#### Scenario: 用户取消编译

- **WHEN** 用户在 compile 或 prepare 阶段取消任务
- **THEN** 系统必须终止后续阶段并标记 cancelled，必须保留最后成功 CDB 和 clangd 会话可恢复状态

### Requirement: clangd 版本相关的诊断/索引兼容 workaround 必须有界且可验证

MUST：每个具名 clangd/NDK 兼容 workaround（friend-template canonical、Android 模板诊断兼容、
旧 Android 编译器警告兼容、Windows header filename casing、Apple no-response super-unity）必须
限定在探测到的实测工具链版本范围内生效；未知版本、工具不可确认或证据不足时必须保持原样并报告
未应用原因，不得据此扩大豁免或猜测环境。转换必须保留原始构建输入、argv、cwd 与 provenance，
相同输入重复 prepare 不得重写相同 CDB 字节或 mtime；不确定归属的编译对象必须保留而不是被静默
排除以“伪造完整覆盖”。

#### Scenario: 已验证的模板写法触发新版本默认错误

- **WHEN** 已确认的 clangd 22.1.x 处理 Android C++17 命令，且命令没有该组的显式诊断控制
- **THEN** 转换 SHALL 仅增加对应 `-Wno-error` 选项，全局 `-Werror` 与其他所有参数、宏、路径、
  cwd、源文件必须保留
- **AND** 未知版本、工具不可确认、非 Android 或非 C++17 命令必须保持原样并报告未应用原因

#### Scenario: Apple no-response unity 成员上下文完全一致

- **WHEN** Apple toolchain 没有保留 `.o.rsp`，且 IOS/Mac unity members 的 active CDB argv 具有相同
  target、arch、sysroot、defines、includes 与 PCH 上下文
- **THEN** 系统必须从 exact argv 只替换原 source 并剥离对象/依赖写出参数
- **AND** 任一语义参数不同或只有通用 `-arch` 而无 Apple 证据时，必须 exact per-file fallback，
  不得合成 flags 的并集

## 选型与踩坑

- **选型**：`:UEPrepare` 不直接触发 compile，但对 IOS target 显式委托 iOS readiness workflow
  （见 `ios-device-debug-workflow`/`ios-build-run-workflow`），保持一次性配置收敛为 Apple 前置
  分支，不改变用户可观察流程
  （出处：`openspec/changes/archive/2026-08-24-establish-ue-platform-workflow-boundaries/proposal.md`）。
- **踩坑**：`clangd.friend_template_canonical` workaround — 同一双 TU 数据库中仅修改源文件注释
  即可让 `InternalConstructor` 引用从主模板变为具体实例，导致主模板 references 查询漏项；已验证
  的修正是早于所有原 forced inputs 的等价 namespace 声明，只在 Unity 正文添加声明不能修复热重
  索引；严格限定已测工具版本（`22.1.5`）与引擎头字节身份，未知情形不得猜测应用
  （出处：`docs/cpp-index-restart-investigation.md`；`lua/workarounds/clangd/friend_template_canonical.lua`）。
- **踩坑**：`clangd.header_path_case` workaround — 错误大小写 include 可使 SymbolCollector 与
  IncludeGraph 使用不同 URI，实际头文件 shard 的 symbols/refs 为空，随后同 digest 被误判为已索引；
  逐文件原位 VFS 使用真实外部文件名可恢复记录，不得修改源码或折叠不同物理文件
  （出处：`lua/workarounds/clangd/header_path_case.lua`）。
- **踩坑**：`clangd.legacy_android_warnings` workaround — Android Clang 9.0.9 成功构建不代表新版
  clangd 的交互诊断级别相同；只在已证明的 Android C++17 + 有效全局 `-Werror` 命令中添加 VLA、
  unused-but-set-variable 两个具体组的 `-Wno-error=`，`unused-variable` 是并列组不能误作父组
  （出处：`docs/cpp-index-restart-investigation.md`；`lua/workarounds/clangd/legacy_android_warnings.lua`）。
- **踩坑**：K74 — Clang DefaultError 不是由全局 `-Werror` 造成；必须先核对诊断定义与真实 TU，
  兼容处理仅在已声明的工具/target/语言范围内改变该组级别；参数插入不得把末尾同名路径误猜成
  source operand（可能属于 `-include`）
  （出处：`docs/CONSTRAINTS.md` K74；`tools/clangd_diagnostic_compat.py`）。
- **重要事项**：各 workaround 独立限定自身实测版本，通用版本预检不能推导其适用于所有版本；
  当前生产预检限定 clangd `22.1.x`。
