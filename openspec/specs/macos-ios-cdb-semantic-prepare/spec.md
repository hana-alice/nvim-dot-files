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

### Requirement: 构建与 Neovim 语义准备必须组成显式两阶段流程

MUST：正常工作流必须先以 `:UEBuild` / `<leader>ub` 在当前 tuple 上执行宿主原生 UBT 增量编译，
再由 `:UEPrepare` 生成 CDB 并刷新 clangd。`:UECompileForNvim` MAY 作为顺序执行这两个阶段的兼容入口，
但 Apple semantic CDB 的生成所有权必须属于 `:UEPrepare`。

#### Scenario: macOS 上编译 IOS 目标

- **WHEN** 宿主为 macOS，当前 platform 为 `IOS`，工程、target 和 configuration 均有效
- **THEN** 系统必须使用 `Engine/Build/BatchFiles/Mac/Build.sh`
- **AND** 必须以 argv 数组传递 target、platform、configuration 与 `-Project=<UPROJECT>`
- **AND** 不得调用 Windows path converter、PowerShell 或 `UnrealBuildTool.exe`

#### Scenario: IOS 构建后进入 prepare

- **WHEN** 原生 IOS 编译成功但 Apple toolchain 没有留下当前 tuple 的 C++ response files
- **AND** 用户随后执行 `:UEPrepare`
- **THEN** IOS target driver 必须规划 tuple-scoped UBT `GenerateClangDatabase`
- **AND** 该计划必须使用 `-NoExecCodeGenActions`，且不得执行 compile、Cook、Package、Deploy 或 Run
- **AND** 生成结果必须在同一构建输出 surface 可观察，经 provenance 校验后才可原子发布

#### Scenario: 工程 action-graph 构造包含自定义 AOT 副作用

- **WHEN** IOS `GenerateClangDatabase` 加载的工程规则支持 `bSkipAOTProcess`
- **THEN** semantic-CDB 子进程必须单独设置 `bSkipAOTProcess=true`
- **AND** 该环境不得泄漏到 `<leader>ub` 或其他 target 的 build/prepare

#### Scenario: 编译失败

- **WHEN** 原生 UBT 进程返回非零退出码
- **THEN** 系统必须将任务标记为 failed 并显示退出码与失败阶段
- **AND** 不得运行准备阶段、替换最后成功 CDB 或重启 clangd

### Requirement: UEPrepare 不得触发编译但必须拥有 Apple semantic source 生成

MUST：`UEPrepare` 不得触发 compile、Cook、Package、Deploy 或 Run。对保留 response files 的 target，它必须继续只读转换已有证据；对 macOS 主机上声明 `semantic_cdb` capability 的 IOS target，它必须在确认当前 tuple 已有成功 build evidence 后，显式委托 iOS readiness workflow 完成 prepared signing、私钥访问与设备 route setup，再执行不包含 compile action 的 UBT `GenerateClangDatabase`，然后进入公共 CDB/index pipeline。该委托必须保持现有 `:UEPrepare` / `<leader>up` 的用户行为不变，不得改变 build/package/install/launch 语义。

#### Scenario: Apple target 缺少当前 tuple build evidence

- **WHEN** 当前 IOS tuple 没有成功 build evidence
- **THEN** `UEPrepare` 必须失败并建议先运行 `<leader>ub`
- **AND** 不得自动执行编译、Cook、Package、Deploy 或 Run

#### Scenario: 状态 marker 上线前已经成功构建

- **WHEN** project bucket 没有 Nvim build marker，但当前 tuple 存在精确匹配的 UBT `.target` receipt
- **AND** receipt 声明的 launch product 仍存在
- **THEN** `UEPrepare` 必须把该 receipt 迁移为 project-scoped build evidence 并继续
- **AND** 不得要求用户为补写 marker 重复执行相同构建

#### Scenario: 编译证据已存在

- **WHEN** 当前 tuple 存在有效 response files 或已验证的 tuple-scoped CDB source
- **THEN** `UEPrepare` 必须直接生成或复用 CDB
- **AND** 非 Apple target 不得仅为准备语义而触发 UBT

#### Scenario: 重复 prepare 复用当前 build 的 Apple semantic source

- **WHEN** project/uproject/target/platform/configuration 与 build completion evidence 均精确匹配
- **AND** 已验证的 tuple-scoped CDB source 路径、大小与纳秒 mtime 均未变化
- **THEN** `UEPrepare` 必须直接复用该 semantic source
- **AND** 不得再次启动 `Build.sh` 或 UnrealBuildTool
- **AND** 新 build evidence 或 source 文件签名变化后必须重新生成并验证

#### Scenario: IOS 首次 prepare 显式委托 readiness workflow

- **WHEN** 当前 IOS tuple 已有成功 build evidence，但 prepared signing、私钥访问或 device route setup 尚未完成
- **THEN** `UEPrepare` 必须先显式委托 iOS readiness workflow 完成这些前置条件
- **AND** readiness workflow 成功后才可继续 semantic source 生成
- **AND** 用户观察到的 `:UEPrepare` / `<leader>up` 行为必须与现有流程一致

#### Scenario: 其他平台执行 prepare

- **WHEN** 当前 target 不声明 `semantic_cdb` capability
- **THEN** `UEPrepare` 必须保持原有 response-file 路径
- **AND** 不得执行 IOS setup、Apple clangd prelude 或 `GenerateClangDatabase`

### Requirement: 编译上下文必须严格隔离

MUST：系统必须按 project、target、platform、configuration 精确选择 response files 或 tuple-scoped CDB source，并保留编译器真实 argv 与 cwd。
已声明的 clangd 诊断兼容转换 MAY 派生语义 argv，但 MUST 保留原始构建输入及其 provenance，
且最终命令必须经同一 prepare 事务封存；不得在查询或发布时偷偷改写参数。

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

#### Scenario: Android RSP 明确绑定 NDK 工具链布局

- **WHEN** 最终有效 target 为 Android，显式绝对 `--gcc-toolchain` 与 `--sysroot` 一致指向同一工具链的 root 和 root/sysroot，且 root/bin/clang++ 可执行
- **THEN** CDB SHALL 使用该绝对编译器路径并记录布局来源，不再由 PATH 的裸 clang++ 替代
- **AND** SHALL 保留其他 argv 与 cwd；布局不能证明时保留既有 fallback 并记录原因，不得猜测环境 NDKROOT
- **AND** 该恢复 MUST NOT 被描述为 clangd 使用 NDK 的 parser，也不能替代真实构建 Action CommandPath 的核对

#### Scenario: 当前链接已替换旧 Unity 或重新吸收 adaptive 源

- **WHEN** selected tuple 的 build receipt 唯一绑定现有 linker response，且真实 `-o` 对象、编译架构与同目录当前直接链接对象可交叉验证
- **THEN** 收集器 SHALL 在 Unity 展开和源去重之前排除该已证明对象族中不被当前链接消费的旧 RSP
- **AND** SHALL 保留当前对象的原始 argv、cwd 与完整 Unity 成员，不得按源 basename、时间戳或引擎路径替换猜测选择
- **AND** SHALL 记录使用的链接输入身份、保留或排除原因；相同输入 SHALL 得到相同选择

#### Scenario: 当前链接无法证明某个编译对象的归属

- **WHEN** receipt 或 response 缺失、无法唯一绑定、嵌套输入损坏，或静态 archive / 多架构使对象归属不确定
- **THEN** 收集器 SHALL 保留无法判定的编译输入并显式记录原因
- **AND** 一个架构的直接链接清单 MUST NOT 被用来静默删除另一架构或 archive 可能使用的源
- **AND** 当前链接对象缺少编译证据时 SHALL 报告覆盖缺口，不能删除其他源来伪造完整覆盖

### Requirement: 准备结果必须可追溯且增量稳定

MUST：系统必须记录当前 tuple、response file provenance、输入指纹、输出指纹与 clangd 工具链身份。

#### Scenario: 输入和输出均未变化

- **WHEN** response files 指纹与最后成功记录一致，生成 CDB 内容也一致
- **THEN** 系统必须报告 no-op
- **AND** 不得重写 CDB、切换 current shard 或重启 clangd
- **AND** raw 生成、pipeline 与 partition 必须在工作副本完成，只有最终内容变化才发布；同内容 provenance、shard 与 partition manifest 也不得重写或触发输入失效监听

#### Scenario: 当前输入产生新数据库

- **WHEN** 有效 response files 的内容变化并成功生成不同 CDB
- **THEN** 系统必须原子发布新数据库和 provenance
- **AND** 仅在发布成功后刷新 clangd
- **AND** 整个工作副本事务与手动 partition/switch 必须遵守同一 live CDB writer lease；发布失败必须恢复旧产物，回滚失败时保留并报告恢复备份

#### Scenario: C 命令不含可识别配置的 Intermediate 路径

- **WHEN** 编译器 argv 不再包含可判定 configuration 的路径，但仍含明确有效的 `UE_BUILD_*` 配置宏
- **THEN** partition SHALL 按 argv 顺序处理定义与取消定义，用唯一明确启用的配置补足路径缺失的 configuration
- **AND** `=0` 不得作为启用证据；冲突或无法判断的配置 SHALL 保持 unknown
- **AND** 此分类 SHALL 保留原编译参数与 cwd，不得把确属当前 build 的 C 源静默排除在 active CDB 外

#### Scenario: 用户检查当前语义状态

- **WHEN** 用户打开 `UECDBStatus` 或等价状态 surface
- **THEN** 系统必须显示当前 tuple、response file 数量、provenance/输出指纹、clangd 路径与版本以及最近任务结果
- **AND** 必须分别表达 Tree-sitter parser 状态和 clangd CDB 状态

### Requirement: clangd 工具链必须经过版本预检

MUST：系统必须按仓库声明的约束验证实际 clangd 路径和版本；不得静默接受不兼容版本或自动安装工具链。
工具链选择 SHALL 在 A/B 正确性、性能与兼容成本验证合格的候选中优先较新版，
MUST NOT 将追随 upstream latest 当作硬要求。当前生产预检限定22.1.x；
clangd、libclang 与 C ABI shim SHALL 使用一致的工具链身份。
各 workaround SHALL 独立限定自身实测版本，不能由通用版本预检推导其适用于所有版本。

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

### Requirement: Friend-template index compatibility SHALL preserve cold and warm references

The prepare pipeline MAY apply the isolated `clangd.friend_template_canonical` workaround
after response expansion and before PCH recipe generation. It SHALL probe the selected
clangd, require the tested `22.1.5` version and an explicitly approved pair of actual
CoreUObject header byte identities, and retain unknown engine revisions unchanged with
an observable reason when no workaround prefix is already present. Text resembling a declaration in comments or another namespace
MUST NOT authorize this transformation.

#### Scenario: A supported UE command uses textual forced inputs
- **WHEN** the command is confirmed C++, explicitly searches the approved CoreUObject context, and contains no unsupported indirect or binary PCH inputs
- **THEN** prepare MAY insert the equivalent namespace-scope `InternalConstructor` declaration as the first forced header, preserving every original argument's relative order
- **AND** the compatibility header SHALL have a stable non-staging path; repeated preparation SHALL not duplicate the option or rewrite unchanged output
- **AND** the existing Unity receipt SHALL bind the resulting command, while original build inputs remain intact

#### Scenario: Shared headers are cached when a source changes
- **WHEN** a supported source is reindexed with unchanged shared headers
- **THEN** references to the primary friend template SHALL retain the same source locations as cold indexing
- **AND** a declaration placed only in an unchanged Unity wrapper body MUST NOT be treated as an equivalent fix

#### Scenario: An existing compatibility prefix cannot be validated
- **WHEN** a command already contains the workaround-owned prefix but its tool, engine or command context is unsupported, or the prefix is duplicated or is not the first forced input
- **THEN** prepare SHALL fail without changing the CDB bytes or mtime; it MUST NOT report a successful skipped transformation while retaining that unverified prefix
- **AND** commands without that prefix SHALL retain the unchanged, observable skip behavior for unknown contexts

#### Scenario: PCH recipes cannot preserve the compatibility prefix
- **WHEN** an existing recipe generator would drop this first forced header
- **THEN** affected commands SHALL retain their textual inputs and report that recipe limitation; unaffected commands SHALL continue through the existing recipe generator
- **AND** the workaround MUST NOT disable existing binary PCH inputs, claim binary PCH support, or bypass full SuperUnity performance acceptance

### Requirement: Android 模板诊断兼容 SHALL 是有界的 prepare 转换

默认 CDB pipeline SHALL 在 response 展开后、PCH 配方生成前执行具名诊断兼容步骤。
它 SHALL 探测实际已选中的 clangd，仅对版本 `22.1.x`、Android target、有效标准选项为
`-std=c++17` 且可确认 C++ 语言的命令增加
`-Wno-error=missing-template-arg-list-after-template-kw`。这是语义前端的明确兼容策略，
MUST NOT 根据 NDK 路径推断历史构建编译器版本。

该转换 MUST 保留全局 `-Werror` 及其他所有参数、宏、包含路径、target、cwd 和源文件，
MUST NOT 抑制警告或放宽其他编译错误；命令已有该诊断组的显式控制时 SHALL 尊重它。
未知版本、工具不可确认、非 Android 或非 C++17 命令 SHALL 保持原样，并报告未应用原因。
原始 RSP/unity/source 身份 MUST 保留，最终 active 命令与 shader donor 命令 SHALL 由既有
receipt 重新封存；前后台查询和分组 SHALL 复用同一最终命令。此策略不得删除 TU 或源文件。

#### Scenario: 已验证的模板写法触发新版本默认错误
- **WHEN** 已确认的 clangd 22.1.x 处理 Android C++17 命令，且命令没有该组的显式诊断控制
- **THEN** 转换 SHALL 仅增加这一项 `-Wno-error` 选项，放在参数终止符之前
- **AND** 诊断 SHALL 仍作为警告可见，真正的非模板调用等其他错误 SHALL 继续失败
- **AND** 完整索引记录等价证据与编译成功 SHALL 分别验证，不能只靠退出码认定语义正确

#### Scenario: 用户明确要求该诊断作为错误
- **WHEN** 原命令已有 `-Werror=missing-template-arg-list-after-template-kw` 或该组的其他显式控制
- **THEN** 转换 SHALL 原样保留该命令，不覆盖用户的诊断选择

#### Scenario: 重复准备相同兼容命令
- **WHEN** 相同输入再次经过该步骤
- **THEN** SHALL 不重复添加选项，不改写相同 CDB 字节或 mtime
- **AND** 后续同内容 receipt、分区、generation 和 clangd 会话 SHALL 继续遵守 no-op 约定

#### Scenario: 编译输入实际缺失
- **WHEN** 错误来自缺失源文件或头文件
- **THEN** 此诊断转换 MUST NOT 将它当成模板兼容问题、豁免错误或删除对应 TU
- **AND** SHALL 保留真实缺失证据，交由正确构建输入的 owner 处置

### Requirement: 旧 Android 编译器警告兼容 SHALL 逐诊断组最小化

具名 `clangd.legacy_android_warnings` workaround MAY 在 prepare 事务内调整编辑器命令。
它 SHALL 仅接受经探测的 clangd 22.1.x、与显式 NDK 布局一致的绝对编译器实际报告
Android Clang 9.0.9、Android C++17 且最后有效全局控制为 `-Werror` 的命令。
唯一允许添加的选项为 `-Wno-error=vla-cxx-extension` 与
`-Wno-error=unused-but-set-variable`；MUST NOT 添加全局 `-Wno-error`、删除 `-Werror`
或抑制警告。每个组独立尊重原命令对它及真实父组的显式控制。

#### Scenario: 新版 Wall 增加旧 NDK 不报告的两类警告
- **WHEN** 命令满足工具、target、标准与全局 Werror 守卫
- **THEN** SHALL 只添加尚未显式控制的具体组级 demotion，原始参数顺序、操作数邻接与源覆盖不变
- **AND** VLA 与 assigned-only variable 诊断 SHALL 保持 warning；无关警告、语义错误及显式组级 Werror SHALL 继续失败
- **AND** `unused-variable` 与 `unused-but-set-variable` 是并列组，前者的控制 MUST NOT 被误当成后者父组控制
- **AND** 显式pedantic控制SHALL阻止VLA降级，保留NDK自身也会拒绝的错误；unused组仍独立判断

#### Scenario: 无需兼容或无法证明编译器
- **WHEN** 无全局 Werror、最后全局控制为 Wno-error、编译器无法证明或版本不匹配、参数包含未展开间接选项
- **THEN** SHALL 保留原命令并报告未应用原因，不得通过环境变量猜工具版本或扩大豁免

#### Scenario: 兼容结果再次准备
- **WHEN** 相同输入再次经过转换
- **THEN** SHALL 不增加重复选项、不重写相同 CDB 字节和 mtime，实际 build RSP 与源码保持不变
- **AND** 最终命令 SHALL 经同一 receipt 封存后供前后台消费；手工加入选项的实验不能代替流水线验收

#### Scenario: 首次加载pipeline前已经禁用兼容
- **WHEN** 注册表明确禁用了该workaround，随后首次加载CDB pipeline
- **THEN** pipeline SHALL 保持禁用状态，不得以默认apply覆盖用户选择
- **AND** 再显式启用后 SHALL 恢复单一转换步骤，注册表与运行态一致

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

#### Scenario: Legacy definition injection encounters an empty macro replacement
- **WHEN** explicit legacy injection converts an object-like `#define NAME` whose replacement is empty, including after removing comments
- **THEN** the emitted option SHALL be `-DNAME=`, preserving an empty replacement and the macro's defined state; bare `-DNAME` MUST NOT substitute the value `1`
- **AND** nonempty replacement values, `#undef` and existing explicit command-line definitions SHALL retain their existing handling
- **AND** `--preserve-exact` SHALL continue retaining the original command bytes and mtime without injecting definitions

### Requirement: Windows header filename casing SHALL not discard native index records

For the verified Windows clangd 22.1.5 behavior, preparation SHALL preserve the canonical filename
of mapped first-party headers across symbol and include-graph records. An owned identity VFS MAY correct
filename casing without changing source bytes, include-search order, cwd or original compiler options.

#### Scenario: An include spells an existing header with different filename case
- **WHEN** the compiler reads a mapped header on the supported Windows filesystem
- **THEN** native symbols and references SHALL be stored under the same physical file URI as its include graph
- **AND** preparation MUST NOT edit the header or the including source, combine distinct files, or substitute header contents

#### Scenario: Mapping unused third-party trees would slow every translation unit
- **WHEN** a selected engine/project has broad include roots containing unused SDK, third-party or foreign-engine files
- **THEN** enumeration SHALL keep the filename repair scoped to the selected engine/project's first-party headers and required filename aliases
- **AND** unmapped files SHALL retain the original real-filesystem lookup and all CDB source/command coverage; this scoped repair MUST NOT be advertised as fixing every external header
- **AND** acceptance SHALL measure the actual overlay's native parsing overhead, not only candidate generation time

#### Scenario: The same identity overlay is prepared again
- **WHEN** the final CDB already contains an owned filename-canonicalization overlay
- **THEN** preparation SHALL validate ownership before replacing its own option, and SHALL preserve identical final bytes and mtimes
- **AND** a malformed overlay, ambiguous file identity or unsupported foreign mapping MUST NOT be silently accepted as an identity mapping

#### Scenario: A previously cached mapped header has no index records
- **WHEN** a successful CDB commit introduces the owned repair and the selected tuple cache contains a mapped, non-main, error-free header shard with no symbols, references or relations
- **THEN** preparation SHALL perform a one-time migration of only those direct cache files, recording their identities and recoverable backups before moving them
- **AND** main-source, nonempty, foreign and malformed shards SHALL remain untouched; this correctness migration MUST NOT be presented as an indexing speed improvement
- **AND** the same completed migration identity SHALL skip subsequent scans and writes; an interrupted migration SHALL retain its recovery manifest
- **AND** a post-commit migration failure SHALL explicitly report that the CDB was committed, rather than claim rollback

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
