# ue-code-search Specification

## Purpose

定义 UE 工作区代码搜索的完整性、性能与缓存一致性合同：`<leader>/` 使用 csearch
索引，watcher 仅维护有界 dirty overlay，prepare 家族独占索引写入，并通过内容指纹、
增量快照和事件降噪确保平台切换、批量文件变化及 Windows 元数据通知不会产生静默漏搜、
并发损坏或持续卡顿。

## Requirements
### Requirement: `<leader>/` SHALL prefer complete indexed search

UE 全代码搜索（`<leader>/`）SHALL **只**使用 csearch 索引后端，**任何情况下都不得在此入口使用 rg 或目录遍历**——无论是静默降级、cached-file-list + rg 批量搜索、还是 snacks 默认目录遍历兜底，一律 MUST NOT 出现在 `<leader>/` 路径。当 csearch 索引可用时使用 csearch；当 csearch 索引不可用时，`<leader>/` SHALL 给出可见错误并引导用户运行 `:UEPrepare`，而不是回落到任何 rg / 遍历路径。

理由：`<leader>/` 是「索引级精确搜索」入口，**任何**走 rg / 目录遍历的路径都会产生「搜不全却看似搜过」的体验欺骗，且与「亚秒」承诺相悖。用户明确要求此入口「从不加 rg」。rg 在本仓有专用入口（`<leader>sg` / `<leader>sG`）；`code_search.stream()` 内部 rg 分支保留供 gd/gr 跳定义兜底（P12），那是**另一个调用点**，不在本入口消失。

#### Scenario: csearch 索引可用
- **WHEN** 用户触发 `<leader>/` 且当前 UE context 含可用 `csearch.idx`
- **THEN** 搜索 SHALL 使用 csearch backend
- **AND** picker 标题 SHALL 标识 `[csearch]`

#### Scenario: csearch 索引不可用
- **WHEN** 用户触发 `<leader>/` 且 csearch 索引缺失 / 0 字节 / 损坏
- **THEN** `<leader>/` MUST NOT fall 到 rg、cached-list+rg、或目录遍历中的任何一种
- **AND** 系统 SHALL 给出可见错误，明确提示运行 `:UEPrepare` 重建索引
- **AND** 系统 SHALL NOT 打开一个走 rg 的 picker

#### Scenario: 有 cached file list 但无 csearch 索引（堵死 rg-batched 暗门）
- **WHEN** 用户触发 `<leader>/`，csearch 索引不可用，但存在 cached workspace file list
- **THEN** `<leader>/` MUST NOT 启用 cached-list + 批量 rg 搜索（旧 rg-batched fallback）
- **AND** 行为 SHALL 与「csearch 索引不可用」一致：报错引导 `:UEPrepare`

#### Scenario: 用户显式要 rg
- **WHEN** 用户需要无索引的 rg 搜索
- **THEN** `<leader>sG`（`ue_grep_all`）SHALL 提供专用 rg 入口
- **AND** 该入口的行为不受本契约约束

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

### Requirement: project or engine switch SHALL select an isolated cache bucket

Project-scoped grep caches SHALL be keyed by canonical project identity beneath the engine cache root.
Changing project or engine SHALL invalidate only process-local context/probe state and route future work
to the newly selected bucket; it MUST NOT delete another project's reusable on-disk cache.

#### Scenario: project root changes
- **WHEN** `UESetProject` selects a different project root in the current Neovim process
- **THEN** future csearch/gtags/CDB paths SHALL resolve below the new canonical project bucket
- **AND** in-memory context and executable probe caches SHALL be reset
- **AND** the old project's on-disk cache SHALL remain intact

#### Scenario: engine root changes
- **WHEN** the same project path is selected under a different engine root
- **THEN** paths SHALL resolve below that engine's own project bucket
- **AND** the other engine's cache SHALL NOT be used or deleted

### Requirement: legacy grep caches SHALL migrate without data loss

当缓存布局变更时，既有 grep 缓存 SHALL 安全迁移，不丢数据、不覆盖更新的文件，且可重复运行。迁移 SHALL 覆盖两个方向：早期「扁平 → 平台子目录」（gtags，历史 v3.1）与本次「csearch 平台子目录 → 扁平共用」。

#### Scenario: csearch 从平台子目录迁移到共用扁平路径
- **WHEN** 共用 `csearch/csearch.idx` 不存在，但存在一个或多个 `csearch/<platform_key>/csearch.idx`
- **THEN** 系统 SHALL 要么将其中一份提升为共用 `csearch/csearch.idx`，要么将共用索引判为 stale 以触发首次 `:UEPrepare` 重建
- **AND** 旧的 `csearch/<platform_key>/` 索引 SHALL NOT 仅因去平台化被主动删除

#### Scenario: 共用 csearch 索引已存在
- **WHEN** 共用 `csearch/csearch.idx` 已存在
- **THEN** 迁移 SHALL NOT 用平台子目录的旧索引覆盖它
- **AND** 操作 SHALL 可重复安全运行

### Requirement: csearch.idx 同时只有一个写者

系统 SHALL 保证 `csearch.idx` 在任意时刻只有一个写者。watcher（`lua/utils/ue_watch.lua`）
在 csearch 维度 SHALL 只更新 `persistent_dirty` 记账，MUST NOT 写 csearch 索引。csearch
索引的写入 SHALL 只由用户显式触发的 prepare 家族命令（`:UEPrepare` / `:UEPrepareReindex` /
`:UEPrepareIncremental`）执行。

理由：cindex 的原子写协议把 staged 文件硬编码为 `<idx>~`，两个并发构建会抢同一个 `idx~`，
在 merge/rename 阶段相互破坏，导致 `corrupt index: remove` 与 0 字节索引死循环。

#### Scenario: 文件创建/内容修改被 watcher 观察到
- **WHEN** watcher 的 fs_event debounce flush 处理一批 add 路径
- **THEN** watcher SHALL 把这些路径记入 `persistent_dirty` 集合
- **AND** watcher MUST NOT 调用 csearch 索引构建（不写 `csearch.idx` / `csearch.idx~`）
- **AND** 这些新文件的可见性 SHALL 由 rg-on-dirty overlay 在下次手动 `:UEPrepare*` 前提供

#### Scenario: Windows metadata-only change 早于当前索引
- **WHEN** Windows/libuv 报告已有文件 `change`，但该文件的内容 mtime 早于或等于当前
  `csearch.idx` mtime
- **THEN** watcher SHALL 把它判为 last-access / attribute / security 类元数据噪声
- **AND** watcher SHALL NOT 把该路径写入 `persistent_dirty`，避免 dirty overlay 洪水

#### Scenario: 新建/重命名文件保留旧 mtime
- **WHEN** fs_event 包含 rename/create 语义，或当前没有可用的 csearch 索引时间锚
- **THEN** watcher SHALL 保守记录该路径，即使文件 mtime 较旧
- **AND** 不得因 metadata 过滤器漏掉新文件

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

### Requirement: csearch index SHALL be platform-independent (single shared index)

csearch trigram 索引 SHALL 全平台共用一份，路径为 `csearch/csearch.idx`（不再按 `platform_key` 分片）。gtags workspace DB 与 cdb compile-db 资产 SHALL 仍按 `platform_key` 分片——它们是平台相关产物（编译参数 / 宏 / include / 条件编译符号按平台不同）。

理由：csearch 索引的输入文件集（`workspace_all.files`）由 `engine_root` + `project_root` + 平台无关常量（`ENGINE_PICKER_DIRS` / `SCAN_EXCLUDES`）+ 平台无关白名单（`.ueprepare-scan-paths`）决定，不含任何平台维度。per-platform 分片是 cache layout v3.1 让 csearch 搭便车的结果，去之使「索引维度」与「`csearch_input_hash` 校验维度（per-project，本就一份）」对齐，并令切平台不再重建 csearch 索引。不同 project 即使共用 engine 仍 MUST 使用不同 project bucket，不能共享该索引。

#### Scenario: 解析 csearch 索引路径
- **WHEN** 系统为任一平台 / 配置解析 csearch 索引路径
- **THEN** 路径 SHALL 为 `csearch/csearch.idx`（与 `platform_key` 无关）

#### Scenario: gtags / cdb 仍分平台
- **WHEN** state 含 `target_platform = "Android"` 且 `target_configuration = "Development"`
- **THEN** gtags 文件清单与 DB SHALL 仍位于 `gtags/Android-Development/`
- **AND** cdb compile-db 资产 SHALL 仍按平台 / 配置分片

#### Scenario: 切换平台
- **WHEN** 用户在平台 / 配置间切换
- **THEN** csearch 搜索 SHALL 继续使用同一份 `csearch/csearch.idx`，MUST NOT 因切平台而被判为缺失或需重建
- **AND** 切平台 SHALL NOT 删除任何既有 csearch 索引

### Requirement: `<leader>/` 结果呈现 SHALL 提供分组、计数与后端状态

`<leader>/` 的结果面板 SHALL 按文件分组，每文件 SHALL 显示命中计数，并 SHALL 以 Project / Engine / Workspace scope 与对应根目录相对路径分类。分组中的每一行 MUST 是带真实 file/line/column 的可跳转命中；系统 MUST NOT 插入可被选中但没有真实命中位置的 synthetic header。picker 标题 SHALL 标识当前后端（`[csearch]`）与当前 scope。

#### Scenario: 多文件多命中
- **WHEN** 一次 `<leader>/` 搜索在多个文件命中
- **THEN** 结果 SHALL 按文件分组
- **AND** 每个文件分组 SHALL 显示该文件内的命中数
- **AND** 首行 SHALL 显示 scope、相对路径与计数，后续行 SHALL 显示该文件内的真实命中

#### Scenario: 选择任意分组行
- **WHEN** 用户选中首条或后续任意一条结果
- **THEN** 该 item SHALL 始终包含真实 file/line/column，并预览对应命中上下文
- **AND** 首条结果 MUST NOT 因 synthetic file header 而预览文件第一行或空占位内容

#### Scenario: 标题反映后端与 scope
- **WHEN** `<leader>/` 面板打开并完成一次搜索
- **THEN** 标题 SHALL 包含后端标识 `[csearch]`
- **AND** 标题 SHALL 包含当前 scope（全工程 / 当前模块 / 插件 / 目录）

### Requirement: `<leader>/` SHALL 提供可视化搜索修饰开关

`<leader>/` 面板 SHALL 提供可视化的 literal / 大小写 / 全词 / 正则开关（无需用户手输 `-- -w/-s/-F`），默认 SHALL 为 literal；开关状态 SHALL 在标题栏可见，切换后 SHALL 以新修饰重跑当前搜索。开关 SHALL 翻译为底层后端等价语义。literal 模式 SHALL 只转义 RE2 真正的 metacharacter，并 SHALL 以精确 match span 驱动预览高亮，不能让 Snacks/Vim 再把用户原始输入解释为另一层 regex。

#### Scenario: 默认搜索特殊符号
- **WHEN** 用户在默认 literal 模式输入 `.`、`/` 或其他单字符标点
- **THEN** 搜索 SHALL 启动并只匹配该字面字符
- **AND** 预览 SHALL 只高亮该字面命中，不能把 `.` 解释为“任意字符”

#### Scenario: 单字符 regex 仍受保护
- **WHEN** 用户开启 regex 后输入单个 `.`
- **THEN** 系统 SHALL 保持短查询保护，不执行会匹配几乎所有源码字符的搜索

#### Scenario: 切换全词
- **WHEN** 用户在 `<leader>/` 面板内切换「全词」开关
- **THEN** 搜索 SHALL 以全词边界（等价 `--word-regexp` / `-w`）重跑
- **AND** 标题栏 SHALL 反映「全词」为开启

#### Scenario: 切换大小写 / 正则
- **WHEN** 用户切换「大小写敏感」或「正则」开关
- **THEN** 搜索 SHALL 以对应修饰（等价 `-s` / 正则模式）重跑
- **AND** 标题栏 SHALL 反映该开关状态

### Requirement: `<leader>/` SHALL 支持面板内 scope 过滤

`<leader>/` 面板 SHALL 允许用户在面板内将搜索范围一键切换到「当前模块 / 插件 / 目录」，无需退出改走单独的 scope grep 键。

#### Scenario: 面板内切到当前模块
- **WHEN** 用户在 `<leader>/` 面板内触发「限定当前模块/插件」scope
- **THEN** 搜索 SHALL 重跑并仅在该 scope 内命中
- **AND** 标题栏 SHALL 反映该 scope

### Requirement: csearch toolchain SHALL bootstrap and resolve portably

系统 SHALL 为 POSIX 宿主提供可复现的 csearch/cindex 安装入口，并在运行时统一发现 `PATH`、
`GOBIN`、多段 `GOPATH/bin` 与宿主惯用 Go bin 目录。安装入口 SHALL 固定 upstream csearch
版本并安装仓内 `cindex-uefilter`，缺失提示 SHALL 指向该入口。仅检查工具或索引可用性时
MUST NOT 创建缓存目录或修改磁盘状态。

#### Scenario: macOS 首次安装搜索工具
- **WHEN** 用户在装有 Go 的 macOS/POSIX 宿主运行仓库安装入口
- **THEN** 系统 SHALL 把固定版本的 `csearch` 与仓内 `cindex-uefilter` 安装到同一可执行目录
- **AND** 安装结束前 SHALL 验证两个程序都可执行

#### Scenario: 工具位于自定义 Go bin
- **WHEN** `csearch` 或 `cindex-uefilter` 不在 `PATH`，但位于 `GOBIN`、任一 `GOPATH/bin` 或宿主惯用 Go bin
- **THEN** executable probing SHALL 找到并返回该程序
- **AND** health、live health 与 UEPrepare SHALL 复用同一发现结果和安装提示

#### Scenario: 只读检查一个尚不存在的索引
- **WHEN** `is_indexed`、health 或 backend probing 检查一个父目录尚不存在的 index path
- **THEN** 检查 SHALL 返回 unavailable/not-indexed
- **AND** MUST NOT 为探测创建该父目录或抛出写目录错误

### Requirement: cindex incremental merge SHALL replace only listed files

仓内 `cindex-uefilter -files-from` 在非 reset 模式 SHALL 以清单中的每个 exact file path 作为
staged merge replacement path，并只重建这些文件的 trigrams；MUST NOT 把宽泛 CLI root 当作
delta replacement prefix。reset 模式 SHALL 只登记显式 CLI roots，避免把全量文件清单复制进
index path table。删除事件 SHALL 继续升级为 reset，而不是伪装成 add。

#### Scenario: 修改文件并增量合并
- **WHEN** 清单包含一个已索引后修改的文件和一个新文件
- **THEN** merge SHALL 移除修改文件的旧 trigram、加入两个文件的新 trigram且不 panic
- **AND** 未列入清单的旧文件 SHALL 继续可搜索

#### Scenario: 增量命令同时传入宽泛 root
- **WHEN** add 模式的 CLI 参数包含 workspace root，但 `-files-from` 只含一个 delta 子集
- **THEN** staged Paths SHALL 只包含 delta 文件的 exact paths
- **AND** merge MUST NOT 因 root prefix shadow 删除其他已索引文件

#### Scenario: reset 使用全量文件清单
- **WHEN** reset 模式通过 `-files-from` 索引大型 workspace
- **THEN** index Names SHALL 覆盖清单中的有效文件
- **AND** index Paths SHALL 只保留显式 roots，不复制全部文件路径
