# lua/utils/ue_goto/ — 即时 goto-definition 解析栈

> 继承 `../AGENTS.md`（utils）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

`gd`/`gr` 的多层解析栈：`jumper`（跳转 + cursor 校正）、`provider`（LSP 请求）、`cache`、
`ranking`（跨平台/.cpp 优先排序）、`pair_picker`（h/cpp 配对）、`location`（normalize/dedup）、
`symbol`（cword/receiver/arity）、`syntax_filter`（按调用签名过滤）、`csearch_fallback`、`ui`。

## 专属约定 / 分层契约（权威 CONSTRAINTS C5）

- **链路**：`treesitter 早退` → `cache(~70%)` → `clangd(LSP 权威)` → `csearch` → `gtags`，
  按「省调用 → 命中精度 → 兜底覆盖」串成单链。
- **clangd 是唯一权威源**：TS 不给答案（P11），csearch/gtags 只在 clangd MISS 时兜底（P12）。
- **每层失败必 fall through**：绝不让用户看到 `lua error in lsp_fallback`，最终兜底 toast「no def」。
- **clangd 永不前台阻塞**：spinner 600ms 后才显示，30s 硬超时。
- **jumper 后置条件**：一个 `<C-O>` 回源、恰好一条 jumplist、无 `(target_buf,1,0)` 幽灵。→ K25
- 纯函数（`ranking`/`pair_picker`/`location`）有行为回归断言，改前先看。

## 改动 → 必跑回归

`ue_goto_behavior` `utils`；复杂场景另有 `scripts/test_*.lua`（syntax_filter/ranking/pair_picker）经 legacy 旁路。

## 先读

`../../../docs/architecture-symbol-resolution.md`（全栈架构，必读）、
`../../../docs/plans/2026-04-17-instant-goto-architecture.md`。
