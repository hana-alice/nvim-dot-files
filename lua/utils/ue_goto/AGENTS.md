# lua/utils/ue_goto/ — C++ 语义导航与非 C++ 兼容栈

> 继承 `../AGENTS.md`（utils）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

`semantic_context`（proven build provenance）、`semantic_protocol`（versioned NDJSON）、
`semantic_sidecar`（libclang CDB/TU/USR + module definition lookup）、
`semantic_sidecar_definition`（controlled CDB + C shim exact-USR body traversal）、
`semantic_client`（异步进程、不可变 transaction 与 context 生命周期）、
`semantic_navigation`（C++ coordinator/explain/probe，`lsp_fallback` 的薄编排后端）、
`provider`（secondary clangd exact-cursor 请求）、`jumper`（跳转 + jumplist）、
`location`（normalize/dedup）。
`cache` / `csearch_fallback` / GTAGS 只服务非 C++ compatibility path、references 或显式搜索。

## 专属约定 / 分层契约（权威 CONSTRAINTS C5）

- **C++ source/header identity**：active CDB / compiler-emitted origin evidence 证明后，只接受
  libclang exact-cursor canonical USR；virtual call 保留静态语义选中的 derived override USR。
- **C++ destination**：先用该 USR 查 subject 所属 controlled module AST 的唯一 body；module
  contexts 暂不可用时才允许 identity-verified clangd 协助，零个/多个 body 均 fail closed。
- **诚实失败**：C++ 只有 `resolved / ambiguous-context / invalid-semantic-context / unavailable`；
  非 resolved 不跳转，也不进入 cache、arity、workspace symbol、csearch 或 GTAGS。
- **缓存边界**：缓存 live TU，以及绑定 canonical USR + CDB signatures + overlays + toolchain 的
  唯一 resolved destination；negative/ambiguous 结果和 symbol/receiver/arity location 禁止缓存。
- **永不前台阻塞**：parse/reparse 只在 sidecar，spinner 600ms 后显示，request 有 stale 门禁。
- **jumper 后置条件**：一个 `<C-O>` 回源、恰好一条 jumplist、无 `(target_buf,1,0)` 幽灵。→ K25
- 任何 context 选择都必须有 provenance；basename、目录距离、最近使用均不是证据。

## 改动 → 必跑回归

`cpp_semantic_context` `cpp_semantic_client` `cpp_semantic_sidecar` `ue_goto_behavior` `utils`；
legacy 旁路只剩 `scripts/test_jumper_headless.lua`。

## 先读

`../../../docs/architecture-symbol-resolution.md`（当前权威架构，必读）。

**治理 spec**（可观察行为的权威；与本文冲突时以 spec 为准）：
`../../../openspec/specs/cpp-contextual-definition-navigation/spec.md`、
`../../../openspec/specs/cpp-semantic-highlighting/spec.md`。
