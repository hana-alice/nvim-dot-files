# Grep 缓存失效与平台分路径 · 模块设计

> 子系统：`lua/utils/code_search/` + `lua/ue.lua`（cache_paths / resolve_context /
> set_project / set_platform / prepare / **prepare_freshness**）+ `lua/utils/ue_watch.lua`
> （**增量 csearch provider**）+ `lua/plugins/snacks.lua`（grep keymaps）。
> 关联：`docs/architecture/overview.md` §2 数据流；`lua/utils/code_search/CLAUDE.md`；
> `docs/CONSTRAINTS.md §二/§三`。
> 引入：2026-06-11，修复 `<leader>/` 静默搜不全。
> 扩充：2026-06-16，D7（watcher 增量入索引经 `-files-from`，修 ENAMETOOLONG）+
> D8（freshness anchor 改 commit-state，修 fsmonitor 假 stale）。
> 2026-06-17：D7→D9（csearch 单写者，修 corrupt 死循环）；D8→D10（freshness 改内容指纹，
> 退役所有 mtime 代理 anchor，修编译产物 touch 假 stale）。

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

### D7 — watcher 增量 csearch 入索引（已被 D9 取代 / 退役，仅存档）

> **状态（2026-06-17）：D7 的「watcher 写 csearch 索引」整体退役，被 D9 取代。**
> 下面保留原始记述作为决策链存档；当前实现以 **D9** 为准——watcher 不再写 csearch.idx。

D7（2026-06-16）把 `ue_watch` 的 `provider_csearch_add` 改为委托
`code_search.build_index(.., {mode="add"})`（`cindex-uefilter -files-from <临时文件>`），
修掉了老 argv fan-out 的 `ENAMETOOLONG`。**但它引入了一个更深的问题**：watcher 由此成为
csearch.idx 的**第二个写者**，与用户的 `:UEPrepare` 全量构建并发写同一个索引。cindex 把
staged 路径硬编码为 `<idx>~`，两个写者抢同一个 `idx~`，在 merge/rename 窗口互毁 →
`corrupt index: remove` + 0 字节 idx 死循环（2026-06-17 现场）。

D7 当时的论证「失败仅 log，未入索引的路径由 persistent_dirty + rg-on-dirty overlay 兜底」
其实**已经预示了 watcher 自动增量不是 load-bearing**——既然 overlay 已兜底，自动写索引的
收益极窄（编辑到下次 prepare 之间的窗口），却换来永久并发写危险面。故 D9 直接收回这个写者。
关于 argv 上限的结论（`-files-from` 是任意长度路径列表喂子进程的唯一正解）仍然成立，只是
现在只有 `:UEPrepare*`（单写者）走这条路径，watcher 不再走。

### D9 — csearch.idx 单写者所有权 + 构建串行 + 增量韧性（取代 D7 的写者）

三层，每层「删/守」而非「加聪明」：

**β（结构层）— watcher 退回记账员**：`ue_watch` 的 `provider_csearch_add` 改为
**record-only no-op**，不再调用 `build_index` / 不写 csearch.idx。新文件的可见性由 flush()
里的 `add_to_persistent_dirty` + rg-on-dirty overlay 提供（直到用户下次手动 `:UEPrepare*`）。
csearch.idx 的写者收敛为**唯一所有者：用户显式触发的 prepare 家族**
（`:UEPrepare` / `:UEPrepareReindex` / `:UEPrepareIncremental`）。
用户已确认：新内容到下次手动 prepare 才识别，可接受。

**Policy A（顺序层）— 构建串行，拒绝不排队**：`CORE_RT.csearch_build_running` 单标志，
每个 csearch 构建入口启动前 `CORE_RT.csearch_build_begin(label)` 检查；占用中**拒绝并可见
提示**（不排队、不写锁文件）。完成回调**无条件** `CORE_RT.csearch_build_done()`（成功与失败
两条路径都清）——否则一次失败永久卡死。不排队的依据：全量已索引整份清单（含增量的脏文件），
并发时排队增量是冗余白做。

**韧性层 — 增量前校验 idx 可用**：`build_index` 在 `mode="add"` 且 spawn 前调
`usable_index_stat(idx)`；不可用（0 字节 / 损坏 / 缺失）则不 spawn、直接
`cb(false, "...run :UEPrepare")`。`mode="reset"`（全量）无视旧 idx，永远安全，不受此约束。
这把「0 字节 idx → add → corrupt → remove」的死循环在源头切断。`recover_staged_index` 仍作
构建后兜底（从 `idx~~` 提升）。

**清理层 — 全量构建成功后 dirty 集合必归零**：β 把 watcher 降级为记账员后，「构建成功 ⇒
dirty 归零」的清理责任完全转移到 prepare 家族，且**必须在每条全量成功路径都清**
（cache fast-path / cold full / sync），统一走 `CORE_RT.clear_persistent_dirty_safe`。
只有 cold-full 清、其它路径漏清会引出两个直接症状：(1) `prepare_freshness` 的第一道闸
（`persistent_dirty_status().count > 0 → "stale"`）恒真——刚 prepare 完仍弹「stale」+ ue_watch
提示；(2) rg-on-dirty overlay 每次 grep 背着巨大脏集合（实测 dirty.json 110 KB）重复扫 → picker
变卡。失败则**不清**（脏文件仍需 overlay 兜底可见，直到下次成功构建）。

为什么不是加锁 / 双索引 / 排队：见 change `fix-csearch-index-single-writer` 的 design.md
Rejected Alternatives（α 锁仍需崩溃恢复且任意两写者重叠仍损坏；γ 双索引查询期 merge 成本永久；
Policy B 排队对全量是冗余）。

cindex `<idx>~` 路径硬编码 = 并发写损坏的根因，记 CONSTRAINTS K31g。防回归护栏：
`tests/cases/ue_watch_csearch_spec.lua`（watcher 不写索引，静态+行为）、
`tests/cases/csearch_build_guard_spec.lua`（构建串行拒绝并发 + 增量拒绝损坏 idx + 全量成功清 dirty）。


### D8 — freshness anchor：git commit-state（已被 D10 取代 / 退役，仅存档）

> **状态（2026-06-17）：D8 的「mtime 代理 anchor」整体退役，被 D10 内容指纹取代。**
> 下面保留原始记述作决策链；当前 freshness 以 **D10** 为准——不再用任何 mtime 代理。

D8（2026-06-16）把 git 维度 anchor 从 `.git/index` mtime 换成 `HEAD`+`logs/HEAD`
（commit-state），缓解了 fsmonitor/TortoiseGit 后台 touch index 引发的假 stale（K30g）。
**但它只是换了个噪声更小的代理**：随后 `dir_mtime` anchor 又被**编译产物落进引擎树 touch**
引发假 stale（重编一次即 stale，未增删任何文件）。换代理是无尽的打地鼠——D10 直接停止代理。

### D10 — freshness 用文件清单内容指纹（取代 D8 + 所有 mtime 代理）

freshness 真正要回答的唯一问题：**被索引的文件【集合】变了吗（增/删/改名）**。该集合即
`workspace_all.files` 的内容（两个写入点都 `table.sort`，bytes 确定性）。其**内容 hash 是对
该问题的直接测量**，无代理噪声。

```
prepare_freshness 稳态：
  ① in_progress / ② list 不存在 = never
  ③ watcher persistent_dirty>0 → stale   （会话内集合变化，事件驱动，零噪声）
  ④ hash(workspace_all.files) ≠ state.csearch_input_hash → stale   （确定性）
  ⑤ 否则 fresh
  删除：git_index_mtime / git_commit_state_mtime(D8) / dir_mtime —— 全部 mtime 代理
```

- **记录点**：csearch 全量构建**成功**后，`CORE_RT.on_full_csearch_success(ctx, reason)`
  在三条全量成功路径（sync / fast-path / cold-full）统一调用，一并做 D-3b 清 dirty + D10 写
  `state.csearch_input_hash = list_fingerprint(workspace_all.files)`。失败不写（指纹不得前移
  于已建成的索引）。
- **成本**：sha256(22 MB) 实测 46ms；`CORE_RT.list_fingerprint` 用 list 自身 `(mtime,size)`
  作缓存键 → 稳态只 stat（微秒），仅 list 被改写时重算一次。**此 mtime 仅作缓存失效键，
  判定永远是内容 hash**——与「拿 mtime 当真相」的代理本质不同。
- **边界**：已有文件内容编辑**不在 csearch freshness 范围**——clangd 实时感知（LSP didChange）。
  csearch 是文件级 trigram 索引，集合不变不需重建。
- **噪声消失论证**：fsmonitor/TortoiseGit touch index、编译产物 touch 目录、git 漏报未提交，
  **都不改 list 内容** → 不再假 stale；会话内集合变化由 watcher dirty 捕获，会话间由指纹捕获。

防回归：`tests/cases/freshness_fingerprint_spec.lua`（指纹同/异 + 缓存 + freshness 源不再引用
任何 mtime anchor）。详见 change `csearch-freshness-content-fingerprint`。

## 3. 失效正确性论证

- **engine 变**：旧 `set_project` 只比 project_root；engine 换了（同 project 指向新引擎）
  缓存不失效。现持久化 engine_root + 比对 → 修复。
- **platform 变不删**：D3 让不同平台落不同路径，天然隔离；新平台无索引时 D2 可见回落
  提示 `:UEPrepare`，不给残缺静默结果。
- **重建期负探测**：D1（不缓存负探测）+ UEPrepare finalize 重探，双保险。
- **stream 尾部命中**：D6 让 backend 只从一个 flusher 交付命中和 done，消除 callback
  调度顺序竞争。
- **watcher 不再写 csearch 索引（取代 D7）**：D9 让 watcher 退回记账员，csearch.idx 单写者
  =prepare 家族；消除 watcher×UEPrepare 并发写损坏（`corrupt index` + 0 字节死循环）。
- **freshness 不误报**：D10 让 freshness 取 `workspace_all.files` 内容指纹而非任何 mtime
  代理；fsmonitor/TortoiseGit touch index、编译产物 touch 目录都不改 list 内容 → 不再假 stale。

## 4. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `cache_paths` 布局变更影响面大 | platform_key="" 完全回落旧路径，老缓存零破坏；D4 move-once 幂等；spec 守护布局 |
| 跨盘绝对路径（E 工程/D 引擎） | 迁移/分路径仅改缓存落点，不碰路径内容生成；既有 cross-drive guard 不受影响 |
| watch 模块索引路径 | `ue_watch.start` 的 `csearch_index` 入参随 ctx.paths 自动指向平台目录，无需额外改 |
| csearch.idx 并发写损坏（watcher×UEPrepare 抢 `<idx>~`） | D9 β：watcher 退回记账员不写索引；Policy A：构建串行拒绝并发；韧性：增量前校验 idx 可用。spec 静态+行为守护「不复活 csearch 写者」 |
| 删除自动增量后新文件到下次 prepare 才识别 | 用户已确认可接受；persistent_dirty + rg-on-dirty overlay 使其非静默丢失 |
| fsmonitor/TortoiseGit 后台改 index、编译产物 touch 目录 → 假 stale | D10：freshness 改 `workspace_all.files` 内容指纹（确定性），退役所有 mtime 代理（git index/commit-state/dir_mtime）；会话内集合变化由 watcher dirty 捕获，会话间由指纹捕获 |

## 5. 测试

- `tests/cases/grep_cache_spec.lua`（16 例）：cache_paths 分路径/回落、fallback 可见性、
  platform_key 生成、迁移 move+幂等+不覆盖+空 key、engine_root 往返。
- `tests/cases/utils_spec.lua`（扩充）：`_reset_probe_cache` 存在/幂等、`is_indexed` 无索引安静返回 false、
  rg stream 的 `on_done` 排序与 stop 后不回调。
- `tests/cases/ue_watch_csearch_spec.lua`（D9，5 例）：watcher csearch provider 是
  record-only no-op——静态守护「不调用 `code_search.build_index()` / 不写 `.incremental.txt` /
  不裸 cindex」+ 行为守护「有/无 dirty 路径都不触发 build_index」。
- `tests/cases/csearch_build_guard_spec.lua`（D9，8 例）：构建串行（begin 占用 / 第二次拒绝 /
  done 后可再 begin / 失败也清标志）+ 增量遇 0 字节·缺失 idx 被拒不 spawn + `_usable_index_for_test`
  + 全量成功清 dirty（D-3b）。
- `tests/cases/freshness_fingerprint_spec.lua`（D10，7 例）：`list_fingerprint` 内容同/异 +
  缺失→nil + (mtime,size) 缓存命中；防回归——`prepare_freshness` 源不再引用任何 mtime 代理
  anchor（git index/commit-state/dir_mtime）+ `on_full_csearch_success` 记录指纹。
- 回归范围：跨子系统（ue.lua + code_search + ue_watch + snacks）→ 提交前全量
  `nvim --headless -l tests/run.lua`。

## 6. 公共 API 增量（M.*）

- `M._reset_probe_cache`（code_search）
- `M.cache_paths` / `M.platform_key_from_state` / `M.migrate_legacy_csearch_if_needed`（ue，测试 seam）
- `M._provider_csearch_add_for_test` / `M._set_opts_for_test`（ue_watch，测试 seam — 非运行时 API）
- `M._usable_index_for_test`（code_search，D9 测试 seam）
- `M._csearch_build_begin_for_test` / `M._csearch_build_done_for_test` /
  `M._csearch_build_running_for_test`（ue，D9 Policy A 测试 seam — 非运行时 API）
- 运行时：`CORE_RT.csearch_build_begin` / `CORE_RT.csearch_build_done`（D9 构建串行守卫）
- 运行时：`CORE_RT.list_fingerprint` / `CORE_RT.on_full_csearch_success`（D10 指纹 + 全量成功钩子）
- `M._list_fingerprint_for_test` / `M._reset_fingerprint_cache_for_test`（ue，D10 测试 seam）
- 持久状态：`state.csearch_input_hash`（D10，全量构建成功后记录的 list 内容指纹）
