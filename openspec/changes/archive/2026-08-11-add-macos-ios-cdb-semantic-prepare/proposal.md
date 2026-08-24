# Proposal — add-macos-ios-cdb-semantic-prepare

## Why

当前 Unreal 编辑能力虽然允许选择 `Mac` 与 `IOS`，但编译入口仍残留 Windows 路径转换、`.exe` UnrealBuildTool 与 Windows 工作目录假设。结果是 macOS 上无法可靠地产生当前目标的 response files，也就无法向 clangd 提供可信的编译上下文。

这里必须区分两个概念：Tree-sitter 语法高亮直接解析源码，不依赖 Unreal 编译；需要编译数据库的是 clangd 的语义导航、诊断、补全和索引。本变更只解决后者，不承担 iOS 打包、签名、安装或设备启动。

## What Changes

- 新增 `:UECompileForNvim`：使用宿主平台原生 UnrealBuildTool 包装脚本执行增量编译，成功后复用 `:UEPrepare` 生成当前上下文的编译数据库并刷新 clangd。
- 保持 `:UEPrepare` 为纯准备操作：只消费已有 response files，不触发编译、Cook、Package、Deploy 或 Run。
- 新增 Unreal target-driver 层：`Android`、`IOS`、`Mac`、`Win64`、`Linux` 分别拥有独立模块；核心调度层不得保存平台特定命令、路径、RSP 分类或生命周期策略。
- 保留独立的 host-driver 层：Windows、macOS、Linux 只声明当前宿主如何找到和执行工具；macOS host 使用 `Engine/Build/BatchFiles/Mac/Build.sh`，禁止 Windows 路径转换、执行 PE 文件或为 `.exe` 修改权限。
- `IOS` target 与 `Mac` target 必须分别实现 build/RSP 规则，即使它们都运行在 macOS host；只允许复用无状态、无平台策略的通用辅助函数。
- 将现有 Android build 规则从核心文件迁入 Android target driver，保持行为不变，避免新增 Apple 支持继续扩大 Android/Windows 条件分支。
- 将 response files 严格限定到当前 project/target/platform/configuration；拒绝以其他平台或配置的参数填充当前数据库。
- 记录 response file 来源、上下文和内容指纹；内容未变化时跳过无效写入与 clangd 重启。
- 对 clangd 版本与仓库工具链约束做显式预检；不静默接受能力不足的系统 clangd，也不自动安装工具链。
- 所有长任务保持异步、可取消，并将可执行 argv、工作目录、阶段与失败原因以脱敏形式呈现。

## Capabilities

### New Capabilities

- `macos-ios-cdb-semantic-prepare`：在 macOS 宿主上为 Unreal `Mac`/`IOS` 目标生成编译器真实、上下文隔离且可追溯的 clangd 编译数据库。

### Modified Capabilities

- 无。现有 C++ 语义身份规则保持不变；本变更只补齐其 Apple 平台输入链路。

## Impact

- 预计新增 `lua/ue/targets/` registry、contract 与每目标独立 driver，并修改 `lua/ue.lua`、host platform driver、UE 配置与编译数据库相关模块。
- 预计增加 macOS 原生命令规划、IOS/Mac response file 分类、上下文隔离、增量跳过和失败路径测试。
- 预计更新命令说明、cheatsheet 与 UE IDE bootstrap 文档，明确 Tree-sitter 与 clangd 的职责边界。
- 不引入新依赖，不修改 Unreal Engine 或游戏工程源码，不处理 Android SO 构建/部署、证书、设备和原生 iOS 调试。
