## 1. 结构层 — watcher 退回记账员（β）

- [x] 1.1 `lua/utils/ue_watch.lua`：`provider_csearch_add` 删除对 `code_search.build_index`
      的调用与临时 `-files-from` 列表写入；保留 `add_to_persistent_dirty`（fs_event → dirty
      集合记账）。函数语义改为「只记账、不写 csearch 索引」，返回 true（no-op 成功）。
- [x] 1.2 `lua/utils/ue_watch.lua`：更新模块 header「Design constraints」与 `provider_csearch_add`
      doc-comment，声明 csearch 写入已收回；引用 D9。退役或改写测试 seam
      `_provider_csearch_add_for_test` / `_set_opts_for_test`（保留供「断言不写索引」用）。
- [x] 1.3 确认 flush() 的 fan-out（step 列表）中 csearch_add 仍在位但已是记账 no-op；
      cdb / gtags / stale-mark provider 不受影响。

## 2. 顺序层 — csearch 构建串行（Policy A）

- [x] 2.1 `lua/ue.lua`：新增 `CORE_RT.csearch_build_running`（默认 false），随其它 CORE_RT
      运行时标志一处声明。
- [x] 2.2 `lua/ue.lua`：全量构建入口（~L8533 `:UEPrepare` / `:UEPrepareReindex` 路径）启动前
      检查标志；占用中则可见 notify「csearch build already in progress — skipped」并 return；
      否则置 true。
- [x] 2.3 `lua/ue.lua`：`:UEPrepareIncremental` 入口（~L8554）同样接入标志检查。
- [x] 2.4 `lua/ue.lua`：每个 `build_index(...)` 完成回调里**无条件**将标志清回 false
      （success 与 fail 两条路径都清）。
- [x] 2.5 暴露测试 seam：可设置 / 读取 `csearch_build_running` 与一个「尝试启动构建」的可测
      入口（或纯函数 `should_skip_csearch_build()`），供行为测断言「占用中拒绝」。

## 3. 韧性层 — 增量前校验 idx 可用

- [x] 3.1 `lua/utils/code_search/init.lua`：`build_index` 在 `mode="add"` 分支、spawn 前调用
      `usable_index_stat(idx)`；不可用则不 spawn，直接 `cb(false, "index unusable; run :UEPrepare", {})`。
- [x] 3.2 `mode="reset"`（全量）不加此检查（无视旧 idx，永远安全）。
- [x] 3.3 暴露 `M._usable_index_for_test(path)`（或复用既有）供行为测。
- [x] 3.4 保留 `recover_staged_index` 作构建后兜底；确认增量被拒后不会留下半截 `idx~`。

## 3b. 清理层 — 全量构建成功后 dirty 集合归零（D-3b）

- [x] 3b.1 `lua/ue.lua`：新增 helper `CORE_RT.clear_persistent_dirty_safe(reason)`
      （soft require ue_watch，存在才调），统一三条全量成功路径的清理。
- [x] 3b.2 cache fast-path 全量成功回调（`csearch index rebuilt`）→ 成功分支调 clear。
- [x] 3b.3 sync 路径全量成功（`cs_ok`）→ 调 clear。
- [x] 3b.4 cold full 路径已有 `clear_persistent_dirty("prepare")`——确认在成功分支、统一走 helper。
- [x] 3b.5 失败路径 MUST NOT 清（脏文件仍需 overlay 兜底）。
- [x] 3b.6 行为测：全量构建成功后 `persistent_dirty.count == 0`；失败后不清。

## 4. 测试（行为优先，防回归护栏）

- [x] 4.1 改写 `tests/cases/ue_watch_csearch_spec.lua`：删除 D7 的 argv/`-files-from`/
      `build_index{mode=add}` 断言；新增「csearch provider 不调用 build_index、不写 csearch
      索引、仅记账」的行为测（stub `code_search.build_index` 断言未被调用）。
- [x] 4.2 新增「csearch 构建串行」行为测：占用标志后再次启动构建被拒（返回 skip / 不 spawn）；
      完成回调清标志后可再次启动；模拟失败回调也清标志。
- [x] 4.3 新增「增量遇不可用 idx 被拒」行为测：对 0 字节 / 缺失 idx 调 `build_index{mode=add}`
      → `cb(false, ...)` 且不 spawn；`mode="reset"` 在同样条件下仍正常。
- [x] 4.4 防回归护栏测：断言 ue_watch 源不再含 `build_index` 调用 / csearch 写路径
      （静态 + 行为双保险，呼应 D4 立规）。

## 5. 文档与立规

- [x] 5.1 `docs/architecture/grep-cache-invalidation.md`：新增 **D9**（单写者所有权 + watcher
      记账员 + 增量前校验）；修订 **D7** 表述（其增量写者已退役，注明被 D9 取代的部分）；
      §4 风险表 / §5 测试 / §6 公共 API 增量同步。
- [x] 5.2 `docs/CONSTRAINTS.md`：新增坑 **K31g**（cindex `idx~` 路径硬编码 → 并发写损坏；
      三层解法；指向 D9 与行为测）；K-grep 相关条目交叉引用。
- [x] 5.3 `docs/changelog.md` Unreleased 追加一条，Validation 写明所跑回归范围与结果。

## 6. 回归门禁

- [x] 6.1 最小范围：`nvim --headless -l tests/run.lua utils`（含 ue_watch_csearch 改写）。
- [x] 6.2 文档可发现性：`nvim --headless -l tests/run.lua structure`。
- [x] 6.3 提交前全量：`nvim --headless -l tests/run.lua` 全绿（跨子系统：ue.lua + ue_watch
      + code_search）。
- [x] 6.4 `openspec validate fix-csearch-index-single-writer` 通过。
