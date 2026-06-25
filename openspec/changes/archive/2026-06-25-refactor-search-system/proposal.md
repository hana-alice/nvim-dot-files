## Why

`<leader>/`（工程级 grep）距离 Rider 的 Find-in-Files 体验仍有差距，问题集中在**呈现层**与**入口策略**，而非搜索引擎本身——csearch（trigram 索引）已是 Windows 上「索引 + 正则 + 可用」交集里唯一存活的方案（zoekt 已论证为 Windows 死胡同 → P13；Everything 1.5 内容索引文档明确「不为源码树设计、≤1GB、无正则」；rg/ugrep 无索引、慢在 NTFS 遍历）。本 change 不换引擎，做三件「小幅度重构」：

1. **csearch 索引去平台化**。当前 csearch 索引按 `csearch/<platform_key>/` 分片（cache layout v3.1），但生成该索引的文件清单（`workspace_all.files`）的**输入是平台无关的**：`picker_search_dirs` 只读 `engine_root` + `project_root` + 平台无关的 `ENGINE_PICKER_DIRS` / `SCAN_EXCLUDES` / `.ueprepare-scan-paths` 白名单，**没有任何平台条件参与文件集构成**（代码坐实，见 design.md「风险1 证伪」）。更关键：freshness 校验用的 `csearch_input_hash` 本就存在 `state.json`（per-engine_root，**非 per-platform**）——也就是说**校验维度（一份）与索引维度（N 份）当前已经不一致**。去平台化让两者重新对齐，同时切平台不再重建 csearch 索引、磁盘省 N 倍。

2. **`<leader>/` 去 rg + UI Rider 化**。`<leader>/` 入口不再静默降级到 rg；无 csearch 索引时明确报错引导 `:UEPrepare`。rg **一行不删**——它在 `code_search.stream()` 内部是 gd/gr 跳定义兜底（`csearch_fallback`）的承重梁（P12 要求每层 fall through），且 `<leader>sg`/`<leader>sG` 已是显式 rg 入口。去 rg 只发生在 `<leader>/` 这一个调用点。UI 侧补齐 Rider 风格：可视化 大小写/全词/正则 toggle、preview 高亮与布局、面板内 scope 过滤、结果按文件分组 + 命中计数 + 后端状态标识。

3. **UEPrepare 对 csearch 的校验强化**。去平台化后，校验维度统一（指纹一份 / 索引一份）。`:UEPrepare` 全量构建成功后 SHALL 断言索引可用并记录输入指纹；freshness 失效语义简化为「文件集变更」单一维度。

## What Changes

### 能力1：csearch 索引去平台化（破坏性：缓存布局）

- `cache_paths` 的 `csearch_idx` 路径从 `csearch/<platform_key>/csearch.idx` 改为 `csearch/csearch.idx`（全平台共用一份）。**gtags / cdb 维持 per-platform 不变**（它们是真·平台相关：cdb 的编译参数/宏/include 按平台不同——承重梁不动）。
- 迁移：去平台化后的扁平路径恰好是 v3.1 之前的 legacy 布局。需提供「平台子目录 → 扁平」的迁移（取任一现存平台索引提升为共用，或标记 stale 让首次 `:UEPrepare` 重建），避免用户被迫手动重建。
- `csearch_input_hash`（已是 per-engine_root）无需改维度——本就与去平台化后的索引对齐。

### 能力2：`<leader>/` 去 rg + UI 重构

- **入口从不加 rg**：`ue_project_grep`（`<leader>/`）SHALL **只**走 csearch。无 csearch 索引时 MUST NOT 回落到任何 rg / 目录遍历路径——移除 `cached_grep` 的三处 rg 暗门（rg-batched fallback、`return nil`→snacks 目录遍历、rg fast-path `ue_grep_rg`），改为可见报错 + 引导 `:UEPrepare`，且不打开任何 picker。`code_search.stream()` 内部 rg 分支**保留**（gd/gr 兜底依赖，P12，另一个调用点）。`<leader>sG`（`ue_grep_all`）维持专用 rg 入口不变。
- **结果分组 + 计数 + 后端状态**：grep 结果面板按文件分组、每文件显示命中计数；标题栏显示当前后端 `[csearch]` 与 scope。
- **可视化 toggle**：`<A-w>` 全词 / `<A-c>` 大小写 / `<A-r>` 正则，状态渲染在标题栏；内部翻译为既有 rg/csearch flag 语义，用户不再背 `-- -w/-s/-F`。
- **preview 高亮与布局**：preview 高亮匹配词、可调上下文行数 / 布局比例。
- **面板内 scope 过滤**：在 `<leader>/` 面板内一键切「当前模块 / 插件 / 目录」scope，不必另走 `<leader>uO`。

### 能力3：UEPrepare 对 csearch 的校验强化

- `:UEPrepare` 全量构建成功后 SHALL 断言 `csearch.idx` 可用（存在且超过最小有效阈值），并记录 `csearch_input_hash`（已有 `on_full_csearch_success` 逻辑，去平台化后维度天然统一）。
- freshness 失效维度简化：去掉「切平台 → 换一份索引」这一维，只保留「文件集内容指纹变更」+「watcher persistent_dirty」+「存在性」。

## Capabilities

### Modified Capabilities
- `ue-code-search`：
  - **REMOVED**「grep-facing caches SHALL be isolated by platform」对 **csearch 索引** 的约束（gtags 仍 per-platform，措辞收窄到 gtags/cdb）。
  - **MODIFIED**「`<leader>/` SHALL prefer complete indexed search」：去掉 rg 中间档与目录遍历兜底；改为「有 csearch 用 csearch，无 csearch 报错引导 :UEPrepare」。
  - **MODIFIED**「legacy grep caches SHALL migrate」：新增「平台子目录 → 扁平」的 csearch 迁移方向。
  - **ADDED**「`<leader>/` 结果呈现」契约（分组 / 计数 / 后端状态 / 可视化 toggle / scope）。
  - 其余契约（单写者、串行化、增量拒绝、freshness 用指纹、记录指纹、指纹缓存）**保留**，仅在措辞上把「per-platform 索引」相关引用对齐到去平台化后的单份索引。

## Impact

- 修改运行时代码：`lua/ue.lua`（`cache_paths` csearch 路径、迁移、UEPrepare 校验、`ue_project_grep` 入口去 rg）、`lua/plugins/snacks.lua`（grep 面板 format / actions / toggle / scope）、可能 `lua/utils/code_search/init.lua`（措辞/注释对齐，rg 分支不删）。
- **不动**：gtags/cdb 的 per-platform 分片、`stream()` 内 rg 分支（gd/gr 兜底）、P13（不换引擎）。
- 缓存破坏：首次升级后 csearch 索引路径变更——迁移逻辑兜底，最坏情况一次 `:UEPrepare` 重建。
- 测试：`utils`、`ue_goto_behavior`、`scripts/test_cached_grep.lua`、`grep_cache_spec`、`csearch_build_guard_spec`、`keymap-command-regression`（若键位/命令冻结清单变化）。影响面跨缓存布局 + 入口策略 + UI，**提交前必跑全量** `nvim --headless -l tests/run.lua`。
- 文档：`docs/changelog.md`（Unreleased + Validation）、cheatsheet / README 键位与 grep 用法、`code_search/CLAUDE.md`（去平台化后布局说明）、`cache_paths` 注释（v3.x 布局）、`grep-cache-invalidation.md`（失效维度简化）。
