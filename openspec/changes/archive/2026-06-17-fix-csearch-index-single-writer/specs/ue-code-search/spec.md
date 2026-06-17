## ADDED Requirements

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

