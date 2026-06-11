# lua/utils/ — 通用工具模块

> 继承 `../CLAUDE.md`（lua 总规则）。只写增量。

## 用途

跨子系统复用的工具：`platform`（OS 分支唯一收口）、`log`（旋转日志）、`lsp_fallback`（gd/gr 兜底）、
`ue_goto/`（goto 解析栈）、`code_search/`（csearch）、`ue_paths`（路径分类）、`sidebar`/`cheatsheet`/
`restart`/`recent_projects`/`async_launcher`/`ue_watch`/`ue_launch`/`ue_logs`/`dirty_files` 等。

## 专属约定

- **OS 分支只在 `platform/`**：其余 utils 读 `platform.is_*` 或 `platform.driver()`，不自己分支。→ 见 `platform/CLAUDE.md`
- **LSP 行为只走 `lsp_fallback.lua`**，不全局覆盖 `vim.lsp.handlers`。→ P3
- 纯函数模块（`ue_paths`、`ue_goto/ranking|pair_picker|location`）有行为回归，改契约前看断言。
- 单一职责、小文件：新功能优先新模块而非堆进现有大文件。

## 改动 → 必跑回归

- 改 `ue_goto/**` / `code_search/**` / `ue_paths.lua` → `ue_goto_behavior` `ue_paths` `utils`
- 改 `platform/**` → `platform`（另见子目录 `CLAUDE.md`）
- 改被广泛复用的 helper（如 `log`、`ue_paths`）→ 提交前全量

## 先读

`../../docs/architecture-symbol-resolution.md`、`../../docs/architecture/overview.md` §5。
