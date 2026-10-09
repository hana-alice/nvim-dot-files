# cpp-semantic-index-coverage Specification

## Purpose

定义 C++ 语义导航所消费的 clangd 索引覆盖合同：快速增量索引必须能够提升新鲜度而不缩窄已知
定义集合，每次跳转都必须能证明其 active build、CDB、toolchain 与索引 generation 来源。本
capability 管辖 SuperUnity 二次合并、build generation 的覆盖单调性、readiness 的可证伪性、
冻结批次激活的失效保护，以及 prepare 交付语义；不管具体加速比数字，只管「不得静默退化」与
「结论必须可验证」两条底线。

## Requirements

### Requirement: SuperUnity acceleration SHALL not silently regress

索引改动 SHALL 同时保留编译语义、真实覆盖与 SuperUnity 的实际加速能力；替换二次合并策略
SHALL 用相同真实 build 的实测证明等效性能。全量 exact fallback MAY 临时保住正确性，但性能
退化未处置时 MUST NOT 报告修复完成。所有 agent 的直接执行约束见根 `AGENTS.md` 的 SuperUnity
性能硬约束；发现它 MUST NOT 依赖阅读本 spec。

#### Scenario: Reporting a performance repair
- **WHEN** 报告索引性能修复完成
- **THEN** SHALL 对照最近可验证的正常实现，报告当前 build 的源覆盖、UBT/二次合并/exact/
  shader 分类与实际完成耗时、CPU/内存影响
- **AND** SHALL 区分冷/热缓存与首次/重复 prepare，MUST NOT 把 CDB 记录数或进度分母当作完成
  耗时或加速证据

### Requirement: Secondary batches SHALL preserve independently proven compiler semantics

系统 MAY 将同模块、完整编译上下文相同的 compiler-authored UBT 组再次合并；MUST NOT 合并宏、
include、target 或 PCH 参数以制造兼容性。每个候选 SHALL 与各原 UBT 独立缓存产生的完整
BackgroundIndex 图比较，保留真实文件、定义、符号身份、关系和引用；共享缓存的缺失记录、
`--check` 零诊断、CDB 条目数或进度结束都 MUST NOT 代替此证明。

#### Scenario: A candidate changes a binding without a compiler error
- **WHEN** 合并能编译但改变重载目标、删除引用、改变符号身份或产生编译错误
- **THEN** 候选 SHALL 被拒绝，并完整保留其原 UBT 命令
- **AND** MAY 调整候选顺序后重新证明，MUST NOT 为通过门禁任意重映射 SymbolID

### Requirement: Active semantic index coverage SHALL be monotonic within an immutable build generation

系统 SHALL 为每个 active build generation 记录可验证的 coverage 集合与等级，并至少绑定 active
target/platform/configuration、CDB 内容 fingerprint、toolchain identity、manifest gate 与
exact-command map 摘要。较窄的 current/hot 产物完成后 MUST NOT 替换、隐藏或降级同一 generation
中已可用的较宽基线；只有覆盖集合为超集，或明确进入新的 build generation，才允许改变可见基线。
导航请求开始后发生的 generation 切换 MUST 使旧响应 stale。

#### Scenario: Hot and full phases finish out of scheduling order
- **WHEN** hot、current、full 产物因异步执行或重试以任意顺序完成
- **THEN** active coverage SHALL 按已证明的覆盖集合单调前进，最后完成但覆盖更窄的产物
  MUST NOT 成为唯一 active index

### Requirement: Readiness SHALL be provable from persisted artifacts and self-evidencing

索引就绪判定 MUST NOT 只依赖易失的进程内/单文件 `state` 账本；账本丢失、损坏或类型错误时，
系统 SHALL 扫描当前 tuple 的持久化 manifest，在 `generation_id`/`build_key`/
`cdb_source_signature` 均校验通过后重建 selection，MUST NOT 因账本丢失而要求用户重跑
`UEPrepare`。重建 MUST fail closed。`ready` 判定本身 MUST 可证伪：报告 `ready` 时 active
selection MUST 同时携带非空 `index_path`、`artifact_fingerprint`、`coverage_level`，且
`index_path` 指向的文件 MUST 存在；内部矛盾的 `ready` SHALL 被降级为非就绪并可观测地记录。
索引查询无定义结果时 SHALL 区分 `index-incomplete`（partial coverage 下的 miss）与
`definition-absent-in-complete-index`（complete coverage 下确实无定义），两者 MUST NOT 被
归类为 overload ambiguity 或 invalid AST。

#### Scenario: State ledger is lost but artifacts remain on disk
- **WHEN** `state.index_artifacts` 为空或类型错误，但该 tuple 的 manifest、controlled CDB
  与 semantic CDB 仍存在且签名匹配当前 build
- **THEN** 系统 SHALL 依据磁盘 manifest 重建 selection 并判定为 ready，MUST NOT 提示用户
  重跑 `UEPrepare`

### Requirement: Frozen batch activation SHALL be guarded and preserve the original semantic authority

默认发布路径 SHALL 始终保留原 UBT/exact CDB；冻结批次 SHALL 使用独立 CDB 与独立 shard 缓存。
新进程发现批次产物时 SHALL 先建立经过宿主能力验证的输入监听，再异步验证 receipts 和发布内容，
成功后才选择冻结 CDB；主循环 MUST NOT 扫描依赖或同步计算大型 CDB/hash。受监视的源码、头文件、
工具、lookup 目录或冻结产物发生变化时，SHALL 立即撤销该客户端的批次 epoch 并退回独立原 UBT
路径，只重启受影响的本进程客户端。

#### Scenario: Inputs change while references or rename is in flight
- **WHEN** 受监视的源码、头文件、工具、lookup 目录或冻结产物发生变化
- **THEN** SHALL 立即撤销该客户端的批次 epoch，拒绝新的 references/rename/prepareRename
  与迟到的旧结果
- **AND** SHALL 退回独立原 UBT 路径，不得清理其他进程的缓存

### Requirement: Prepare SHALL deliver a usable, self-healing index without extra user commands or stale accumulation

`UEPrepare` 的完成语义 SHALL 覆盖 controlled index 的就绪状态；用户完成
`set platform → set project → build → UEPrepare` 后 SHALL NOT 需要额外执行任何平台专属索引
命令（如 `UEIndexFull`）才能获得可用的 C++ 定义跳转，这些命令 SHALL 仅作为显式重建入口保留。
index 构建状态 MUST NOT 因进程退出而永久卡死：持久化 `state.build.status` 为 `running` 而其
owner 进程已不存在时，系统 SHALL 判定为孤儿并复位，MUST NOT 依赖用户手动删除状态文件。prepare
家族 SHALL 在成功后清理自身中间备份（如 `.pre-*.bak`），不同 generation 的陈旧 controlled CDB
SHALL 被失效或清除，MUST NOT 以「存在即可用」误导 readiness 判定。

#### Scenario: Neovim exits mid-build and is restarted
- **WHEN** controlled index 构建期间 Neovim 退出，持久化状态留下 `status="running"`，其 owner
  PID 已不存在
- **THEN** 下一次索引操作 SHALL 将该孤儿状态复位，而不是判定"构建中"并拒绝新构建

### Requirement: Background index work and the clangd process SHALL yield to host CPU pressure without over-claiming guarantees

后台受控索引构建 SHALL 在启动前评估宿主整体 CPU 负载，负载超过高水位时推迟启动而非无条件
加压；负载采样 MUST NOT 通过 spawn 子进程实现（同步子进程往返阻塞主循环）。判定 SHALL 使用
高/低双水位滞回，MUST NOT 单阈值抖动式反复启停，且推迟 SHALL 有上限。宿主负载高于高水位时，
clangd 进程 SHALL 被施加 OS 级资源约束（降低优先级等可逆手段），MUST NOT 被终止或暂停——
clangd 是长驻交互式服务，终止会丢弃已构建的 preamble。系统 MUST NOT 声称能保证宿主 CPU 低于
任何阈值，也 MUST NOT 约束或挂起非自身启动的外部进程。

#### Scenario: Host is under heavy external load when a phase becomes due
- **WHEN** 某索引阶段的 deadline 到达，而宿主 CPU 使用率高于高水位
- **THEN** 系统 SHALL 推迟该阶段启动，MUST NOT 启动新的构建子进程，推迟原因 SHALL 可观测

## 选型与踩坑

- **选型（2026-10-09）**：冷大型 CDB generation 摘要与普通 phase 的 manifest/语义发布使用独立
  nvim worker；摘要按 size/mtime/ctime/dev/ino 绑定当前输入，计算期间替换必须丢弃并重算。
  未就绪与 worker 失败分别处理，旧 selection 只保留为历史，不冒充当前已验证 generation；
  成功后恢复延迟 reader，发布保持原 writer lease、来源校验和未变更不写入语义。
  子进程异步计算不等于整个启动/prepare 无卡顿；主循环最大间隔与 GUI 响应仍需分别实测。

- **踩坑（2026-10-08）**：正常 prepare 的 current/hot/full 曾统一只复用 proof；新项目桶没有
  receipts 或 accepted hints 时，所有候选都 deferred=`verification-not-cached`，不会自行生产证明。
  历史上其他项目桶的成功 proof 不能证明当前 build，也不能靠复制或改写其身份来命中。
- **阶段选型（2026-10-08）**：无外部 proof selector 的 full 在已有异步 worker、writer lease
  和宿主准入下有界生产独立原 TU 图证明，优先小组；每轮新接受一个合格批次后停止该轮证明。
  重复 prepare 完整重验并复用已有批次，缓存命中不消耗本轮新接受批次名额，下一组仍可在
  预算内证明；新增产物按计划发布，纯缓存轮保持 no-op。失效或预算未覆盖的组保留原 UBT。current/hot 与显式
  外部 store 仍仅复用；完整 argv、宏/PCH、图比较、来源及真实过期拒绝门禁保持不变。
  这是生产/命中路径的阶段修复，不能用条目数下降宣称全工程性能恢复。
- **踩坑（2026-10-08）**：冻结激活安装监听后，query profile 验证若在 proof store 内创建临时
  目录，会改变受保护的 receipt/asset 祖先目录并触发自撤权。查询 scratch 必须外置且自动收尾；
  不得提前应用 exclude、忽略目录事件或削弱真实修改与祖先 rename/delete 的保护来规避该故障。

- **踩坑**：`openspec/changes/archive/2026-09-28-restructure-super-unity-compression/` 的
  调查发现，「Secondary batches」二次合并的**实际交付量为零**——活跃索引缓存 33,014 个
  shard 中 995 个 `SuperUnity.UBT`、仅 **1 个** `SuperUnity.Batch`。根因不是合并质量差，而是
  门禁本身要求了一个任何单个 TU 都达不到的目标：`compare_graphs` 把引用基线构造成**所有原始
  图的 UNION**，在模板主模板/偏特化、宏生成重载集这类 context-dependent SymbolID 面前**结构
  性不可满足**——585 条被拒绝的 removed-ref 中 **0 条**落在该组自己拥有的成员源文件里
  （全部是共享头），其中 583 条所在位置在原始图之间本来就存在多个 symbol id，且没有任何单个
  TU（候选或原始）能同时携带 union 要求的全部 id。
- **已选方向（尚未实现）**：该调查按用户决策选定的方向是——Tier 1 只合并属于**同一次 UBT
  unity 发射序列**（`(module_root, compile_context_key, member_class)` 三元组相同）的组，
  按 UBT 自身 `NumIncludedBytesPerUnityCPP` 的整数倍字节预算打包，理由是这是编译器自己会
  发射的分组、不是语义改动，因此 Tier 1 SHALL NOT 要求逐组 `compare_graphs`，改用编译成功 +
  索引完成（`missing_main_shards == 0`）+ 成员源集合与被替换原始逐字节一致三项硬门禁替代。
  Tier 2（跨 gen/src 类、跨模块的合并）仍需证明，但其基线必须先改为可满足的形式，本方向
  未给出 Tier 2 新基线设计。
- **明确标注（防止冒充收益）**：该 change 的 22 个任务**全部未勾选**，Tier 1 无任何实测
  收益数字；本仓唯一受控冷启动 A/B 实测是 **1115.23 s → 1028.51 s（7.78%）**
  （`docs/cpp-index-restart-investigation.md`），这是另一次改动的结果，MUST NOT 被冒充为
  Tier 1 的收益，也 MUST NOT 用 CDB 条目数下降（纸面 1197 → 777，−35%）替代实测速度提升。
- **重要事项**：截至本次瘦身，`cpp-semantic-index-coverage` 的现行实现仍是本 spec
  Requirements 描述的状态（union 基线、逐组 compare_graphs、0 条 Tier 1 结构化豁免）；上述
  「已选方向」只是记录调查结论与选型意向，不代表 Requirements 已经改变。
