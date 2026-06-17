## 1. 指纹工具 + 记录点

- [x] 1.1 `lua/ue.lua`：新增 `CORE_RT.list_fingerprint(path)`——读文件 + `vim.fn.sha256`，
      用该文件自身 `(mtime,size)` 作缓存键（命中只 stat 返回缓存值，miss 才重算）。
- [x] 1.2 `lua/ue.lua`：csearch 全量构建成功回调（sync / cache fast-path / cold full
      三路径，复用 D-3b 的 `clear_persistent_dirty_safe` 同一位置）写入
      `state.csearch_input_hash = list_fingerprint(workspace_all_list)`；失败不写。
- [x] 1.3 暴露测试 seam `M._list_fingerprint_for_test(path)`。

## 2. freshness 改用内容指纹

- [x] 2.1 `lua/ue.lua` `CORE_RT.prepare_freshness`：保留 ① in_progress / ② never（list 不存在）
      / ③ watcher dirty>0 → stale；**删除 ④ anchor 块**（git_commit_state + dir_mtime 比较）。
- [x] 2.2 新增稳态判定：`list_fingerprint(workspace_all_list) == state.csearch_input_hash`
      → fresh，否则 stale；state 无该字段视为 stale（升级首跑）。
- [x] 2.3 删除 `git_commit_state_mtime` / `dir_mtime` / `git_index_mtime` 辅助函数
      （grep 确认无其它引用后再删；有则一并迁移）。

## 3. 测试

- [x] 3.1 集合变（list 内容不同）→ stale；集合不变（内容相同）→ fresh。
- [x] 3.2 list 文件被重写但**内容字节相同** → 仍 fresh（指纹相同，证明不靠 mtime）。
- [x] 3.3 hash-cache：同一 (mtime,size) 第二次调用不重算（可用 stub sha256 计数验证）。
- [x] 3.4 watcher dirty>0 仍短路 stale（与指纹正交）。
- [x] 3.5 state 缺 csearch_input_hash → stale（升级路径）。
- [x] 3.6 防回归：freshness 源不再引用 dir_mtime / git anchor（静态守护代理退役）。

## 4. 文档与立规

- [x] 4.1 `docs/architecture/grep-cache-invalidation.md`：新增 **D10**（内容指纹取代 mtime 代理）；
      标记 **D8** 被 D10 取代（commit-state anchor 退役）；§4 风险 / §5 测试 / §6 API 同步。
- [x] 4.2 `docs/CONSTRAINTS.md`：K30g 收敛——补「dir_mtime 被编译产物 touch 假 stale，连同所有
      mtime 代理已退役，freshness 改内容指纹」；指向 D10。
- [x] 4.3 `docs/changelog.md` Unreleased 追加，Validation 写明回归范围与结果。

## 5. 回归门禁

- [x] 5.1 最小范围：`nvim --headless -l tests/run.lua utils` + 新 freshness spec。
- [x] 5.2 `structure`（文档可发现性）。
- [x] 5.3 提交前全量 `nvim --headless -l tests/run.lua` 全绿。
- [x] 5.4 `openspec validate csearch-freshness-content-fingerprint` 通过。
- [x] 5.5 真机：重编 UE 一次 → `<space><space>` 不再假 stale（除非真增删文件）。
