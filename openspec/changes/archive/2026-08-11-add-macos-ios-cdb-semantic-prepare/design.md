# Design — macOS/iOS 编译语义准备

## Context

现有实现以 Unreal response files 作为编译数据库的主要事实来源。这一方向应继续保留：response file 包含编译器实际使用的 include、define、语言标准和目标参数，比猜测参数或为头文件伪造命令更可靠。

缺口位于 response file 之前。macOS 宿主仍可能进入 Windows 专用路径和 UnrealBuildTool `.exe`，导致 `Mac`/`IOS` 目标无法完成产生 response files 的原生增量编译。同时，用户口中的“给 Neovim 语法解析编译”实际包含两层能力：

- Tree-sitter 负责语法树与高亮，不消费 `compile_commands.json`；
- clangd 负责编译器语义，需要当前目标的真实编译数据库。

因此本设计建立“显式编译，再做纯语义准备”的双阶段流程，但不进入应用打包和设备生命周期。

当前代码还混合了两种不同维度：运行 Neovim 的 host OS，以及 Unreal 要构建的 target platform。新架构必须先拆开这两个维度，否则 macOS host、Mac target 与 IOS target 会继续被误当成同一平台分支。

## Goals / Non-Goals

### Goals

- 在 macOS 上用原生 UBT 包装脚本编译 Unreal `Mac` 与 `IOS` 目标。
- 让 Android、IOS、Mac、Win64、Linux 的 target-specific 实现彼此独立，并把 host OS 选择留在现有 host-driver 层。
- 从当前 project/target/platform/configuration 的真实 response files 生成 clangd 数据。
- 让执行计划可测试、可观察、可取消，并保持 Neovim UI 响应。
- 保留 Windows、Linux 和 Android 的既有行为与公共命令兼容性。

### Non-Goals

- 不改变 Tree-sitter parser 的安装或编译方式。
- 不执行 Cook、Stage、Package、Archive、Deploy、Install 或 Run。
- 不移植或改写 Android SO 的 PowerShell 构建/部署流程。
- 不新增 macOS→Android 构建、部署或运行支持。
- 不安装或导入 clangd、Xcode、证书、provisioning profile。
- 不为缺少编译证据的头文件生成虚假 standalone 命令。
- 不实现 iOS DAP、模拟器或真机调试。

## Decisions

### 0. host driver 与 target driver 是两个正交层

现有 `lua/utils/platform/` 保持 host-driver 层，只回答“Neovim 当前运行在哪个 OS、如何执行本机工具”。新增 `lua/ue/targets/` 作为 Unreal target-driver 层，只回答“当前 Unreal target 如何 build/package/device/install/launch，以及如何识别自己的编译证据”。

建议模块边界：

```text
lua/utils/platform/
  windows.lua             # Windows host tools
  macos.lua               # macOS host tools
  linux.lua               # Linux host tools

lua/ue/targets/
  init.lua                # registry + dispatch only
  contract.lua            # driver shape validation only
  _common.lua             # stateless/policy-free helpers only
  android.lua             # Android target policy
  ios.lua                 # IOS target policy
  mac.lua                 # Mac target policy
  win64.lua               # Win64 target policy
  linux.lua               # Linux target policy
  android_windows.lua     # 既有 Android SO 的 Windows-only 兼容适配
```

核心层先解析 `host_driver` 与 `target_driver`，再把不可变 context 传给 target driver。target driver 可以请求 host driver 提供 executable/path primitives，但不得读取另一个 target driver 的状态或调用其实现。

统一 target-driver contract 至少包含：

- `id` 与 `capabilities(context)`；
- `build_plan(context, host_driver)`；
- `classify_rsp(candidate, context)`；
- 对不支持的 package/device/install/launch 返回结构化 unavailable。

`IOS` 和 `Mac` 必须分别实现 `build_plan` 与 `classify_rsp`。它们可以共同调用 `_common.lua` 的 argv 校验、路径归一化等纯函数，但 `_common.lua` 不得包含 `if IOS`、`if Mac`、默认 target、工具选择或产物策略。

现有 Android build/PowerShell/SO 逻辑迁入 `android.lua`，此迁移先由回归测试锁定，且不得趁机改变 Android 行为。`lua/ue.lua` 最终只保留命令注册、通用任务编排和 target-driver dispatch；其中不得出现 target-specific 脚本名称或 target 条件分支。

### 1. 两个入口表达两个不同副作用

`:UECompileForNvim` 是有意触发编译的入口。其流水线为：

1. 解析当前工程、target、platform 与 configuration；
2. 预检宿主构建入口与 clangd 工具链；
3. 运行 UBT 增量编译；
4. 仅在编译成功后调用现有准备管线；
5. 发布新的 CDB 状态并按需刷新 clangd。

`:UEPrepare` 保持 prepare-only。已有 response files 合法时它可以直接重建或复用 CDB；缺失时只给出可执行的 `:UECompileForNvim` 提示，绝不暗中编译。

这使自动化、CI 与用户操作可以清楚区分“读取/转换现有证据”和“创建新编译证据”。

该能力可以与 iOS 应用流程复用同一个 host-driver build entry 和 IOS target driver 的无状态 build planner，但不得调用 `UEPackageIOS`、`UEInstallIOS` 或 `UELaunch`，也不读写应用产物/设备状态。共享的是 driver contract 与纯命令规划，不是两个 workflow 的生命周期；Mac target 仍由独立 `mac.lua` 实现。

### 2. 宿主命令由 host driver 提供，目标参数由 target driver 提供

核心 UE 模块只决定目标 tuple 并执行调度；target driver 决定该目标的 UBT 参数，host driver 负责返回可执行入口与宿主路径语义。macOS host 上的计划形态为：

```text
<ENGINE_ROOT>/Engine/Build/BatchFiles/Mac/Build.sh
  <TARGET> <PLATFORM> <CONFIGURATION> -Project=<UPROJECT>
```

执行器接收 argv 数组，不拼接 shell 字符串。macOS 分支不得调用 `to_windows_path`、`UnrealBuildTool.exe`、PowerShell 或 Windows host cwd，也不得尝试 `chmod` PE 文件。

host driver 的共享基础方法保持统一返回形状；Xcode 与 PowerShell 之类宿主专属工具作为可选
capability，只由真实拥有它的 driver 暴露。调用方通过统一 resolver 把缺失 capability 转为结构化
unavailable，而不是让 macOS/Linux 提供假的 Windows 方法、调用其他 target 实现或隐式回退。

### 3. response file 继续作为唯一编译参数事实来源

准备阶段按精确 tuple 选择 response files：

```text
project + target + platform + configuration
```

候选文件必须能证明属于当前 tuple。无法证明来源、来自其他平台、其他配置或其他 target 的候选必须拒绝，并在诊断中说明拒绝原因。Apple `.cpp.o.rsp`、`.rsp` 与 `.response` 变体通过经过测试的分类器归一化，但不改写编译器语义参数。

头文件上下文继续依赖编译器产生的依赖证据和真实源文件 argv/cwd；不新增通用 fallback compile command。

### 4. 内容寻址决定是否刷新

每次成功准备记录：

- 工程与引擎身份的脱敏标识；
- target/platform/configuration；
- 被消费 response files 的相对来源与内容指纹；
- 生成 CDB 的内容指纹；
- clangd 可执行文件与版本结果。

若输入与输出指纹均未变化，准备阶段报告 no-op，不重写文件、不切换 current shard、不重启 clangd。`UECompileForNvim` 仍允许用户显式要求 UBT 增量编译；是否跳过目标编译由 UBT 自身的依赖判断负责，而不是 Neovim 猜测源码新旧。

### 5. 工具链不匹配是显式失败

仓库声明的 clangd 版本约束是语义能力契约。预检必须解析实际版本并区分：

- 找不到 clangd；
- 找到但不满足版本约束；
- 满足约束；
- 版本输出不可解析。

不满足时返回修复建议和已探测路径，不自动下载安装，也不静默退回能力较弱的系统 clangd。Tree-sitter 仍可独立工作，因此提示不得误报为“Neovim 无法解析语法”。

### 6. 长任务使用统一异步生命周期

编译与准备共享任务状态机：queued、preflight、compiling、preparing、refreshing、succeeded、failed、cancelled。取消后不得继续发布部分 CDB 或重启 clangd；失败保留旧的最后成功数据库。

输出进入既有日志/quickfix surface，包含阶段、退出码和下一步，但必须遮蔽用户目录、凭据和环境秘密。高频进度不使用通知刷屏。

### 7. 公共状态必须说明数据来源

`UECDBStatus` 或等价状态 surface 应显示当前 tuple、准备时间、response file 数量、CDB 指纹、clangd 版本及是否 no-op。状态不得把 Tree-sitter parser 状态和 clangd CDB 状态合并成一个模糊的“解析成功”。

## Risks / Trade-offs

- UBT 在仅需刷新语义时仍可能执行昂贵编译。通过保留纯 `UEPrepare` 入口，让已有 response files 的场景不触发编译。
- Apple response file 命名随 UE/Xcode 版本变化。分类器必须基于内容和 tuple 证据，而不是只依赖文件名。
- 扩展平台驱动会触及所有宿主实现。统一返回结构与契约测试可防止 Windows/Linux/Android 回归。
- 抽取现有 Android target 逻辑会扩大机械改动范围。先锁定行为、只移动平台策略，并禁止在同一步重写算法或 UX。
- 严格 clangd 版本门槛可能阻止“勉强可用”的系统工具链，但比产生不可复现的语义结果更诚实。

## Migration Plan

1. 先为现有 Android/Win64/Linux target 行为、host driver 和 CDB 行为补充回归测试。
2. 引入 target-driver registry/contract，并把 Android target 策略等价迁出核心文件。
3. 分别建立 `ios.lua` 与 `mac.lua`，实现各自纯 build/RSP 规划；不得互相调用。
4. 在 host-driver 层增加统一宿主构建入口并接入 macOS `Build.sh`，保持现有 Windows/Linux host 行为。
5. 扩展 IOS/Mac 各自 response file 分类和 tuple 隔离。
6. 添加 `UECompileForNvim` 异步编排并复用 `UEPrepare`。
7. 添加 provenance/no-op/clangd 版本状态。
8. 更新 README、architecture overview、cheatsheet 与 headless 测试；确认核心层无 target-specific 分支，并且无 Android SO、打包或设备副作用。

回滚时可移除新命令和平台驱动入口；已有 `UEPrepare` 与最后成功 CDB 仍保持可用。
