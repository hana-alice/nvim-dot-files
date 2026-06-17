## Context

`csearch.idx` 损坏死循环的现场事实（apply 前以这些为准，不靠记忆）：

事故时 `csearch/Android-Development/` 目录状态：
```
csearch.idx     0 bytes      ← 主索引被 corrupt 后清空
csearch.idx~    12232 bytes  ← incremental 写的 staged（watcher 增量产物）
csearch.idx~~   272 MB       ← 上一次全量 UEPrepare 的好索引
```
刷屏日志：`cindex-uefilter exit=1 ... merge ... corrupt index: remove <csearch.idx>`，
且 `:UEPrepare` 的 "building csearch index" 卡在 ~85%。

### cindex 原子写协议（不可改的上游约束）

```
write new trigrams ──▶ idx~      （staged，路径 = <idx>~，固定）
merge(idx, idx~)   ──▶ idx~
rename idx~        ──▶ idx       （commit）
```

关键：**staged 路径是硬编码的 `<idx>~`，不是每进程独立的临时文件**。两个 csearch 构建并发
跑同一个 `idx` 时会抢同一个 `idx~`：

```
UEPrepare(full, reset)        watcher(incremental, add, D7)
──────────────────────────────────────────────────────────
write idx~ (full)
                              write idx~ (incr)   ← 同一个 idx~！
merge idx + idx~                                  
                              merge idx + idx~     ← idx 处于半 rename 态
"corrupt index: remove"
rm idx                        rm idx               ← 双删
```

0 字节 `idx` 再被下一次 `mode="add"` 撞上（`merge 0-byte-idx + mem` 读到空头）→ 再次
`corrupt index: remove` → 死循环。

### 当前代码行为快照

- 两个 csearch 写者：
  - 全量：`lua/ue.lua` ~L8533 `code_search_fp.build_index(cs_ctx_fp, abs_list, cb)`
    （`mode="reset"`），由 `:UEPrepare` / `:UEPrepareReindex` 触发；
  - 增量：`lua/utils/ue_watch.lua` `provider_csearch_add` → `build_index(.., {mode="add"})`
    （2026-06-16 D7 引入），由 fs_event debounce flush 在后台触发；
  - 另有手动 `:UEPrepareIncremental`（`lua/ue.lua` ~L8554，`mode="add"`）也是写者。
- `build_index`（`lua/utils/code_search/init.lua` L585）对 `mode` 仅区分加不加 `-reset`，
  **不检查目标 idx 是否可用**；完成后才调 `recover_staged_index(idx)`（L633）——即恢复发生在
  构建之后，`mode="add"` 撞上 0 字节 idx 时损坏已经发生。
- `recover_staged_index`（L124）能把 `idx~~` / `idx~` 提升为 `idx`，但只在构建完成回调里跑，
  不在构建之前跑。
- 没有任何跨写者的串行机制；`CORE_RT.prepare_jobid` 只跟踪 gtags 异步 job，不覆盖 csearch
  build 的 spawn。
- watcher 的 `persistent_dirty` 记账与 csearch 写入是**两条独立路径**：D7 注释已声明记账 +
  rg-on-dirty overlay 是新文件可见性的兜底，csearch 自动写只是「锦上添花」。

## Goals / Non-Goals

**Goals：**
- 结构上消除 `csearch.idx` 并发写损坏：同一时刻只有一个 csearch 写者。
- watcher 在 csearch 维度退回纯记账（`persistent_dirty`），不再写索引。
- 多个手动写者之间串行：第二个被拒绝并可见提示，绝不与第一个并发。
- 增量构建遇到不可用 / 0 字节 idx 时拒绝并引导走全量，损坏死循环不可复发。
- 把单写者规则固化为可执行不变量（spec + 文档 + 行为测），防止再被加回写者。

**Non-Goals：**
- 不追求「编辑后立即 trigram-grep 到新文件」——用户已确认到下次手动 prepare 才识别可接受。
- 不改 cindex-uefilter / cindex 的原子写协议。
- 不引入文件锁 / 跨进程锁 / 任务队列。
- 不做临时止血现场操作（按正规改动流程推进；恢复由 `recover_staged_index` 在下次全量
  构建后自然完成）。

## Decisions

### D-1（结构层）watcher 退回记账员：β，不是加锁

watcher 的 `provider_csearch_add` 删除对 `build_index` 的调用；保留 `persistent_dirty`
记账（fs_event → dirty 集合）。csearch.idx 的写者收敛为「用户显式触发的 prepare 家族」。

**为什么删而不是锁**：watcher 自动增量从不 load-bearing（overlay 已兜底），它的收益极窄
（编辑到下次 prepare 之间的窗口），代价是两天两个事故 + 永久并发面。删除写者 = 移除一个
moving part；加锁 = 增加一个 moving part（且仍要处理崩溃残留锁）。删除是唯一「减法」选项，
也正是 D7 注释已预先认可的语义。

### D-2（顺序层）Policy A：单标志串行，拒绝不排队

```
CORE_RT.csearch_build_running = false   -- 模块级单标志

每个 csearch 构建入口（全量/Reindex/Incremental）启动前：
  if csearch_build_running then
     notify("csearch build already in progress — skipped")   -- 可见
     return
  csearch_build_running = true
  build_index(..., function(...)
     csearch_build_running = false   -- 成功与失败都清，无条件
     ...
  end)
```

**为什么拒绝而非排队（否决 Policy B）**：全量 `:UEPrepare` 读取整份 workspace 文件清单
（包含增量本要加的脏文件）。全量在跑时排队一个增量是**冗余**——全量会自己收进这些文件。
排队只是安排一份注定白做、还要和下一个抢的活。`reject` 是「有序」的最小诚实形态：无锁文件、
无队列、无崩溃恢复。

**唯一陷阱**：标志必须在 success 与 fail 两条回调路径都清，否则一次失败永久卡死，之后所有
构建都被「skipped」。

### D-3（韧性层）增量前校验 idx 可用，否则拒绝引导全量

```
build_index(.., {mode="add"}) 启动前：
  if not usable_index_stat(idx) then        -- 0 字节 / 损坏 / 缺失
     拒绝增量 + 提示「索引不可用，请运行 :UEPrepare 全量重建」
     return
mode="reset"（全量）不做此检查——它无视旧 idx，永远安全。
```

这把「0 字节 idx → add → corrupt → remove」的循环在源头切断：增量永远不会对一个不健康的
idx 做 merge。`recover_staged_index` 仍保留作构建后的兜底恢复（从 `idx~~` 提升）。

### D-3b（清理层）全量构建成功后 dirty 集合必归零（β 的清理责任转移补全）

watcher 退回记账员后，「构建成功 ⇒ dirty 归零」的清理责任**完全转移到 prepare 家族**。

```
全量构建成功回调（所有路径：cache fast-path / cold full / sync）：
  if ok then
     clear_persistent_dirty("prepare")   -- 统一清，不只其中一条路径
```

**为什么是 D9 的一部分而非事后补丁**：β 把 watcher 从写者降级为记账员，原本「watcher 写
csearch 时顺带清 dirty」的隐式清理链断了。若只有 cold-full 一条路径清（实施初版的状态），
缓存快速路径成功后 dirty 集合残留会引出两个直接症状：

- `prepare_freshness` 的**第一道闸**（`persistent_dirty_status().count > 0 → "stale"`）恒真
  → 刚 prepare 完 `<space><space>` 仍弹「:UEPrepare is stale」+ ue_watch 提示（**真 bug，非误报**）；
- rg-on-dirty overlay 每次 grep 背着一个巨大的脏集合（实测 dirty.json 110 KB）重复扫
  → `<leader>/` / `<space><space>` 变卡。

全量已索引整份清单（含全部脏文件），故成功后 dirty 逻辑上必须为空。失败则**不清**（脏文件
仍需 overlay 兜底可见，直到下次成功构建）。

### D-4（立规层）D9 不变量 + K31g + 防回归行为测

- `grep-cache-invalidation.md` 新增 **D9**：「csearch.idx 同时只有一个写者；watcher 是
  记账员不是索引器；增量写者必须先验证 idx 可用；全量构建成功后 dirty 集合必归零」。
  同时修订 D7 表述（其增量写者已退役）。
- `docs/CONSTRAINTS.md` 新增坑 **K31g**：cindex `idx~` 路径硬编码导致的并发写损坏 +
  本次三层解法；并记 D-3b 的 dirty-残留 stale/卡顿 二次症状。
- 行为测：断言 `ue_watch` 的 csearch provider **不调用 `build_index` / 不产生 csearch 写**
  （只记账）；若有人重新接回写入，测例变红。这是把「上一轮我亲手加回写者重开坑」这件事
  钉死的执行性护栏。

## Rejected Alternatives

| 方案 | 思路 | 否决理由 |
|---|---|---|
| α — 文件锁 / 互斥 | 两个写者用锁协调，第二个等待 | 加 moving part；锁文件在 kill -9 / 断电后残留需崩溃恢复；且只要任意两个 csearch 写者重叠就仍可损坏——治标 |
| γ — 双索引分离 | watcher 写独立 idx，查询时合并两个索引 | 复杂度高（查询期 merge）、2x 磁盘；为一个非 load-bearing 的收益引入永久查询成本 |
| Policy B — 排队 | 第二个写者排队等第一个完成 | 全量已覆盖增量的全部文件，排队增量是冗余白做；引入队列 + 崩溃恢复机制 |
| 保留自动增量 + 仅加锁 | 维持 D7 写者，外加 D-2 串行 | 串行只防「同时」，不改「watcher 是第二写者」这一结构事实；用户已确认自动增量收益不需要，保留它只是把危险面继续养着 |

## Risks

| 风险 | 缓解 |
|---|---|
| 删除自动增量后，新文件到下次 prepare 前 grep 不到 trigram | 用户已确认可接受；rg-on-dirty overlay 仍使其可见，非静默丢失 |
| `csearch_build_running` 标志泄漏（回调漏清）卡死所有构建 | 测试覆盖 success/fail 两路径都清；标志为内存态，重启 nvim 自动复位 |
| 增量拒绝损坏 idx 后用户不知所措 | 拒绝时给可见提示明确指向 `:UEPrepare` 全量 |
| 现有 `ue_watch_csearch_spec.lua`（D7 的测）与新契约冲突 | 改写为「不写索引」契约，删除 argv/`-files-from` 相关断言，保留「不阻塞主线程」精神 |

## Verification

- `nvim --headless -l tests/run.lua utils`（code_search）、`dap` 无关、`structure`（文档可发现）。
- 跨子系统（ue.lua + ue_watch + code_search）→ 提交前全量 `nvim --headless -l tests/run.lua`。
- 行为测覆盖：watcher provider 不产生 csearch 写；并发构建第二个被拒；增量遇 0 字节 idx 被拒
  并提示全量；全量 reset 在损坏 idx 上仍成功。
