## ADDED Requirements

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
