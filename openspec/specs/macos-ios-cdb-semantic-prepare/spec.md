# macos-ios-cdb-semantic-prepare Specification

## Purpose

定义 macOS 宿主为 Unreal `Mac`/`IOS` 目标产生真实编译证据，并将其转换为 Neovim/clangd 语义上下文的行为契约。此能力不包含应用打包与设备操作。

## Requirements

### Requirement: 系统必须准确区分语法解析与编译器语义

MUST：系统必须把 Tree-sitter 语法解析和 clangd 编译语义作为两个独立状态；不得声称 `compile_commands.json` 是 Tree-sitter 工作的前置条件。

#### Scenario: 编译数据库不可用但 Tree-sitter 可用

- **WHEN** 当前工程没有有效 CDB，但 Tree-sitter parser 已加载
- **THEN** 系统必须允许语法高亮继续工作
- **AND** 只将 clangd 导航、诊断、补全和索引标记为未准备

### Requirement: 系统必须提供显式的 Neovim 语义编译入口

MUST：系统必须提供 `:UECompileForNvim`，在当前 tuple 上执行宿主原生 UBT 增量编译，并且仅在编译成功后进入 CDB 准备和 clangd 刷新。

#### Scenario: macOS 上编译 IOS 目标

- **WHEN** 宿主为 macOS，当前 platform 为 `IOS`，工程、target 和 configuration 均有效
- **THEN** 系统必须使用 `Engine/Build/BatchFiles/Mac/Build.sh`
- **AND** 必须以 argv 数组传递 target、platform、configuration 与 `-Project=<UPROJECT>`
- **AND** 不得调用 Windows path converter、PowerShell 或 `UnrealBuildTool.exe`

#### Scenario: IOS 构建不保留 response files

- **WHEN** 原生 IOS 编译成功但 Apple toolchain 没有留下当前 tuple 的 C++ response files
- **THEN** IOS target driver 必须规划 tuple-scoped UBT `GenerateClangDatabase`
- **AND** 该计划必须使用 `-NoExecCodeGenActions`，且不得执行 compile、Cook、Package、Deploy 或 Run
- **AND** 生成结果必须在同一构建输出 surface 可观察，经 provenance 校验后才可原子发布

#### Scenario: 编译失败

- **WHEN** 原生 UBT 进程返回非零退出码
- **THEN** 系统必须将任务标记为 failed 并显示退出码与失败阶段
- **AND** 不得运行准备阶段、替换最后成功 CDB 或重启 clangd

### Requirement: UEPrepare 必须保持纯准备语义

MUST：`UEPrepare` 必须只读取和转换已有 response files 或由显式语义编译阶段发布的 tuple-scoped CDB source；不得触发 UBT、编译或任何应用生命周期命令。

#### Scenario: 缺少 response files

- **WHEN** 当前 tuple 既没有可证明来源的 response files，也没有已验证的 tuple-scoped CDB source
- **THEN** `UEPrepare` 必须失败并建议运行 `:UECompileForNvim`
- **AND** 不得自动执行编译、Cook、Package、Deploy 或 Run

#### Scenario: 编译证据已存在

- **WHEN** 当前 tuple 存在有效 response files 或已验证的 tuple-scoped CDB source
- **THEN** `UEPrepare` 必须直接生成或复用 CDB
- **AND** 不得仅为准备语义而触发 UBT

### Requirement: 编译上下文必须严格隔离

MUST：系统必须按 project、target、platform、configuration 精确选择 response files 或 tuple-scoped CDB source，并保留编译器真实 argv 与 cwd。

#### Scenario: 引擎内存在第三方 CDB 测试夹具

- **WHEN** 第三方源码或测试目录包含名为 `compile_commands.json` 的嵌套夹具
- **THEN** 候选发现不得递归拾取该文件
- **AND** 任何文件条目落在当前 engine/project roots 之外的 CDB 必须在发布前拒绝

#### Scenario: 同时存在 Mac 与 IOS 响应文件

- **WHEN** 当前 platform 为 `IOS` 且扫描结果同时包含 `Mac` 与 `IOS` 候选
- **THEN** 系统必须只消费可证明属于当前 IOS tuple 的候选
- **AND** 必须在诊断中统计被拒绝的 foreign-platform 候选

#### Scenario: 头文件缺少编译器证据

- **WHEN** 一个头文件没有编译器产生的依赖上下文
- **THEN** 系统不得为其伪造 standalone compile command
- **AND** 必须将其保持为无可信语义上下文状态

### Requirement: 准备结果必须可追溯且增量稳定

MUST：系统必须记录当前 tuple、response file provenance、输入指纹、输出指纹与 clangd 工具链身份。

#### Scenario: 输入和输出均未变化

- **WHEN** response files 指纹与最后成功记录一致，生成 CDB 内容也一致
- **THEN** 系统必须报告 no-op
- **AND** 不得重写 CDB、切换 current shard 或重启 clangd

#### Scenario: 当前输入产生新数据库

- **WHEN** 有效 response files 的内容变化并成功生成不同 CDB
- **THEN** 系统必须原子发布新数据库和 provenance
- **AND** 仅在发布成功后刷新 clangd

#### Scenario: 用户检查当前语义状态

- **WHEN** 用户打开 `UECDBStatus` 或等价状态 surface
- **THEN** 系统必须显示当前 tuple、response file 数量、provenance/输出指纹、clangd 路径与版本以及最近任务结果
- **AND** 必须分别表达 Tree-sitter parser 状态和 clangd CDB 状态

### Requirement: clangd 工具链必须经过版本预检

MUST：系统必须按仓库声明的约束验证实际 clangd 路径和版本；不得静默接受不兼容版本或自动安装工具链。

#### Scenario: 系统 clangd 版本不足

- **WHEN** 探测到 clangd 但其版本不满足仓库约束
- **THEN** 系统必须阻止语义准备发布并报告实际路径、版本与所需约束
- **AND** 不得将其误报为 Tree-sitter 语法解析失败

### Requirement: 编译与准备必须异步且可取消

MUST：系统必须在不阻塞 Neovim UI 的任务生命周期中执行预检、编译、准备与刷新。

#### Scenario: 用户取消编译

- **WHEN** 用户在 compile 或 prepare 阶段取消任务
- **THEN** 系统必须终止后续阶段并标记 cancelled
- **AND** 必须保留最后成功 CDB 和 clangd 会话可恢复状态

### Requirement: host OS 与 Unreal target platform 必须分层

MUST：系统必须使用独立 host driver 表达 Windows/macOS/Linux 宿主工具能力，并使用独立 target driver 表达 Android/IOS/Mac/Win64/Linux 目标策略；不得用一个 platform 分支同时表达两个维度。

#### Scenario: macOS host 构建 IOS target

- **WHEN** 当前 host 为 macOS 且 target 为 IOS
- **THEN** 核心层必须组合 macOS host driver 与 IOS target driver
- **AND** 不得把 Mac target driver 当作 IOS target 的实现

#### Scenario: 不支持的 host-target 组合

- **WHEN** target driver 请求 host driver 不具备的工具能力
- **THEN** 系统必须返回结构化 unavailable 与缺失 capability
- **AND** 不得隐式切换 host 或调用另一个 target driver

### Requirement: 每个 Unreal target 的平台策略必须独立实现

MUST：Android、IOS、Mac、Win64、Linux 必须分别拥有 target-driver 模块；平台特定的脚本、argv、RSP 分类、产物、设备与生命周期策略只能存在于对应模块。

#### Scenario: IOS 与 Mac 都运行在 macOS

- **WHEN** IOS driver 与 Mac driver 都请求 macOS `Build.sh`
- **THEN** 两者必须分别构造和验证自己的 target argv 与 RSP 分类
- **AND** 任一 driver 不得调用另一个 driver 的实现或读取其状态

#### Scenario: 使用共享辅助函数

- **WHEN** 多个 target driver 复用路径归一化或 argv 校验
- **THEN** 共享 helper 必须无状态且不包含 target 选择、默认值、工具选择或产物策略
- **AND** 平台策略仍必须保留在调用方 driver 内

### Requirement: 核心调度层不得包含 target-specific 实现

MUST：`lua/ue.lua` 或其后继核心调度模块必须只负责上下文解析、命令注册、任务编排和 target-driver dispatch。

#### Scenario: 注册通用 UEBuild 命令

- **WHEN** 核心层为当前 target 规划 build
- **THEN** 必须通过 registry 解析 target driver 并调用统一 contract
- **AND** 核心层不得包含 Android/IOS/Mac 脚本名称或 target 条件分支

#### Scenario: 迁移现有 Android 实现

- **WHEN** Android build/PowerShell/SO 策略从核心层迁入 Android driver
- **THEN** 其既有 executable、argv、cwd、错误和用户命令行为必须保持兼容
- **AND** 回归测试必须证明该迁移没有借机改变 Android 行为

### Requirement: clangd 启动必须绑定已解析工程的受控 CDB

MUST：clangd 命令必须在 LSP root 已解析后选择当前 project bucket 与 tuple 对应的 active
controlled CDB，并把 resolved argv 保留给 exact-command transport。不得在静态配置加载时把
CDB 固化到配置仓库或 engine root，也不得依赖原生 LSP 不执行的 legacy callback。

#### Scenario: 原生 LSP 为工程启动 clangd
- **WHEN** Neovim 原生 LSP 为一个已选择 project root 创建 clangd client
- **THEN** cmd factory 必须生成指向该 project-scoped active CDB 的 `--compile-commands-dir`
- **AND** exact-command transport 必须读取实际 resolved argv，而不是把 cmd factory 函数当作 argv

#### Scenario: CDB 只有 command 字段
- **WHEN** compiler-authored CDB entry 只提供 POSIX 或 Windows `command` 字符串
- **THEN** 受控 CDB 工具必须按该 command 的原始宿主语法转换为结构化 `arguments`
- **AND** 后续 definition 注入与 super-unity 处理不得通过重新拼接引号改变编译语义

### Requirement: Apple no-response super-unity SHALL require exact context proof

MUST：Apple toolchain 没有保留 `.o.rsp` 时，super-unity 只能复用 active CDB 中 compiler-authored
argv。一个 unity group 只有在所有 include member 都唯一映射、cwd 相同、剥离 source 与逐文件
写出参数后的编译上下文完全一致，并且 argv 含可验证 Apple target 或 SDK/sysroot 证据时才可合并。
系统不得合成 flags 的并集；任何证据不足都必须 exact per-file fallback。

#### Scenario: AppleClang 成员上下文完全一致
- **WHEN** IOS/Mac unity members 的 active CDB argv 具有相同 target、arch、sysroot、defines、includes 与 PCH 上下文
- **THEN** 系统必须从 exact argv 只替换原 source 并剥离对象/依赖写出参数
- **AND** wrapper argv 必须保留其余编译器语义参数

#### Scenario: 任一语义参数不同
- **WHEN** unity members 的 define、include、target、sysroot、PCH、cwd 或其他语义参数不同
- **THEN** 该 group 必须拒绝合并
- **AND** 每个 member 必须继续使用自己的 exact compile command

#### Scenario: 只有通用 arch 参数而无 Apple 证据
- **WHEN** CDB argv 含 `-arch`，但没有 Apple target 或 Apple SDK/sysroot 证据
- **THEN** 系统 MUST NOT 把它推断为 Apple compiler context
- **AND** no-response grouping 必须 exact fallback
