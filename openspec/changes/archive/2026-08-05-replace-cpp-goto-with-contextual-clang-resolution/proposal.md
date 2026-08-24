## Why

当前 C++ `gd` 会把某次 clangd 结果按 `receiver::symbol` / 裸 `symbol` 持久化，并在后续调用中先于实时语义请求复用。该键不包含调用位置、重载身份、编译配置或 TU 上下文，已在 `SubmitActiveCmdBuffer` 反例中把无参重载缓存错误地复用于同名的一参调用；同时，非自包含 UE 头文件被 clangd 作为主文件解析时可能产生恢复 AST，无法给出唯一重载目标。

必须把 C++ 定义跳转收敛为“真实 Clang TU 语义是唯一权威”：能证明唯一目标才跳，语义上下文缺失、无效或确有多义时明确呈现状态，任何时候都不得用参数个数、文本搜索、距离排序或同名缓存猜答案。

## What Changes

- 新增上下文感知的 C++ 定义导航合同：`.cpp` 使用当前 TU，头文件使用可证明的 origin TU / 用户明确选择的 TU 上下文进行 Clang 语义解析。
- 以 Clang 解析得到的 referenced declaration 与稳定语义身份（USR）区分重载；声明与实现落点策略建立在该身份之上，不再按名字筛选候选。
- **BREAKING**：C++ `gd` 不再读取或写入按符号名持久化的 definition cache，也不再在语义失败时自动跳入 csearch / GTAGS 结果。
- **BREAKING**：Tree-sitter arity、receiver 推断、workspace symbol、同文件优先和候选 ranking 均不得决定或否决 C++ `gd` 的目标。
- 为非自包含头文件提供仓外、项目外的本地 Clang semantic sidecar，复用当前 active compile database 和真实 donor TU；不得修改 UE 引擎或项目源码。
- 定义可验证的 resolved / ambiguous-context / invalid-semantic-context / unavailable 状态，并为后 3 种状态提供诚实诊断而非静默猜测。
- 建立真实编译数据库集成回归，覆盖同 arity 不同类型、模板、ADL、默认参数、cv/ref、继承重载、未保存内容和平台 / 配置切换。

## Capabilities

### New Capabilities

- `cpp-contextual-definition-navigation`: 规定 C++ `gd` 的真实 TU 上下文、Clang 语义权威、重载身份、缓存一致性、失败语义、性能与回归合同。

### Modified Capabilities

- 无。

## Impact

- 主要影响 `lua/utils/lsp_fallback.lua` 与 `lua/utils/ue_goto/` 下的 provider、cache、symbol、UI 和跳转编排。
- 新增本地异步 semantic sidecar 及其进程生命周期 / JSON-RPC 协议；优先使用现有 LLVM 22 `libclang.dll`，不修改引擎与项目代码，不引入网络服务。
- compile database、active platform / configuration、导航来源 TU 与未保存 buffer 内容成为语义请求输入。
- csearch / GTAGS 保留为显式文本搜索能力及非 clangd 文件类型后端，但退出 C++ `gd` 自动决策链。
- 现有按 arity 过滤和按名字 definition cache 的行为测试将被语义集成测试替换；全量 Neovim 回归仍是提交门禁。
