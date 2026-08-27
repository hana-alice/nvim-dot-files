# lua/utils/code_search/ — csearch 亚秒级 grep

> 继承 `../AGENTS.md`（utils）→ `../../AGENTS.md`（lua 总规则）。只写增量。

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
- **索引平台无关，全平台共用一份**（cache layout v3.2）：`ctx.paths.csearch_idx` =
  `csearch/csearch.idx`（不再按平台分片）。理由：csearch 文件清单输入平台无关，且
  `csearch_input_hash`（per-engine_root）与单份索引天然对齐。**gtags/cdb 仍 per-platform**
  （编译相关）。切平台不重建、不删 csearch；旧 `csearch/<key>/` 残留靠 freshness 判 stale
  → 下次 `:UEPrepare` 重建。见 change `refactor-search-system`。
- **增量 merge 只支持新增/替换**：fork 的 add 模式必须把 `-files-from` 中每个文件作为
  exact merge path 写入 staged index，才能替换同路径旧 trigram；删除无法由 upstream
  `index.Merge` 表达，必须走 reset。不得退回“staged names 存在但 Paths 为空”的实现，
  否则原生 merge 会 panic `inconsistent index`。
- **`<leader>/` 是 csearch-only 入口，从不加 rg**：无索引时弹可见 ERROR 引导 `:UEPrepare`、
  不开任何 picker。rg 仅存在于 ① `stream()` 内部供 gd/gr 兜底（P12）、② `<leader>sG` 显式入口。

## 改动 → 必跑回归

`utils`（加载）；行为相关另跑 `ue_goto_behavior`；更重场景跑 `csearch_build_guard`、
`ue_watch_csearch`。

## 先读

`../../../openspec/specs/ue-code-search/spec.md`（治理本目录的 capability）、
`../../../openspec/specs/project-scan-root-discovery/spec.md`（扫描根推导：索引输入集的
**范围完整性**——freshness 指纹只判集合变化，判不了集合一开始就漏了）、
`../../../README.md`（csearch 集成）、`../../../docs/architecture-symbol-resolution.md`。
