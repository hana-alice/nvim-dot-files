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
- **负探测不缓存**：`csearch_exe`/`cindex_uefilter_exe` 只在探测成功时缓存路径；
  失败返回 nil 但不钉死——冷启动 PATH 未就绪/索引重建期的一次失败不得让整会话
  `is_indexed()=false`（曾导致 `<leader>/` 静默走最慢目录遍历、搜不全）。
  UEPrepare 完成 / 切项目 / 切平台后调 `_reset_probe_cache()` 强制重探。→ 见
  `../../../docs/architecture/grep-cache-invalidation.md`
- **索引按平台+配置分路径**：`ctx.paths.csearch_idx` = `csearch/<Platform>-<Config>/csearch.idx`
  （由 `ue.cache_paths(root, platform_key)` 推导）。切平台不删旧平台索引。

## 改动 → 必跑回归

`utils`（加载）；行为相关另跑 `ue_goto_behavior`；`scripts/test_cached_grep.lua` 为更重场景。

## 先读

`../../../README.md §8`（csearch 集成）、`../../../docs/architecture-symbol-resolution.md §6`。
