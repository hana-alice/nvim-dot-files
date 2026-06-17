## Why

`prepare_freshness`（驱动 `<space><space>` 文件 picker 与 csearch grep 的「索引是否过期」
判定）一直用**侧信道代理**回答「被索引的文件集合变了吗」这个问题：`.git/index` mtime、
`git HEAD/logs/HEAD` mtime（D8）、`engine/project 目录 mtime`。每个代理都有自己的噪声源，
导致反复出现**假 stale**：

- K30g：`.git/index` 被 fsmonitor / TortoiseGit 后台 touch → 假 stale（D8 用 commit-state
  代理缓解）；
- 本次：`dir_mtime` 被**编译产物**落进引擎树 touch → 即便没增删文件也判 stale，刚
  `:UEPrepare` 完重编一次就又 stale。

根因是结构性的：**我们在用代理猜测真实状态，每换一个代理只是换一个噪声源——这是无限的打
地鼠**。`prepare_freshness` 真正要回答的唯一问题是「**被索引的文件【集合】变了吗（增/删/
改名）**」。这个问题有一个确定性、零噪声的答案：被索引的集合就是 `workspace_all.files` 的
内容；它变 ⟺ 集合变。直接对它取内容指纹（hash），就把「猜侧信道」换成「**直接测量被检测
对象本身**」，所有代理噪声一次性消失。

边界（用户明确）：freshness 只需检测**文件集合**变化；**已有文件的内容编辑**不归 csearch
freshness 管——那由 clangd 实时感知（LSP didChange / 保存即重解析）。csearch 是文件级
trigram 索引，文件还在、仅内容变时旧 trigram 仍可用，集合变（增删改名）才是它必须重建的
唯一理由。因此内容指纹只到「清单层」（L2），不下沉到「每文件内容层」。

## What Changes

- **freshness 判定改为内容指纹（L2）**：`prepare_freshness` 的稳态判定从「list mtime vs
  代理 mtime 的大小比较」改为「`hash(workspace_all.files)` 是否等于建索引时记录的 hash」。
  相等 = fresh，不等 = stale。确定性、零噪声。
- **退役所有 mtime 代理 anchor**：删除 `git_commit_state_mtime`（D8，今天刚加）、
  `dir_mtime(engine/project)` 两类 anchor 及其 `git_index_mtime` 残留。它们存在的唯一理由是
  「猜集合是否变」，已被内容指纹精确取代。D8 是通往 L2 的中间态（更小噪声的代理），L2 是
  终点（不用代理）。
- **保留两条确定性信号**：① `csearch.idx` / list 存在性（never）；② watcher
  `persistent_dirty` 非空（会话内集合变化，事件驱动、零噪声）。这两条本就不是 mtime 代理。
- **记录指纹**：csearch 全量构建成功后，把当时的 `hash(workspace_all.files)` 写入 state
  （`csearch_input_hash`）。与 D-3b 的 dirty-clear 同一回调位置，三条全量成功路径统一。
- **hash 成本控制**：sha256(22 MB) 实测 46ms。用 list 文件**自身**的 (mtime,size) 作
  hash-cache 失效键——仅当 list 被重写时重算 hash，稳态 grep 入口只 stat 一次（微秒级）。
  注意此 mtime 是「被检测对象自己的」mtime，仅作缓存键，最终判定仍是内容比对，不是代理。

## Capabilities

### Modified Capabilities

- `ue-code-search`：freshness 判定语义从「mtime 代理比较」改为「workspace_all.files 内容指纹
  比对」；明确「集合变化由指纹检测，内容编辑由 clangd 负责，不在 csearch freshness 范围」。

## Impact

- 运行时代码：
  - `lua/ue.lua`：重写 `CORE_RT.prepare_freshness`（删 anchor 块，改指纹比对 + hash-cache）；
    删除 `git_commit_state_mtime` / `dir_mtime` / `git_index_mtime` 辅助函数（若无其它引用）；
    csearch 全量成功回调记录 `csearch_input_hash`（三路径，复用 D-3b 回调点）。
  - 指纹 hash 用 `vim.fn.sha256`（neovim 自带，已验证可用）。
- 测试：`tests/cases/`（freshness 指纹行为：集合变→stale、集合不变→fresh、list 重写但内容
  相同→仍 fresh、hash-cache 命中不重算、watcher dirty 仍短路 stale）。
- 文档：`docs/architecture/grep-cache-invalidation.md`（新增 D10，标记 D8 被取代 / dir_mtime
  退役）、`docs/CONSTRAINTS.md`（K30g/本次 dir_mtime 假 stale 收敛为「mtime 代理已退役」）、
  `docs/changelog.md`。
- 关联 change：取代 `fix-csearch-index-single-writer` 的 **D8**（commit-state anchor）。本 change
  的 freshness 模型是 D8 的正确终点；D8 的清理（D-3b dirty-clear）保留。
- 不引入新依赖。
