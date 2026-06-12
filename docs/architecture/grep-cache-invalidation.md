# Grep 缓存失效与平台分路径 · 模块设计

> 子系统：`lua/utils/code_search/` + `lua/ue.lua`（cache_paths / resolve_context /
> set_project / set_platform / prepare）+ `lua/plugins/snacks.lua`（grep keymaps）。
> 关联：`docs/architecture/overview.md` §2 数据流；`lua/utils/code_search/CLAUDE.md`；
> `docs/CONSTRAINTS.md §二/§三`。
> 引入：2026-06-11，修复 `<leader>/` 静默搜不全。

## 1. 问题背景

`<leader>/`（`ue_project_grep` → `ue.cached_grep`）在某些会话里只返回残缺结果，
picker 标题为 `Grep All Code (Engine+Project)`（**无 `[csearch]`/`[rg]` 后缀**）。

三方诊断（命令行 csearch/rg、headless `cached_grep`、GUI 内 `diag_grep_why.lua`）证明：
健康态下三条路径都返回完整结果——**无静态 bug**。无后缀标题 = `cached_grep` 返回 nil
→ `ue_project_grep` 静默回落到最底层 `snacks.picker.grep` 目录遍历（排除 ThirdParty、
与索引无关 → 漏结果）。运行诊断脚本后"突然变全" → 坏在**会话级缓存**。

### 四个根因/缺口

| # | 缺口 | 后果 |
|---|------|------|
| 1 | `code_search` 的 `csearch_exe`/`cindex_uefilter_exe` **永久缓存负探测** | 冷启动/重建期一次探测失败 → 整会话 `is_indexed()=false` → grep 永远走回落 |
| 2 | `cached_grep` 返回 nil 时**静默回落** | 用户拿到残缺结果却无任何提示，以为搜全了 |
| 3 | 失效逻辑不全：engine_root 未持久化；`UESetPlatform` 不碰 grep 缓存；UEPrepare 完成不清 context_cache | 状态变了缓存没失效（与 #1 同源） |
| 4 | `code_search.stream` 旧实现逐行 `vim.schedule(on_line)`、exit callback 另行 `vim.schedule(on_done)` | `on_done` 可能先于尾部 `on_line` 被 picker drain loop 观察到，最后几条命中滞留、表现为结果不全 |

## 2. 设计决策

### D1 — 负探测不缓存（`code_search/init.lua`）

`csearch_exe()` / `cindex_uefilter_exe()` **仅在探测成功时缓存路径**；失败返回 nil
但不置 probed 标志，下次重试。新增 `M._reset_probe_cache()` 供 UEPrepare 完成、
切项目/平台后强制重探。

理由：一次冷启动期（PATH/`vim.env` 未就绪）或索引重建期的失败，不得污染整个会话。
探测成本低（几次 `executable()`），miss 时重探可接受。

### D2 — 回落可见（`ue.lua` cached_grep + `snacks.lua`）

- `cached_grep` 在拿不到 cached file list（要 return nil → 最慢目录遍历）时，
  发一次性 `WARN`（`vim.b._ue_grep_fallback_warned` 去重，**不做 ticker**，遵守 P5）：
  "no csearch index and no cached file list — falling back to slow dir walk that may MISS files. Run :UEPrepare"。
- `ue_project_grep` 回落分支标题改为 `Grep All Code (slow fallback — run :UEPrepare)`，
  让缺后缀不被误认为完整结果。

### D3 — csearch/workspace_all **按平台+配置分路径**（`cache_paths`）

与 cdb shard 的平台维度对齐。**只有 grep-facing 工件**分平台：
- `csearch_idx` → `csearch/<platform_key>/csearch.idx`
- `workspace_all_list` / `workspace_list` / `project_list` / `engine_list` → `gtags/<platform_key>/*.files`
- `workspace_db`（GTAGS DB）→ `gtags/<platform_key>/workspace/`

`platform_key` 空时**回落旧单一路径**（向后兼容 + 迁移源）。
`state.json` / cdb shards（已内部按 key 分）/ clangd index / pch / logs / runtime **不分平台**。

`platform_key` 由 `CORE_RT.platform_key_from_state(state)` 生成：
`"<Platform>-<Config>"`，config 剥离 ` Editor` 后缀（与 shard config 段一致），
无 platform → `""`。**与 `ue.cdb.shards.shard_key` 同源的平台维度**（无 target 段，
因 state 只有 platform+config）。

理由：用户切平台（Android↔Win64）应保留两边 csearch 索引，切平台不删重来——
与 cdb shard 模型一致（用户既往明确诉求）。

### D4 — 旧缓存自动迁移（`CORE_RT.migrate_legacy_csearch_if_needed`）

参照 `shards.migrate_legacy_if_needed`。检测旧单一路径
（`csearch/csearch.idx` + `gtags/*.files`）存在、且当前 platform_key 目录为空时，
**move（os.rename，同卷）**进平台目录。`resolve_context` 末尾幂等调用（platform_key≠"" 时）。
幂等：移完旧路径即空，后续 no-op。新目录已有索引时**不覆盖**。

### D5 — 失效触发矩阵

| 触发 | engine 变 | project 变 | platform 变 |
|---|---|---|---|
| **入口** | `set_project`（比对 state.engine_root） | `set_project`（比对 state.project_root） | `set_platform` |
| **csearch/workspace_all** | 删全平台（`invalidate_project_scoped_cache` rm `csearch/`+`gtags/` 整树） | 删全平台 | **不删**（切到 `csearch/<新key>/`，旧平台保留） |
| **cdb shards** | 删 `shards/` 整树 | 删 `shards/` 整树 | fast-swap flip active（不删） |
| **context_cache** | 清 | 清 | 清 |
| **probe cache** | 重探 | 重探 | 重探 |
| **engine_root 持久化** | `persist_project` 写入 state.engine_root，使 engine 维度判定有据 | — | — |

UEPrepare（同步 + 异步 finalize）完成后：清 `context_cache`+`freshness_notified`+重探——
修复"重建期建立的无索引 ctx 在 TTL 内被命中"（#1 同源）。

### D6 — stream 交付顺序：单一 flusher 保证 `on_line` 先于 `on_done`

`stream_csearch` / `stream_rg` 不再为每条命中单独 `vim.schedule(on_line)`。stdout read
callback 同步解析输出并追加到 backend 内部 `parsed` 队列；一个 scheduled flusher 负责交付
所有 parsed-but-undelivered 命中。进程 exit callback 只记录退出状态并请求最终 flush。

flusher 的顺序固定为：先 drain backlog → 再在 `proc_exited=true` 且 backlog 为空时调用
`on_done`。stop() 先设置 `stopped=true`，再 kill/close 进程，所有已排队 flusher 在触碰
picker 前都检查 `stopped`。

理由：snacks finder 的 drain loop 以 `on_done` 设置的 done 状态决定何时停止等待；如果
`on_done` 先于尾部 `on_line` 被处理，那些尾部命中即使已经由子进程输出，也不会进入 picker。

## 3. 失效正确性论证

- **engine 变**：旧 `set_project` 只比 project_root；engine 换了（同 project 指向新引擎）
  缓存不失效。现持久化 engine_root + 比对 → 修复。
- **platform 变不删**：D3 让不同平台落不同路径，天然隔离；新平台无索引时 D2 可见回落
  提示 `:UEPrepare`，不给残缺静默结果。
- **重建期负探测**：D1（不缓存负探测）+ UEPrepare finalize 重探，双保险。
- **stream 尾部命中**：D6 让 backend 只从一个 flusher 交付命中和 done，消除 callback
  调度顺序竞争。

## 4. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `cache_paths` 布局变更影响面大 | platform_key="" 完全回落旧路径，老缓存零破坏；D4 move-once 幂等；spec 守护布局 |
| 跨盘绝对路径（E 工程/D 引擎） | 迁移/分路径仅改缓存落点，不碰路径内容生成；既有 cross-drive guard 不受影响 |
| watch 模块索引路径 | `ue_watch.start` 的 `csearch_index` 入参随 ctx.paths 自动指向平台目录，无需额外改 |

## 5. 测试

- `tests/cases/grep_cache_spec.lua`（16 例）：cache_paths 分路径/回落、fallback 可见性、
  platform_key 生成、迁移 move+幂等+不覆盖+空 key、engine_root 往返。
- `tests/cases/utils_spec.lua`（扩充）：`_reset_probe_cache` 存在/幂等、`is_indexed` 无索引安静返回 false、
  rg stream 的 `on_done` 排序与 stop 后不回调。
- 回归范围：跨子系统（ue.lua + code_search + snacks）→ 提交前全量
  `nvim --headless -l tests/run.lua`。

## 6. 公共 API 增量（M.*）

- `M._reset_probe_cache`（code_search）
- `M.cache_paths` / `M.platform_key_from_state` / `M.migrate_legacy_csearch_if_needed`（ue，测试 seam）
