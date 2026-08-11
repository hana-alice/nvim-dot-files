# Proposal — add-nvim-core-functionality-audit

## Status

**IMPLEMENTED — 2026-08-11；待 OpenSpec CLI 可用后 strict validate/archive。**

本 change 已定义并实现“Neovim 基本功能是否真实可用”的检查契约；审计仍禁止自动安装工具、
更新 parser、构建 UE 工程或写入现有索引。

## Why

当前 `nvim --headless -l tests/run.lua` 已覆盖 774 个契约、纯逻辑和 fixture 用例，但“测试全绿”
与“本机真实功能可用”仍有明确间隙：

- `smoke_spec.lua` 验证关键 Lua module 可 `require` 和命令可注册，但不等于完整 `init.lua`、LazyVim
  plugin graph 和真实启动阶段无错误。
- Tree-sitter 配置声明安装 `c`、`cpp`、`hlsl` parser，但现有回归没有逐个加载真实 parser、解析
  fixture 并检查 syntax tree/error node。
- csearch 回归覆盖 backend 选择、索引韧性、并发和 `rg` fallback，但没有在临时语料上完成真实
  `cindex-uefilter → csearch → dispatcher` 查询闭环。
- clangd/CDB、C++ definition 和 UE target driver 已有大量契约测试，但本机工具版本、真实 CDB
  provenance、LSP attach 与 live workspace 证据属于另一层，不能被 mock/fixture 结果代替。
- GUI、真机、DAP、签名和大型 UE workspace 依赖外部状态；缺失这些条件时应报告明确 gate，不能让
  整份健康报告误绿或误红。

因此需要一个只读、可重复、按 capability 分层的健康审计，把“基础编辑器正常”“某个外部能力被阻塞”
和“真实功能回归”明确区分。

## What Changes

- 新增一个统一的 read-only health runner，支持 headless 文本输出和结构化 JSON evidence。
- 新增 capability matrix，分别检查：
  - 完整配置启动、基础 buffer/file/option/autocmd、命令和 keymap；
  - Tree-sitter parser discovery、真实 AST 解析与 error-node 判定；
  - `rg` fallback，以及具备工具时的真实 cindex/csearch 临时索引查询；
  - clangd 版本、CDB 结构/provenance、fixture semantic probe 和可选 live UE smoke；
  - UE context、target registry/plan、异步任务生命周期与重复 setup 稳定性。
- 每项只允许 `PASS`、`FAIL`、`BLOCKED`、`SKIP`；总结果不得用单一布尔值掩盖外部 gate。
- 所有可写探测只允许进入新建临时目录并在结束时清理；不得修改工程、插件、parser、CDB、csearch
  index、设备或签名配置。
- 更新测试映射和使用文档，说明 deterministic fixture audit 与 optional live-workspace audit 的边界。

## Capabilities

### Added Capabilities

- `nvim-core-functionality-audit`：以分层、只读、可机器判定的证据检查 Neovim 基础编辑、
  Tree-sitter、csearch、clangd/CDB、UE 集成和异步稳定性。

## Non-goals

- 不替代现有 774 项回归套件，也不以健康 runner 重写已有 spec。
- 不在 audit 中执行 `TSUpdate`、plugin sync、工具下载、`:UEPrepare`、UE build/package/install/run。
- 不承诺 GUI 像素级渲染、真实 DAP、Android/iOS 真机或签名 E2E；这些只能作为显式 optional gate。
- 不采集或持久化完整用户路径、设备 identifier、证书身份、工程名称或环境秘密。
- 不进行性能优化；只记录有界的启动/解析/查询耗时证据，超阈值时报告而不自动调参。

## Impact

- 预计新增：`scripts/nvim_core_health.lua`、`tests/cases/core_health_spec.lua` 及最小 fixture。
- 预计修改：`docs/testing-regression.md`、`tests/AGENTS.md`、README/cheatsheet、changelog。
- 不新增依赖；复用 Neovim、已安装 Tree-sitter parser、`rg`、csearch/cindex、clangd 和现有 UE smoke。
- deterministic 部分进入全量回归；live workspace、GUI、设备和签名部分只在显式请求时运行。
