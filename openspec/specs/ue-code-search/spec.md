# ue-code-search Specification

## Purpose

定义 UE 工作区代码搜索的完整性、性能与缓存一致性合同：`<leader>/` 使用 csearch
索引后端（trigram，全平台共用一份），watcher 仅维护有界 dirty overlay，显式构建
命令独占索引写入。目的是保证平台切换、批量文件变化及 Windows 元数据通知不会产生
静默漏搜、并发损坏或持续卡顿。边界：显式 rg 入口（`<leader>sG`）与 `gd`/`gr` 内部
的 rg fallback 是另一个调用点，不受本 spec 约束。

## Requirements

### Requirement: `<leader>/` SHALL 只使用 csearch 索引，不得回落到 rg / 目录遍历

UE 全代码搜索（`<leader>/`）SHALL 只使用 csearch 索引后端；静默降级、
cached-file-list + rg 批量搜索、默认目录遍历兜底一律 MUST NOT 出现在此入口。
索引不可用时 SHALL 给出可见错误并引导运行 `:UEPrepare`。索引读取 SHALL 只读
正式发布路径并验证有界格式头/尾/区段 offset，MUST NOT 按文件大小把暂存文件
提升为正式索引；reset/add SHALL 先完成暂存产物再原子替换，写入或发布失败
MUST NOT 提前删除或截断原有正式索引。

理由：`<leader>/` 是「索引级精确搜索」入口，走 rg / 遍历会产生「搜不全却看似
搜过」的体验欺骗；用户明确要求此入口从不加 rg。

#### Scenario: csearch 索引不可用
- **WHEN** 用户触发 `<leader>/` 且 csearch 索引缺失 / 0 字节 / 损坏
- **THEN** `<leader>/` MUST NOT fall 到 rg、cached-list+rg 或目录遍历
- **AND** 系统 SHALL 给出可见错误，明确提示运行 `:UEPrepare`

### Requirement: csearch.idx 同时只有一个写者，watcher 只记账不写索引

系统 SHALL 保证 `csearch.idx` 任意时刻只有一个写者。watcher
（`lua/utils/ue_watch.lua`）在 csearch 维度 SHALL 只更新 `persistent_dirty`
记账，MUST NOT 写 csearch 索引；索引写入 SHALL 只由显式构建命令
（`:UEPrepare*` / `:UEBuildCsearch`）执行，且同一时刻只运行一个构建——第二个
调用 SHALL 被拒绝并给出可见提示，MUST NOT 排队或写锁文件。增量构建
（append）前 SHALL 校验目标索引可用，不可用时拒绝并提示全量 `:UEPrepare`；
全量构建（reset）永远安全，不受此约束。`-files-from` 增量 merge 只替换清单
中列出的 exact file path 的 trigram，MUST NOT 把宽泛 CLI root 当作 delta
replacement prefix；删除事件升级为 reset，不得伪装成 add。

理由：cindex 原子写协议把 staged 文件硬编码为 `<idx>~`，并发构建抢同一
`idx~` 会在 merge/rename 阶段相互破坏，导致 `corrupt index: remove` 与 0
字节索引死循环；增量对损坏索引 merge 会重新触发该循环，故须在增量前校验。

#### Scenario: 已有构建运行时再次触发
- **WHEN** 一个 csearch 构建正在运行，用户触发另一个构建命令
- **THEN** 第二个构建 SHALL 被拒绝且不 spawn cindex 进程，watcher 不得写索引

### Requirement: 成功构建只清除已覆盖的 dirty 记录，溢出标记必须可见直到全量覆盖

所有构建成功路径 SHALL 只移除本次构建开始时捕获且已覆盖的 dirty 路径；构建
期间新增或再次修改的路径 MUST NOT 被清空，失败构建 MUST NOT 确认覆盖。
Watcher dirty 数组是有界集合，截断丢失路径时 SHALL 原子发布
`dirty.json.overflow` 标记；标记 SHALL 保持可见直到被覆盖它的全量 reset
清除，期间 freshness SHALL 保持 stale 且 smart build SHALL 选择 reset 而非
add 或 skip。

#### Scenario: 全量构建失败
- **WHEN** 全量 csearch 构建失败
- **THEN** 系统 SHALL NOT 清空 dirty 集合或确认其 overflow 已修复

### Requirement: freshness 以文件清单内容指纹判定，不用 mtime 代理

freshness SHALL 以 `workspace_all.files` 的内容指纹与建索引时记录的指纹
（`csearch_input_hash`）比对为判据；MUST NOT 依赖 `.git/index`、git
HEAD/logs 或引擎/项目目录 mtime 等侧信道代理。全量构建成功后 SHALL 记录该
指纹，失败 SHALL NOT 记录。指纹计算 SHALL 以清单文件自身 `(mtime, size)`
作缓存键，命中时仅 stat 不重算。

理由：freshness 要回答的是「被索引的文件**集合**是否变化」，内容指纹是
直接测量；mtime 代理会被 fsmonitor / TortoiseGit 后台 touch、编译产物落树
等无关事件污染而产生假 stale。已有文件的**内容编辑**不在此范围，由 clangd
实时感知。

#### Scenario: 文件集合未变但引擎目录 mtime 被 touch
- **WHEN** `:UEPrepare` 后用户重新编译，引擎目录 mtime 被 touch，但未增删
  任何被索引文件
- **THEN** freshness SHALL 判 fresh，不弹 stale 提示

### Requirement: csearch 索引全平台共用一份；范围完整性独立于 freshness

csearch trigram 索引路径 SHALL 为 `csearch/csearch.idx`，不按
`platform_key` 分片；gtags/cdb 资产是平台相关产物，SHALL 仍按平台分片。
索引输入集（`workspace_all.files`）SHALL 覆盖项目内全部模块声明
（`*.Build.cs` / `*.uplugin` / `*.uproject`）所在目录的源文件；扫描根推导
遗漏某模块目录导致的永久不可搜，MUST NOT 被当作「索引过期」处理——这类范围
遗漏无法靠重建修复，freshness 指纹相等 SHALL NOT 被视为范围完整的证明
（范围契约见 `project-scan-root-discovery`）。

理由：csearch 输入集只由 engine_root + project_root + 平台无关常量/白名单
决定，不含平台维度；per-platform 分片是历史 cache layout 搭便车的结果。

#### Scenario: 切换平台
- **WHEN** 用户在平台/配置间切换
- **THEN** csearch 搜索 SHALL 继续使用同一份 `csearch/csearch.idx`，MUST NOT
  因切平台被判为缺失或需重建

### Requirement: `<leader>/` 默认扁平呈现结果，暴露后端与搜索修饰状态

默认结果面板 SHALL 每条命中显示一条独立 grep 行（file/line/column + 命中
文本），MUST NOT 插入按文件聚合的 header/计数/分组标记（`:UEGrepGroupingToggle`
MAY 作为诊断 A/B 开关恢复旧分组，但默认必须关闭）。面板 SHALL 提供可视化
literal / 大小写 / 全词 / 正则开关（默认 literal，状态在标题栏可见）与一键
scope 切换（当前模块/插件/目录）；literal 模式 SHALL 只转义 RE2 真正的
metacharacter 并以精确 match span 驱动预览高亮。picker 标题 SHALL 标识后端
（`[csearch]`）与当前 scope。流式 backend（csearch 与 rg）SHALL 保证所有已
解析命中在 `on_done` 前交付，stop 后 MUST NOT 再对该搜索调用 `on_done`。

#### Scenario: 默认搜索特殊符号
- **WHEN** 用户在默认 literal 模式输入 `.`、`/` 等单字符标点
- **THEN** 搜索 SHALL 只匹配该字面字符，预览 SHALL 只高亮该字面命中

### Requirement: Windows 原生 watcher 必须排除纯元数据事件并诚实报告覆盖缺口

只有最后访问时间、属性或安全描述符变化的原生通知类别 SHALL 在订阅时被排除，
不进入 dirty tracking；文件/目录名、大小与最后写入变化 SHALL 继续被递归
订阅。不可用的原生 watching SHALL 被显式报告，不得被静默当作等价的仅内容
watcher。事件缓冲区溢出、协议失效或 helper 异常退出时，watcher 状态 SHALL
暴露未知覆盖及原因并通知其 source owner；`.omx` 目录组件下的实验性文件复制
SHALL 在共享路径过滤器处被拒绝，不进入 dirty tracking。

#### Scenario: Windows 元数据通知不进入 source observer
- **WHEN** 只有文件的最后访问时间、属性或安全性在 Windows 主机上变化
- **THEN** source watcher SHALL 在订阅时排除该类通知，不进入 dirty tracking

### Requirement: 项目/引擎切换选择隔离缓存 bucket，legacy 缓存安全迁移

Project-scoped grep 缓存 SHALL 按 canonical project identity 分桶于 engine
缓存根之下；切换项目/引擎 SHALL 只失效进程本地 context/probe 状态，MUST NOT
删除另一个项目的可复用磁盘缓存。缓存布局变更时既有缓存 SHALL 安全迁移
（可重复运行、不丢数据），覆盖「扁平 → 平台子目录」（gtags 历史）与
「csearch 平台子目录 → 扁平共用」两个方向；旧的平台子目录索引 SHALL NOT
仅因去平台化被主动删除。

#### Scenario: csearch 从平台子目录迁移到共用扁平路径
- **WHEN** 共用 `csearch/csearch.idx` 不存在，但存在一个或多个
  `csearch/<platform_key>/csearch.idx`
- **THEN** 系统 SHALL 提升其中一份为共用索引，或将共用索引判为 stale 以触发
  首次 `:UEPrepare` 重建

## 选型与踩坑

- **选型**：`<leader>/` 与显式 rg 入口（`<leader>sG`）严格分离——索引搜索
  承诺「亚秒 + 完整」，走 rg 会破坏承诺并制造「搜过却没搜到」的体验欺骗；
  `gd`/`gr` 内部的 rg fallback 是另一个调用点，不受本 spec 约束。
- **选型**：freshness 判据用 `workspace_all.files` 内容指纹而非任何 mtime
  代理——mtime 会被后台工具（fsmonitor、TortoiseGit、编译产物落树）污染，
  产生假 stale；指纹是对「索引集合是否变化」的直接测量。
- **选型**：csearch 索引去平台化为全局共用一份，gtags/cdb 保持按平台分片——
  csearch 输入集不含平台维度，历史按 platform_key 分片是 cache layout 搭
  便车的结果。
- **踩坑**：`corrupt index: remove` 与 0 字节索引死循环——根因是并发构建争抢
  同一 `<idx>~` 临时文件；处置是单写者串行化（拒绝并发，不排队）+ 增量构建
  前校验索引可用性。
- **踩坑**：watcher 曾经/可能被误接回 csearch 写入路径——回归测试专门断言
  watcher provider 不触发 `build_index`，这是防回归红线。
- **重要事项**：Windows 原生文件通知包含大量与内容无关的元数据事件，必须在
  订阅层过滤，否则会制造持续 dirty 噪声与虚假 stale 判断。
- **重要事项**：`workspace_all.files` 的范围完整性是独立于 freshness 的
  契约——freshness 只能证明「集合没变」，不能证明「集合一开始就没漏」；
  范围契约见 `project-scan-root-discovery`。
