# ue-code-search Specification

## Purpose

TBD
## Requirements
### Requirement: `<leader>/` SHALL prefer complete indexed search

UE 全代码搜索 SHALL 在 UE context 可解析时优先使用完整的 indexed backend：存在 csearch index 时使用 csearch；不存在 csearch index 但存在 cached workspace file list 时使用 rg；只有两者都不可用时才允许回落到 snacks 的目录遍历。

#### Scenario: csearch index 可用
- **WHEN** 用户触发 `<leader>/` 且当前 UE context 含有效 `csearch_idx`
- **THEN** `cached_grep` SHALL 使用 csearch backend
- **AND** picker 标题 SHALL 标识 `[csearch]`

#### Scenario: csearch index 不可用但 cached file list 可用
- **WHEN** 用户触发 `<leader>/` 且 csearch index 不可用，但 cached workspace file list 可用
- **THEN** `cached_grep` SHALL 使用 rg backend
- **AND** picker 标题 SHALL 标识 `[rg]`

#### Scenario: indexed backend 与 cached file list 都不可用
- **WHEN** 用户触发 `<leader>/` 且 csearch index 与 cached workspace file list 都不可用
- **THEN** `cached_grep` SHALL 返回 nil 以允许最底层 fallback
- **AND** fallback picker 标题 MUST 明确包含 slow fallback 与运行 `:UEPrepare` 的提示
- **AND** 系统 MUST 发出一次性 WARN，说明该 fallback 可能漏文件

### Requirement: 流式 backend SHALL deliver all parsed hits before done

`utils.code_search.stream` 的 csearch 与 rg backend SHALL 保证同一次搜索中所有已解析命中均在 `on_done` 前通过 `on_line` 交付。

#### Scenario: stdout 尾部数据晚于 exit callback 调度
- **WHEN** csearch 或 rg 进程退出信号与 stdout 尾部数据在同一轮事件循环附近到达
- **THEN** backend SHALL 先交付所有 parsed-but-undelivered hits
- **AND** backend SHALL only call `on_done` after backlog is empty

#### Scenario: 搜索被 stop 后
- **WHEN** caller 调用 backend 返回的 stop 函数
- **THEN** backend SHALL stop delivering future `on_line` callbacks
- **AND** backend SHALL NOT call `on_done` for that stopped search after stop has taken effect

### Requirement: csearch tool probing SHALL NOT cache failures

csearch 与 cindex-uefilter 的 executable probing SHALL cache only successful executable paths. A failed probe MUST NOT prevent later probes in the same Neovim session.

#### Scenario: 冷启动首次探测失败
- **WHEN** 首次探测 csearch executable 返回 nil
- **THEN** 后续再次调用 probing 逻辑 SHALL retry discovery
- **AND** 一旦 executable 可用，后续调用 SHALL reuse the successful path

#### Scenario: UEPrepare 或上下文切换完成
- **WHEN** UEPrepare finalize、项目切换或平台切换完成
- **THEN** 系统 SHALL reset csearch/cindex probe cache
- **AND** 下一次 `<leader>/` SHALL re-evaluate backend availability

### Requirement: grep-facing caches SHALL be isolated by platform and configuration

UE grep-facing cache artifacts SHALL be keyed by the active platform/configuration when that state is known. This includes csearch index, gtags workspace DB, and grep file lists.

#### Scenario: active platform key exists
- **WHEN** state contains `target_platform = "Android"` and `target_configuration = "Development"`
- **THEN** cache paths SHALL place csearch index under `csearch/Android-Development/`
- **AND** grep file lists SHALL be under `gtags/Android-Development/`

#### Scenario: no platform key exists
- **WHEN** no active platform is known
- **THEN** cache paths SHALL use the legacy single-path layout
- **AND** existing no-platform workflows SHALL continue to resolve cache files without platform subdirectories

#### Scenario: switching platform
- **WHEN** user switches from one platform/configuration to another
- **THEN** UE grep SHALL resolve to the new platform/configuration cache directory
- **AND** the previous platform/configuration cache SHALL NOT be deleted solely because of the platform switch
- **AND** if the new cache is missing, the next `<leader>/` SHALL surface visible fallback instead of silently presenting incomplete results

### Requirement: project or engine switch SHALL invalidate project-scoped grep caches

Project-scoped grep caches SHALL be invalidated when either the project root or engine root changes.

#### Scenario: project root changes
- **WHEN** `UESetProject` records a different project root than the persisted state
- **THEN** all platform-specific csearch and gtags grep caches for that engine cache root SHALL be invalidated
- **AND** cdb shard caches tied to the old project SHALL be invalidated

#### Scenario: engine root changes
- **WHEN** `UESetProject` records the same project root but a different engine root than persisted state
- **THEN** all project-scoped grep caches SHALL be invalidated
- **AND** the new `engine_root` SHALL be persisted in state for future comparisons

### Requirement: legacy grep caches SHALL migrate without data loss

When a platform key becomes available, legacy single-path grep caches SHALL be migrated into the active platform/configuration directory without overwriting newer platform-specific files.

#### Scenario: legacy cache exists and active platform cache is empty
- **WHEN** legacy `csearch/csearch.idx` and `gtags/*.files` exist
- **AND** active platform-specific target files do not exist
- **THEN** migration SHALL move those files into the active platform directory
- **AND** the legacy source files SHALL no longer remain at their old paths

#### Scenario: active platform cache already exists
- **WHEN** legacy cache files exist but the active platform-specific target file already exists
- **THEN** migration SHALL NOT overwrite the active platform-specific file
- **AND** the operation SHALL be safe to run repeatedly

### Requirement: csearch.idx 同时只有一个写者

系统 SHALL 保证 `csearch.idx` 在任意时刻只有一个写者。watcher（`lua/utils/ue_watch.lua`）
在 csearch 维度 SHALL 只更新 `persistent_dirty` 记账，MUST NOT 写 csearch 索引。csearch
索引的写入 SHALL 只由用户显式触发的 prepare 家族命令（`:UEPrepare` / `:UEPrepareReindex` /
`:UEPrepareIncremental`）执行。

理由：cindex 的原子写协议把 staged 文件硬编码为 `<idx>~`，两个并发构建会抢同一个 `idx~`，
在 merge/rename 阶段相互破坏，导致 `corrupt index: remove` 与 0 字节索引死循环。

#### Scenario: 文件创建/修改被 watcher 观察到
- **WHEN** watcher 的 fs_event debounce flush 处理一批 add 路径
- **THEN** watcher SHALL 把这些路径记入 `persistent_dirty` 集合
- **AND** watcher MUST NOT 调用 csearch 索引构建（不写 `csearch.idx` / `csearch.idx~`）
- **AND** 这些新文件的可见性 SHALL 由 rg-on-dirty overlay 在下次手动 `:UEPrepare*` 前提供

#### Scenario: watcher 被重新接回 csearch 写入（防回归）
- **WHEN** 代码改动让 watcher 的 csearch provider 重新写入索引
- **THEN** 对应行为测 SHALL 失败（断言 provider 不触发 `build_index` / 无 csearch 写）

### Requirement: csearch 构建串行化（拒绝并发，不排队）

系统 SHALL 保证同一时刻只运行一个 csearch 构建。任一 csearch 构建入口在启动前 SHALL 检查
全局 `csearch_build_running` 状态；若已有构建在运行，第二个调用 SHALL 被拒绝并发出可见提示，
MUST NOT 排队、MUST NOT 写锁文件。构建状态标志 SHALL 在构建完成回调中无条件清除（成功与
失败两条路径都清）。

理由：全量 `:UEPrepare` 已索引整份文件清单（含增量本要追加的脏文件），并发时排队增量是冗余
工作；拒绝是「有序」的最小诚实形态，无需队列与崩溃恢复。

#### Scenario: 已有 csearch 构建在运行时再次触发构建
- **WHEN** 一个 csearch 构建正在运行，用户触发另一个 csearch 构建命令
- **THEN** 第二个构建 SHALL 被拒绝且不 spawn cindex 进程
- **AND** 系统 SHALL 发出可见提示说明已有构建在运行、本次被跳过

#### Scenario: csearch 构建失败后
- **WHEN** 某次 csearch 构建以失败结束
- **THEN** `csearch_build_running` 标志 SHALL 被清回空闲
- **AND** 后续 csearch 构建 SHALL 能正常启动（标志不被失败永久卡死）

### Requirement: 增量构建拒绝不可用索引并引导全量

系统在执行增量 csearch 构建（append 模式）前 SHALL 校验目标 `csearch.idx` 可用
（存在且大小超过最小有效阈值）。当索引不可用（缺失 / 0 字节 / 损坏）时，增量构建 SHALL 被
拒绝，并提示用户运行全量 `:UEPrepare`。全量构建（reset 模式）SHALL NOT 受此校验约束——它
无视既有索引，永远安全。

理由：`mode="add"` 对 0 字节 / 损坏索引做 merge 会触发 `corrupt index: remove`，进而 0 字节
索引再被下一次 add 撞上，形成死循环；增量前校验在源头切断该循环。

#### Scenario: 增量构建遇到 0 字节 / 损坏索引
- **WHEN** 触发增量（append）csearch 构建且目标索引不可用
- **THEN** 系统 SHALL 不 spawn cindex 进程
- **AND** 系统 SHALL 返回失败并提示运行全量 `:UEPrepare`

#### Scenario: 全量构建遇到 0 字节 / 损坏索引
- **WHEN** 触发全量（reset）csearch 构建且既有索引不可用
- **THEN** 全量构建 SHALL 正常执行并重建一个可用索引

### Requirement: 全量构建成功后持久化 dirty 集合归零

系统在任一**全量** csearch 构建成功后 SHALL 清空 watcher 的 persistent dirty 集合
（`clear_persistent_dirty`）。这适用于全量构建的所有成功路径（cache fast-path / cold full /
sync），不只其中一条。

理由：watcher 退回记账员后（单写者 β），「构建成功 ⇒ dirty 归零」的清理责任完全转移到 prepare
家族。若任一全量路径漏清，残留的 dirty 集合会（1）让 `prepare_freshness` 的 dirty 闸门恒判
`stale`——即便刚 prepare 完也弹「stale」提示；（2）让 rg-on-dirty overlay 每次 `<leader>/` /
`<space><space>` 背着一个巨大的脏集合重复 grep，导致 picker 变卡。全量构建已索引整份文件清单
（含所有脏文件），故脏集合在成功后逻辑上必须为空。

#### Scenario: 全量构建经缓存快速路径成功
- **WHEN** `:UEPrepare` 走缓存快速路径并成功重建 csearch 索引
- **THEN** 系统 SHALL 调用 `clear_persistent_dirty`
- **AND** 此后 `prepare_freshness` 的 dirty 闸门 SHALL NOT 因残留 dirty 判 `stale`

#### Scenario: 全量构建经冷路径 / 同步路径成功
- **WHEN** `:UEPrepare` 走冷全量路径或同步路径并成功重建索引
- **THEN** 系统 SHALL 同样调用 `clear_persistent_dirty`（清理责任在所有全量成功路径一致）

#### Scenario: 全量构建失败
- **WHEN** 全量 csearch 构建失败
- **THEN** 系统 SHALL NOT 清空 dirty 集合（脏文件仍需在下次成功构建前由 overlay 兜底可见）

### Requirement: csearch freshness 用文件清单内容指纹判定（非 mtime 代理）

系统判定 csearch 索引 / 文件 picker 是否过期（freshness）时，SHALL 以
`workspace_all.files` 的**内容指纹**（content hash）与建索引时记录的指纹比对为稳态判据：
相等判 fresh，不等判 stale。系统 MUST NOT 依赖 `.git/index` mtime、git `HEAD/logs/HEAD`
mtime、或引擎/项目目录 mtime 等侧信道代理作为 freshness 判据。

理由：freshness 真正要回答的是「被索引的文件**集合**是否变化（增/删/改名）」。该集合即
`workspace_all.files` 的内容（确定性、排序后的清单），其内容指纹是对该问题的直接测量，无
代理噪声。mtime 代理会被 fsmonitor / TortoiseGit 后台 touch、编译产物落树等无关事件污染，
产生假 stale。

边界：已有文件的**内容编辑**不在 csearch freshness 范围——由 clangd 实时感知。csearch 是
文件级 trigram 索引，集合不变时不需重建。

#### Scenario: 文件集合未变（仅编译 / 后台 touch）
- **WHEN** `:UEPrepare` 后用户重新编译，引擎目录 mtime / git index 被 touch，但未增删任何
  被索引文件
- **THEN** `workspace_all.files` 内容指纹与记录值相等
- **AND** freshness SHALL 判 fresh（不弹 stale 提示）

#### Scenario: 文件集合变化（增 / 删 / 改名）
- **WHEN** 被索引的文件集合发生增删改名，导致 `workspace_all.files` 重新枚举出不同内容
- **THEN** 内容指纹与记录值不等
- **AND** freshness SHALL 判 stale

#### Scenario: 清单文件被重写但内容字节相同
- **WHEN** UEPrepare 重新生成 `workspace_all.files`，集合未变故内容字节完全相同（仅 mtime 更新）
- **THEN** freshness SHALL 仍判 fresh（指纹相同；证明判据是内容而非 mtime）

### Requirement: 全量构建成功后记录输入指纹

系统在任一**全量** csearch 构建成功后 SHALL 记录当时 `workspace_all.files` 的内容指纹到
持久状态（`csearch_input_hash`），适用于全部全量成功路径（cache fast-path / cold full /
sync）。构建失败 SHALL NOT 记录（索引未建成，指纹不得前移）。

#### Scenario: 全量构建成功
- **WHEN** 任一全量 csearch 构建成功
- **THEN** 系统 SHALL 写入 `csearch_input_hash = hash(workspace_all.files)`

#### Scenario: 持久状态无指纹记录（升级首跑）
- **WHEN** state 中不存在 `csearch_input_hash`（旧缓存升级）
- **THEN** freshness SHALL 判 stale（提示运行 `:UEPrepare`），首次全量建成后写入指纹并转稳定

### Requirement: 指纹计算成本受缓存约束

系统计算 `workspace_all.files` 内容指纹时 SHALL 以该文件自身的 `(mtime, size)` 作为
hash 缓存键：缓存命中时仅 stat 不重算，仅当清单文件被改写时才重新读取并计算 hash。
此处 mtime 仅用于缓存失效，最终判据仍为内容 hash。

#### Scenario: 稳态重复检测
- **WHEN** 清单文件未变，freshness 在同一会话被多次调用
- **THEN** 系统 SHALL NOT 重复计算完整内容 hash（命中 (mtime,size) 缓存）

