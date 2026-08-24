## Why

csearch 索引文件 `csearch.idx` 出现损坏死循环：`:UEPrepare` 全量构建卡在 ~85%，同时
`[ue.watch] csearch_add: cindex-uefilter exit=1 ... corrupt index: remove` 反复刷屏。

根因是**并发写同一个索引文件**。cindex（google/codesearch）的原子写协议把暂存文件硬编码为
`$idx~`（与目标 `idx` 同目录的固定兄弟路径），完成后 `rename idx~ → idx` 提交：

```
write new trigrams ──▶ idx~      （staged，路径固定）
merge(idx, idx~)   ──▶ idx~
rename idx~        ──▶ idx       （commit）
```

两个 csearch 构建并发跑同一个 `idx` 时，**不是各用各的临时文件，而是抢同一个 `idx~`**。
当前两个写者是：

- `:UEPrepare` 全量重建（`mode="reset"`，写 `idx` + `idx~`）；
- `lua/utils/ue_watch.lua` 的 `provider_csearch_add` 增量追加（`mode="add"`，2026-06-16 D7
  引入），debounce flush 在后台对同一个 `idx` 做 merge。

两者交错 → cindex 在 merge 阶段读到半截/0 字节的 `idx` → `corrupt index: remove` 把主索引删掉
→ 0 字节 `idx` 再被下一次 `mode="add"` 撞上 → 死循环；全量构建的产物一边写一边被搅坏，进度
永远到不了 100%。

更深一层：watcher 的自动增量 csearch **从来不是 load-bearing**。D7 自己的注释已写明
「未入索引的路径由 `persistent_dirty` 集合 + rg-on-dirty overlay 兜底」。用户已确认：新文件
**到下次手动 `:UEPrepare` 才被识别完全可接受**。因此这个自动写者的全部收益（编辑后到下次
prepare 之间的窗口内、新文件可走 trigram 速度 grep）极窄，却换来两天两个生产事故
（2026-06-16 ENAMETOOLONG、本次 corrupt）和一个永久的并发写危险面。正解是**收回写者权限**，
而不是给它加锁。

## What Changes

本次按三层修复，每层独立、各自「删/守」而非「加聪明」：

- **结构层（β — 单写者）**：`ue_watch` 的 csearch provider 不再写 `csearch.idx`，退回只做
  `persistent_dirty` 记账。watcher 从「索引器」降级为「记账员」。新文件靠 rg-on-dirty overlay
  浮现，直到用户下次手动 `:UEPrepare*`。删除 `provider_csearch_add` 的 `build_index` 调用路径
  （它是 2026-06-16 D7 引入的写者，本次连同其测试 seam 一并退役）。

- **顺序层（Policy A — 单构建串行，拒绝不排队）**：引入单一 `csearch_build_running` 标志，
  所有 csearch 构建入口（全量 `:UEPrepare` / `:UEPrepareReindex` / `:UEPrepareIncremental`）
  在启动前检查；已有构建在跑时**拒绝并发出可见提示**，不排队、不写锁文件、不需崩溃恢复。
  标志在构建完成回调里**无条件清除**（成功与失败两条路径都清），避免一次失败永久卡死。
  不排队的依据：全量 `:UEPrepare` 已经索引全部文件（含增量的脏文件），并发时排队一个增量是
  冗余工作。

- **韧性层（损坏自愈）**：任何增量 `mode="add"` 在执行前先校验目标 `idx` 可用
  （`usable_index_stat`）；不可用（0 字节 / 损坏）时**拒绝增量并提示走全量 `:UEPrepare`**。
  全量 `mode="reset"` 永远安全（无视旧 `idx`）。这使「0 字节 idx → add → corrupt → remove」
  的死循环结构上不可能复发。

- **立规层（防复发纪律）**：把「csearch.idx 同时只有一个写者；watcher 是记账员不是索引器」
  写成 `grep-cache-invalidation.md` 的具名不变量（D9）、`docs/CONSTRAINTS.md` 新增坑条
  （K31g），并补一条**行为测：若有人把 watcher 重新接回 csearch 写入则测例变红**——因为本次
  正是上一轮把写者加回去重开了这个坑，规则必须可执行而非只活在注释里。

## Capabilities

### Modified Capabilities

- `ue-code-search`：新增「csearch.idx 单写者所有权」「csearch 构建串行化（拒绝并发）」
  「损坏 / 0 字节索引下的增量拒绝与自愈」三类契约；并明确 watcher 在 csearch 维度只做
  `persistent_dirty` 记账、不写索引。

## Impact

- 运行时代码：
  - `lua/utils/ue_watch.lua`：`provider_csearch_add` 不再调用 `build_index`，退回记账；
    退役相关测试 seam（`_provider_csearch_add_for_test` / `_set_opts_for_test`，或改为断言
    「不写索引」）。
  - `lua/utils/code_search/init.lua`：`build_index` 在 `mode="add"` 前校验目标 idx 可用；
    暴露可测的「idx 可用」判定 seam。
  - `lua/ue.lua`：三处 csearch 构建入口接入 `csearch_build_running` 串行守卫，完成回调
    无条件清标志。
- 测试：`tests/cases/ue_watch_csearch_spec.lua`（改写为「不写索引」契约）+ 新增构建串行 /
  增量拒绝损坏 idx / watcher 不写索引的行为测。
- 文档：`docs/architecture/grep-cache-invalidation.md`（D9 + 修订 D7 表述）、
  `docs/CONSTRAINTS.md`（K31g）、`docs/changelog.md`。
- 不引入新依赖；不改 cindex-uefilter；不改平台层。
