# config-regression-suite Specification

## Purpose

定义本 Neovim 配置的回归测试套件覆盖的大方向：配置加载冒烟、平台驱动契约、`ue` 模块公共
API 冻结、DAP 平台注册、工具函数加载与关键纯函数行为、以及失败可定位性。目标是「开发完跑一遍」
即可快速发现回归；本 spec 不逐字段列出所有断言细节，具体断言由 `tests/cases/*_spec.lua` 承载。

## Requirements

### Requirement: 冒烟与公共 API 冻结覆盖回归

回归套件 SHALL 覆盖 headless 启动冒烟（关键模块可 `require`、`ue.setup()` 不报错）、平台驱动
（windows/macos/linux/stub）接口形状一致、以及 `ue` 模块与子模块的公共表/函数持续存在，防止
重构误删。

#### Scenario: 核心模块与命令可用

- **WHEN** 冒烟用例运行并调用 `require("ue").setup()`
- **THEN** 关键模块成功 `require`、关键用户命令（`UEDAP*` 等）已注册
- **AND** 任一模块加载报错时该用例标记为 FAIL 并打印模块名与错误

### Requirement: DAP 平台注册与工具函数行为覆盖

回归套件 SHALL 验证 DAP 平台注册表（`register_attach`/`attach_handler`/`_reset_for_test`）与
各平台模块（win64/mac/linux/ios/android）的 `attach`/`launch` 导出符合 host/target matrix；
并对 `utils`、`ue.core` 下的纯函数（路径处理、`ue_paths` 过滤、`ue_goto` 的 semantic context/
location）做输入→输出断言，而不仅是「模块能加载」。

#### Scenario: 平台注册与纯函数行为符合契约

- **WHEN** 用例遍历平台模块并调用纯函数（如 `ue.core.fs.norm`、`utils.ue_paths.is_blocked`）
- **THEN** 只有真实 host/target matrix 支持的平台操作会注册，不兼容的 handler 为 nil
- **AND** 纯函数按既定输入返回既定输出，覆盖不仅是加载成功

### Requirement: CI 与本地维护同一回归入口

CI SHALL 在隔离配置目录执行 `tests/run.lua` 全量回归，且 Windows 原生编译器验收车道使用同一
受支持版本的 LLVM 工具链（clangd/clang/libclang/内建头文件不漂移到不同大版本渠道）；Linux/macOS
车道不强制要求 LLVM，编译相关用例在工具不满足要求时报告明确的 capability skip 而非静默跳过。
DAP/host capability smoke SHALL 使用真实 host matrix，不注入假宿主让不兼容操作看似受支持。

#### Scenario: 全新 CI checkout 且工具链一致

- **WHEN** runner 没有已有用户配置或插件缓存，且 Windows 车道拉起 LLVM
- **THEN** checkout、依赖初始化与全量回归均指向同一隔离目录
- **AND** Windows 上 clangd/clang/libclang 来自同一受支持工具链版本；缺失的必需工具直接失败
  而非静默跳过原生验收
- **AND** Linux/macOS 无强制 LLVM 要求，能力不满足时用例报告显式 capability skip

### Requirement: 套件失败可定位

回归套件 SHALL 在任意用例失败时输出 `describe > it` 归属、断言期望与实际值或错误堆栈摘要，
并以非零退出码结束，便于「开发完跑一遍」时快速排错。

#### Scenario: 失败输出包含归属与原因

- **WHEN** 任意领域用例失败
- **THEN** 输出包含用例归属与失败原因
- **AND** 整体退出码非零

## 选型与踩坑

- **选型**：用 `describe/it` 风格分组 + 纯函数输入→输出断言，而非只验证「模块能加载」——
  仅验证加载对重构中悄悄改变的行为契约（如 `ue_goto` 的 semantic context 判定规则）无防护力。
- **踩坑**：CI 原生编译器验收若跨大版本包渠道拉取 LLVM 组件（clangd 与 clang/libclang 版本不
  一致），会导致编译期证明测试基于不一致的工具链，结论不可信；处置为固定同一受支持版本渠道
  （见 headless-test-harness 的 required-native 语义）。
- **重要事项**：Linux/macOS 车道不作为 LLVM 强制验收通道是当前既定范围，非疏漏；覆盖缺口
  由 capability skip 显式暴露。
