# lua/utils/code_search/ — csearch 亚秒级 grep

> 继承 `../CLAUDE.md`（utils）→ `../../CLAUDE.md`（lua 总规则）。只写增量。

## 用途

trigram 索引（google/codesearch 的 csearch）驱动的亚秒级 live grep，UE 万级文件可用；
索引由 `tools/cindex-uefilter`（Go fork，`-files-from`）构建。rg 作为无索引时的兜底后端。

## 专属约定

- **csearch / gtags 不做主路**：文本/ctags 搜索分不清重载/同名/namespace，只在 clangd MISS 时兜底。→ P12
- **不用 zoekt 替代**：Windows 不可用，已论证死胡同。→ P13
- 后端优先级：`csearch（有索引）` → `rg`；`current_backend(ctx)` 决策，调用方不假设。
- 流式 API（`stream` + `on_line/on_done`）async，不阻塞主线程；stop() 后不得再回调（snacks「yielded after done」陷阱）。

## 改动 → 必跑回归

`utils`（加载）；行为相关另跑 `ue_goto_behavior`；`scripts/test_cached_grep.lua` 为更重场景。

## 先读

`../../../README.md §8`（csearch 集成）、`../../../docs/architecture-symbol-resolution.md §6`。
