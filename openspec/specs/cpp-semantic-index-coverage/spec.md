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

**Tier 1 结构化豁免**：同一 `(module_root, compile_context_key)` 内、按字节预算打包的 UBT 合并
（默认不再按 gen/src `member_class` 拆分；`NVIM_UE_TIER1_SPLIT_CLASSES=1` 可回退）SHALL 用三条硬门禁代替图比较：私有候选编译/索引成功；
每个成员源都有主 shard；候选成员集合与被替换原 UBT 的成员并集完全相等。任一失败，该块 SHALL 保留原
UBT。门禁 SHALL 在写入 live CDB **之前**于私有目录完成（不乐观发布、不预置 shard）。Tier 1 receipt
默认只绑定 wrapper/成员源/工具/环境，头文件变化不会让普通配方失效，这是已接受的取舍；显式有序
forced-header 前缀配方还绑定直接强制包含头的完整字节，不能冒充传递依赖闭包。跨模块、跨编译上下文等
非 Tier 1 合并仍受上面的图比较约束。gen/src 不是编译上下文差异（同桶 argv 剥除只写标志后一致），
因此同上下文跨类别合并属于 Tier 1。

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

#### Scenario: A large background-index run has finished
- **WHEN** clangd 一次后台索引处理的任务数达到阈值，结束后编辑器空闲，没有未保存 buffer，也没有 prepare 在跑
- **THEN** 系统 SHALL 重启该 clangd 一次，以归还 Windows 堆不会自行释放的索引期内存；加载已有 shard 引发的重启 MUST NOT 再次触发回收，重启频率 SHALL 有会话级上限，放弃回收时 SHALL 记录原因

## 选型与踩坑

- **显式有序 strict 配方（2026-10-18）**：跨模块 generated-only 候选可由
  `tools/cdb_ordered_batch.py` 构造，但必须显式选定完整原 UBT owner，逐原 TU 独立图仍走既有
  strict 准入、冻结验证和 schema2 收据；有序构造或宏分类本身不授予资格，不自动扩大/缩小范围。
  普通 Tier 1 默认和身份保持，旧 strict 证明按 collector 身份正常失效。gzip 仅约束证明图
  存储，物理/逻辑摘要及原有比较门禁保留；正常收集、失效回退与真实冷收益须分别验收。

- **显式 Tier 1 加载边修复（2026-10-18）**：已接受的完整 flat owner 可显式重新证明有序
  forced-header 前缀配方，将完整强制包含序列放到同一候选 main 的成员区前，保留顺序和重复项，
  只删除对应 argv 位置。配方、头字节和同一完整原 UBT 序列参与新资格身份；旧收据不能改标签复用。
  初次迁移要求当前有效的完整 canonical flat owner，部分 child、多 owner 拼接或无 descriptor 的
  legacy root-only owner 不作迁移。收集后仅凭自己的有效收据继续复用；旧 flat 收据缺失不撤销
  新资格，新配方失效则保留仍有效的 flat 或既有回退。catalog 只持久选择偏好，不证明历史采纳或
  授予资格。普通配方、默认发现、完整覆盖与 Tier 1 三门不变；修复暖加载可达性不等同冷启动提速。

- **原生交付验收与进度窗口（2026-10-15）**：小范围隔离实验应复制真实 per-file CDB 与完整
  sealed unity receipt，交给生产生成器、worker、发布和 reload，不能由 runner 代写阶段 CDB。
  显式 headless fixture 只跳过前置扫描/GTAGS/csearch/RSP/分区，并禁止额外后台 proof；普通默认
  路径不变。真实输入 membership 会漂移，旧样本成员清单不可直接当作本轮覆盖或公平耗时基线。
  延迟 reload 不得抹掉已经观察到的 begin；仅同 generation、前阶段已完成的同 reader 且发布时
  没有旧 pending，才可采纳 loading 时现存的正向 begin。若 begin/end 整轮均发生在观察窗口前，
  仍可能走 180 秒兜底，此缺口尚未关闭；空 pending/前台响应不能冒充后台完成。
  clangd `sync` 有 idle 保证但阻塞服务线程，仅用于隔离验收，不能默认加入用户流程；
  `compilationDatabaseChanges` 会留下内存命令覆盖，也不能为了制造进度当作无副作用探针。

- **阶段屏障（2026-10-15）**：prepare 的 current/hot/full deadline 是生成调度，不是 clangd
  完成顺序；full 可以先于 hot 发布。普通同 generation 的实际纯追加在独立 publisher 预检后，
  等待前阶段同根普通 reader 的 `backgroundIndexProgress` begin/end，单阶段最多 180 秒；
  释放后重新验证 lease、输入与 generation 再完整发布。命令变化、显式 `UEPrepare!`、冻结
  receipts/批次和失效回退不因本屏障等待。CDB 生成与首阶段后台完成分别记录；超时不可冒充完成。
  clangd 会重排待执行队列，但已有路径的去重仍有效，不能表述成「全部旧 TU 重索引」。
  此顺序修复不改变二次合并资格，也不代表全工程索引性能已经恢复。

- **踩坑与选型（2026-10-15）**：current/hot/full 的模块选择并不天然构成 TU 超集；普通发布只有在
  同 generation、实际旧 CDB 非空且规范化文件唯一、旧 argv/cwd/output 完全不变并只新增文件时，
  才保留既有 reader。目录 CDB 有重验时间窗，打开源的 exact overlay 和 watched-files 通知不能
  保证加载新增数据库；延后用同根内存空文档触发目录查询，解析响应后关闭。被防抖推迟的非追加
  重启必须继续标记旧 reader 待退役，不能被下一次追加洗白。冻结 receipts、源码刷新和命令变化
  保留原有失效/独立缓存边界；此受限交付不代表冻结阶段无重启或全工程性能已经恢复。

- **踩坑与选型（2026-10-13）**：后台队列只存内存 completed 会让 owner 退出后的已接受候选
  无法继续收集。持久小摘要分别保存 proof、collect attempt/outcome、待收集候选和 owner PID
  活性；摘要和旧 worker 的 ok 都不授予资格。新一轮 plan 只发现匹配当前输入/profile/group 的
  旧结果提示，仍经原 receipt/cache-only 门禁、后台与发布 leases 重验再收集，失败候选继续证明
  或保留原 UBT。历史退出事件缺失时不得把推测写成唯一根因。
- **选型（2026-10-13）**：显式切分支刷新由子模块注册，首次无有效 CDB/shard baseline、未覆盖
  的新增/删除/改名委派既有 prepare；只有实际成功 prepare 完成信号能建立 baseline，正常 reader
  attachment 与私有加速结果分别报告。TEMP 盘点仅 dry-run，传递引用证据与未知活性保守保留，
  不实现删除；这些交付不等于真实全工程压缩和索引性能已经恢复。

- **选型（2026-10-12）**：源码刷新前的私有 reindex helper 共享原 semantic CDB 的 shard
  目录，使用 junction 而非复制/播种；复用已有 index build lease 和 active CDB writer lease，
  排除普通/batch 发布与 prepare 的 header shard migration 并发。phase 完成回调返回后才取锁，
  避免拒绝自己尚未释放的 lease；helper 退出后释放，异常仍走原重启确认路径。冻结 seed
  只读原缓存、只增独立 verified 缓存，clangd 原子 shard 写入可并存；不改用户进程生命周期。
  独立 Python CLI 只有工作目录锁，发布 lease 由 Lua 调用方持有。提交内存不足导致的 Job
  终止是失败回退，不能当作成功重索引耗时或全工程性能恢复证据。

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
- **已选方向（2026-10-16 首版已实现）**：该调查按用户决策选定的方向是——Tier 1 只合并属于**同一次 UBT
  unity 发射序列**（`(module_root, compile_context_key, member_class)` 三元组相同）的组，
  按 UBT 自身 `NumIncludedBytesPerUnityCPP` 的整数倍字节预算打包，理由是这是编译器自己会
  发射的分组、不是语义改动，因此 Tier 1 SHALL NOT 要求逐组 `compare_graphs`，改用编译成功 +
  索引完成（`missing_main_shards == 0`）+ 成员源集合与被替换原始逐字节一致三项硬门禁替代。
  Tier 2（跨 gen/src 类、跨模块的合并）仍需证明，但其基线必须先改为可满足的形式，本方向
  未给出 Tier 2 新基线设计。
- **瓶颈定位与 gen/src 合并（2026-10-21 实测）**：后台 BackgroundIndex 不用 preamble/PCH，每个 TU 都重新解析
  forced-include 的 SharedPCH 前缀；空 TU 去掉三个 `-include` 后 CPU 20.3→1.19 s，长驻 clangd 稳态约 7 s/TU
  （Engine 系），成员源约 0.09 s/个，写 shard 0.76 ms/个——**前缀解析是主瓶颈，SuperUnity 的收益即其摊销**。
  据此 Tier 1 默认取消 gen/src 拆分：8 模块/97 UBT 同输入 A/B（单长驻 clangd j1）24→16 TU，CPU 304.5（A/A 均值，
  波动 2%）→238.4 s（−21.9%）；成员主 shard 缺失 0，HadErrors 节点集合相同，拆分独有的 31 个定义全在
  ObjectMacros.h，低于 A/A 自身差异（1075/1124）。全工程离线规划保留 UBT 456→86。范围仅 8 模块，未做全工程
  与 gd/refs 查询验收；分组变化使既有 Tier 1 收据整体失配，首次 prepare 需重验新块（full 约 278 块，一次性）。
- **合并收益上限与被否决路线（2026-10-22/23 实测）**：16 个随机已发布 TU 的 CLANGD_TRACE 分解为前缀 45% /
  成员解析 9.5% / 符号收集 22% / 写 shard 23%（每个新 shard 约 4.7 ms、串行）；合并只削减前缀。
  Tier 2 跨模块（默认关）离线 UBT TU 364→168，生产入口单次 −19%，按用户判定不达标，未默认开启。
  **被否决：后台索引使用前缀 PCH**。官方 clangd 22.1.5 在 Compiler.cpp 无条件清除 `ImplicitPCHInclude`；
  自编并打补丁后，两模块 A/B 合计 CPU 仅 −12%（前缀主人承担共享头首写），且使用 PCH 的 TU 丢失 2756 个
  符号 ID/2405 个定义——全是其 UCLASS/USTRUCT 由 UHT 宏生成的成员（规范位置在前缀头的宏展开处，
  而 PCH TU 的 include 图没有前缀头节点，不写入这些 shard）。前缀主人无法补偿。要做对需改 include 图与
  分片合并，改动面大于收益。另：`SymbolCollector` 的 `shouldIndexFile` 结果在 4 处被 FIXME 丢弃，
  FileFilter 实际只按声明位置剪枝遍历，不过滤符号/引用。
- **踩坑**：同一 TU 内 `X.cpp` 与 `X.gen.cpp` 共同 include 无 guard 的 `X.h` 会重复解析并编译失败，
  UBT 从不把它们放进同一 unity；一律避开同名 pair 会让不拆分收益几乎归零（保留 UBT 86→434），
  所以采用「门禁失败后按类别拆分重试」。跨模块块越大，`StaticEnum<…> after instantiation` 类
  模板实例化顺序冲突越多（12 MB 块整块失败），块大小不能无界放大。
- **历史边界（防止冒充收益）**：该调查 change 归档时 22 个任务全部未勾选，尚无 Tier 1
  实测；后续首版阶段数据见下一条。此前的受控冷启动 A/B **1115.23 s → 1028.51 s（7.78%）**
  （`docs/cpp-index-restart-investigation.md`）是另一次改动的结果，MUST NOT 被冒充为
  Tier 1 的收益，也 MUST NOT 用 CDB 条目数下降（纸面 1197 → 777，−35%）替代实测速度提升。
  2026-10-13 的全工程 j12 空 shard A/B 中，原 UBT 为 1199.6166 / 1255.9569 s，旧 13 Batch
  为 1437.0561 / 1273.0648 s；均覆盖 14317 个源并保留相同两个 Vulkan 编译失败，OS 缓存未清。
  这两对未测得全工程提速，不能冒充新 Tier 1 的结果；后续不同 j 或内存上限的未完成实验也不能
  替代这些约 20–24 分钟的完整测量。
- **Tier 1 首版实测（2026-10-16，阶段验收，不代表全工程恢复）**：私有 shard，clangd -j1，
  低优先级，串行，格式为 CPU s / 墙钟 s / 峰值 WS：VulkanRHI 5 UBT/33 源，原 UBT 48.1/50.3/1.43 GB，
  Tier 1 18.2/19.9/1.36 GB；Renderer 8 UBT/79 源，原 UBT 93.0/96.3/1.65 GB，Tier 1 21.5/23.4/1.68 GB。
  两组门禁全过；Renderer 的 shard 文件名集合除 wrapper 外一致，符号/引用内容未做比较。
  真实 full phase 规划：3329 条/997 UBT → 110 块覆盖 540 UBT，纸面 2899 条（不是实测速度）。
  门禁选型：用户选「前置私有验证」，首次 prepare 额外付出约一次 Tier 1 索引的成本，以换取不存在错误窗口。
- **实际交付后的阶段验收（2026-10-16）**：当前工程与构建的 full 已补齐并启动生产
  Tier 1 队列；实际采用的 AugmentedReality 5 UBT/21个生成源，在同生产 query-driver/cwd/config、
  同 clangd、j4、新私有 shard 的窄 A/B 中，wall74.18→29.51s、CPU211.61→27.31s、峰值WS
  3.84→1.09GiB，源与头文件 own digest集合一致、成员/TU完整且无错误。资格成本49.17s另计；
  与候选冷索引分项相加约78.68s，不是端到端测量，未证明完全无资格缓存的首次启动更快。
  OS 文件缓存未清，正常后台队列仍在运行，非独占宿主基准。收尾生产快照为278 UBT→65批次，
  其余719 UBT、214 exact与2119 shader记录保留，14319源集合及内容摘要完整；65候选own shard
  均为TU且无错误。当前全工程j4冷基线在实验的8GiB进程commit上限内OOM，
  不完整结果不能计算全工程提速；本次属于可用阶段交付，不能表述为全工程性能已恢复。
  已验证范围与未完成事项归档于 `docs/release_2.9.0.md`。
- **后续全工程冷索引实测（2026-10-16）**：同当前 build/profile/clangd 22.1.5/j8 的两套空
  私有 shard，101 个已合格批次替换 481 UBT，保留其余 516 UBT、214 exact 和 2119 shader。
  14319 源完整覆盖，wall 1656.6612→1140.4418s（减少31.16%），CPU减少30.17%；峰值WS
  10.38→10.99GiB，不能宣称内存收益。全部 native own TU 无错误，两侧32032个实际
  source/header own集合、digest及flags一致；成员源前后seal一致，头文件输入未完整预封存，
  也未证明完整符号图等价。此处资格收据已存在，首次队列跨度76分57秒另计；OS缓存未清、
  固定A→B且非独占宿主。不能将本次reader冷索引收益表述为首次资格建立也更快，或与历史
  j12约20分钟直接相减。明细见 `docs/changelog.md`。
- **资格 worker 共享研究（2026-10-16，尚未生产接入）**：同 context 两组生成源候选的
  空缓存 j1 正反序实验均减少约26%的原生索引时间，峰值内存略增；不等于全队列或首次启动
  收益。后续图审计发现共享产物相对独立原图新增717个不可解析源引用目标、22个目标失去
  definition；即使成员 own 图相同，也不能据此直接交付共享缓存。把相同220源的12个UBT
  真正合为一个TU后，739个目标及其原定义位置全部恢复，refs/relations不变；部分符号存储
  位置、canonical declaration及文档字段改变，未证明全部header图或实际LSP行为等价。
  私有实测相对两候选TU的wall33.3866→26.6329s，仅限该范围。后续共享验证仍需保留
  独立失败归因及目标身份检查；样本与验证边界见 `docs/changelog.md`。
- **踩坑**：发布到 clangd 的 CDB 会按设计剥离 `nvim_ue_members`/`nvim_ue_module_root`
  （clangd 解析器拒绝未知键）。Tier 1 规划必须读 phase 的 `.semantic.json`，不能读已发布 CDB；
  已发布 CDB 规划出 0 块不代表元数据丢失。
- **发布重验（2026-10-16）**：producer 的复用检查不能替代稍后发布时的输入检查；成员源
  已变化时，旧 full phase 仍可能重新引入此前合格的候选。发布 SHALL 重新核对收据声明的
  wrapper/member/owned-overlay 字节和候选本身的 `candidate_sha256`，失效块保留原 UBT。
  缺少候选 digest 的旧 Tier 1 收据需重新私有验证，不补造证明；小 CDB 中的批次也走已有发布
  worker，避免源文件哈希落在编辑器主循环。未声明的头文件依赖仍保持既有 Tier 1 取舍。
- **负缓存边界（2026-10-16）**：超时、进程异常与不完整索引不是候选无法编译的证明，不能
  将它们永久缓存为拒绝并从后续计划排除。只有正常完成的确定编译拒绝可复用负收据；旧负
  收据缺少完成/退出/编译错误证据时重新验证。临时失败仍保留原 UBT，后续计划可以重试。
- **重复复用成本（2026-10-16）**：真实缓存组约93%的复用时间曾耗在反复验证同一 owned
  overlay 的物理名称。Tier 1 可在一次外层 collect/reuse 内共享该验证，退出即清空；下一次
  独立调用必须重新验证物理路径，overlay bytes 及成员源 bytes 仍按原门禁检查。不得把
  单次调用复用扩大为跨 prepare 的持久缓存，也不得据此弱化 strict 路线。
  真实60批次时的重复 full 交付84.75s，输入与五类产物 bytes/mtime 不变、reader不重启；
  此验收只覆盖 full 阶段，不代表完整 UEPrepare 时延或全工程冷索引收益。
- **混合与监听的验收边界（2026-10-16）**：当时 mixed strict/Tier 1 发布的 strict coverage
  校验会拒绝激活，不能把该 fail-closed 回归称作两类批次同时被 reader 消费。监听组错误会广播
  到多个回调；盘根的 direct 祖先订阅出现在日志中，不证明该盘根是原生 overflow 来源，亦不
  证明递归监听了整个磁盘。不能据此删除祖先保护。
- **原生缓存角色变化（2026-10-16，机制已复现，自动修复未落地）**：clangd 22.1.5 的
  [BackgroundIndex](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.5/clang-tools-extra/clangd/index/Background.cpp)
  按源内容 digest 判断已加载 shard 是否过期。独立原生实验中，先被 Unity 包含的源改为 exact
  主文件、甚至改变编译宏后，同字节的旧非 TU shard 仍被复用；仅在私有目录退休目标 own shard
  后才真实重索引，产物与空缓存对照一致。因此缓存存在、进度结束和 CDB 发布完成均不能独自
  证明当前 exact 命令已执行。两个真实 exact 命令的独立冷索引已成功，不能将其旧非 TU 缓存
  解释为当前编译失败；缺少可选 `cmdl` 也不能单独作为失效判据。后续修复必须绑定明确 owner
  与编译命令变化，在对应 native writer 确认退出后重验身份、仅处理受影响 own shard，并保留
  无变化发布的 no-op；不得通过全量清缓存掩盖这个缺口。当前仅完成调查，未修改生产缓存。
- **证明与观测的边界（2026-10-17）**：严格图比较通过不证明公开分组器会生成候选；六源
  跨类别样本只经显式私有入口取得完整资格，生产工具身份校验实际拒绝该试验收据。原图
  缺少声明记录也不证明原 TU 无声明：真实 TU 的 libclang 可以在同一引用处找到同 ID、同位置
  的声明。此类结果只能作为待设计的补充证明，不能改写原图、把普通引用当声明或跳过 provider、
  body 与其余图门禁。LSP 对照须核实实际编译命令，并区分缓存查询与前台 AST；错误推断到
  触发文件命令的空结果不能归因于合并图。实测与未完成项见 `docs/changelog.md`。
- **后续入口与发布修正（2026-10-17）**：strict 规划保留原同类块，同类残余迭代稳定后才尝试
  跨类别，以保证计划组能被 worker 独立重规划。六源样本已通过公开 plan/work/collect 和重复
  复用，不再依赖私有显式分组入口；完整语义及工具身份门禁不变。混合 publisher 将相同 Tier 1
  基线同时保留在 live/verified，strict 只消费其未占用原 UBT，重叠整组延后；覆盖检查不放宽。
  后续隔离11源 reader 已验证真实冻结激活、文件监听撤权与保留 Tier 1 的限定重启；六个严格
  成员的引用、关系及目标/已知定义保留。默认混合调度及完整 header/LSP 等价尚未验收。
- **Tier 1 扩容纠错（2026-10-17）**：原八 UBT 与字节上限属于规划预算，不是 Tier 1/Tier 2
  的语义分界。同 module/full context/member class 且保序的 27 UBT/589 源样本，经现有
  Tier 1 三项门禁取得资格，重复调用无新索引和存储改写；此前以 strict provider/独立 header
  UNION 失败阻塞该资格，是不当扩大门槛。仍不得忽略已证实的源绑定/引用目标/定义损失。
  增量扩容须保留当前正常小组基线，仅在大组真实重验后原子替换完整旧组，失效时按当前有效
  小组回退；索引集合被旧组覆盖不能冒充新组已验证。扩容接入后真实默认 scheduler 两次仍
  完整保留原有 101 组；27 UBT 的公开资格/收集/普通复用/损坏回退已验，重复复用成本有所
  增加。自动大组优先已接入正常队列，空资格缓存的首次队列收益已实测；包含 reader 交付的
  首次净收益与新的全工程性能仍待验证。
- **首次资格调度选型（2026-10-17）**：Tier 1 在同 tuple 保序、完整旧 owner 与普通回退组
  不可拆的边界内优先尝试大组；首阶段每轮最多两个候选，各限 32 UBT 和 32×384KiB 实际
  成员字节预算。首次无需先验证小组，已有有效小组也不因提案而失去资格。只有最终 collector
  实际采用并确认发布后，队列才跳过其小组任务；失败、失效或未采用时恢复小组验证，尚无
  有效小组资格的范围保留原 UBT。恢复提示不授予准入，失败尝试与回退成本必须计入首次 Q；
  静态规划减少任务或调度回归通过不代表首次启动提速。27 UBT/589 源的真实空资格缓存 A/B
  已将队列耗时从 156.830s 降至 72.425s，四次资格变为一次，四个子组经 collect 与私有发布
  确认后跳过；完整 own 闭包保持。固定 A→B 顺序未控制 OS 缓存，私有发布也不代表用户激活
  或冷 reader，不能外推完整引用/目标等价或全工程首次收益。旧 repeat 因 observer 误禁合法
  collect 失败；修正观察器后两侧重复队列已验证零新资格/索引、产物不变。合法的无变化 collect
  不等于重复索引，不得为迎合观察器而删除恢复语义。
- **候选排序踩坑（2026-10-17）**：曾按待验证子组数降序选择两个源文件类大组，真实编译
  均失败、未被采用，work+collect 已付175.8325s，小组回退成本尚未测。104任务只是未实现的
  全成功预测，精确源码失败原因仍未证实；已撤回该排序及其新增用例，保留原自动large-first
  cap2、packing、完整 owner 与资格/发布门禁。全量贪心起点可能产生不同于已验证子集的候选，
  不能沿用子集资格或速度；计数预测、静态审查和功能回归均不替代真实成功率及失败总成本。
- **whole-owner 踩坑（2026-10-17）**：收集器若先排除已采用的大组，再将旧 catalog 与新提案
  按大小竞争，会让局部重叠的新组绕过完整 owner 边界。必须从当前完整重验后的实际选择出发
  采用新提案；仅有候选收据或原始范围被覆盖，均不等于最终采用。调度关系只约束任务，当前
  候选仍过原资格门禁；单个父组失效不得连带阻断仍合法的小组回退。
- **坐标编码与缓存边界（2026-10-17）**：资格 runner 默认 UTF-16，而真实 Neovim reader 可
  协商 UTF-8；clangd 的持久索引位置也随编码变化，见固定版本的
  [SymbolLocation.h](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.5/clang-tools-extra/clangd/index/SymbolLocation.h#L20)。
  真实六源对照中的两条列号差异，经初始化协议与源码字节位置闭环后消除；比较须基于实际
  协商结果，不能丢弃位置字段或重映射符号身份。资格产物若用于缓存交付，必须验证两端编码
  一致或另证转换正确；同工具/CDB/源摘要不足以授权跨编码播种。
- **完整 reader 保全缺口（2026-10-17）**：全工程两侧保存的完整索引产物中，源 own 节点和
  源文件覆盖相同，仍发现原ref-slab记录保持但目标符号/定义在候选磁盘索引消失；定向解码已确认
  两例，其中一例所属原 UBT 未合并。后续role核对区分Reference与definition-role记录，不可把
  collector附加的Call位当真实调用。源相关 ID 汇总包含容器、归属与关系端点，不能直接
  当悬空引用计数；旧定义位置减少也须区别另有定义仍在的情形。小型独立实验已复现缓存历史
  对共享头目标的影响，但尚未还原这两例的历史全工程成因，不能据此概括归因或免除损失。
  速度实测与结构三门通过不能代替这些已发现问题的处置；
  当前保存产物稳定性不补造历史完整预封存，磁盘图也不冒充实际 LSP 内存合并图。
- **子集缓存的因果反例（2026-10-17）**：真实小型 clangd 实验中，固定最终 CDB、有效命令、
  源字节和编码，仅改变先前子集 producer 的完整缓存，三源引用/关系保持却改变宏生成方法
  的全局目标/定义集合。不能把合格子集 cache 直接当更大最终 CDB 的完整 cache；最终 CDB
  改变后的缓存交付必须独立验收。同一最终 CDB producer 到同 CDB reader 的完整交付仍需
  单独实测，不能由暖启动数字推断首次收益。此反例不恢复历史全工程的具体调度顺序。
- **同目录缓存交接原型（2026-10-17）**：两个完整 Tier 1 组可共用一次真实 producer，并在
  相同最终 CDB、缓存目录、命令上下文和实际编码下交给单个私有 reader。每个 main 须有真实
  执行与 own/cmdl 证据，普通收据门禁和键保持；共享运行失败不伪造各组独立资格结果。
  交接另验当前工具、driver、环境、输入闭包和完整缓存清单，producer/reader 全生命周期持有
  同一个写入租约。已知正向闭包的预封存成本计入首次使用；原型未解决未知闭包、负向查找
  或完整 header 目标保全。小型实验及真实工程已知闭包的 27 UBT / 589 成员双组实验，均已
  验证共享 producer 后同目录 reader 零重建、完整缓存与绑定资产不变；已知闭包预封存与
  交接校验必须计费，不能冒充未知闭包首次总成本。原始 UBT 完整语义、匹配首次总收益及
  正常编辑器接线仍须分别验收，不得由此接管用户现有缓存。四组独立资格加冷reader对照
  及离线比较已完成：成员引用/关系保留，公共成员目标域内旧目标及已知定义位置零丢失；
  局部符号记录仍有声明归属与定义补充差异。必要组件费用差不等于等价ready提速。
- **冷进程与暖加载边界（2026-10-17）**：相同磁盘与对称loader模型比较不能证明实际
  cold-live和warm-live相等。本次两侧各有相同312个非main可达shard，涉及13690个全局ID；
  冷编译直接安装新slab，暖加载仅遍历CDB main可达source-map，实际可见性须独立查询。
  命令行forced include来自可能无真实FileEntry的predefines buffer，include-graph回调可省掉
  main边而仍保存own节点。真实guarded微型夹具四运行已复现：原命令的目标冷有暖无；
  保留原`-include`并在wrapper显式include同一guarded头后，真实main边存在、目标冷暖均有，
  orphan从2变0；成员引用/关系和目标记录相等，两warm零重建且5个idx字节/大小/mtime不变。
  此结果仅闭环guarded夹具，未证明全部孤立路径或可直接用于真实PCH。实际root记录检查中，
  内层guarded头无自身符号/引用，外层PCH及另一root有独立记录；只加内层anchor不能推定
  保全外层记录。后续真实窄范围P/W1四组查询相等，但待查目标在首次producer已有
  definition-role ref-slab记录而磁盘/live无目标，不能归为冷到暖丢失；collector附加的Call位
  也不能当真实调用证据。不同role须分别解读，不得声称全部ID丢失或凭零重建宣称等价。
  同缓存reader交接已增加从实际最终CDB mains沿全部Sources keys出发的完整own-shard
  可达性门禁；这是storage topology必要条件而非完整语义充分条件。失败只拒交接，
  保留已接受候选的压缩与普通资格收据；旧交接schema证据拒绝。专项contract与两个真实
  producer的正反例已通过并独立复核，未启动native reader；后续required-native全量亦通过。
  阻止不完整交接不等于性能恢复，首个producer自身的目标缺口仍须独立定位。
  保留producer进程并非小配置接管：私有Python stdio不能直接交给用户Neovim，需另证
  同owner客户端的资格观察、发布/attach及生命周期；不能以该设想绕过现有门禁。
- **共享宏头的首次producer反例（2026-10-17）**：fresh split/unity局部实验中，所有own均
  main可达，仍出现split后处理源的真实Reference-bearing occurrence保留而目标在磁盘/live
  缺失，unity中目标存在；完整源引用Counter保持不能证明目标保全。此夹具与共享spelling
  header的更新门禁解释相容，但split成员作为main、unity作为include，另有flags/补全字段
  差异。随后两侧成员均included的原UBT wrapper对照已完成：完整成员symbols/refs/relations
  Counter相等，先处理方法的全字段也相等；共享宏头仍仅unity保留后处理方法，所有own可达。
  因而成员完整记录相等仍不足以证明共享头目标保全；该微型结果不等于所有header symbols
  相等或真实工程根因已证，不授权跨context强合并，不替代适用资格与全工程性能/失效验收。
- **显式strict范围选择（2026-10-17）**：生产API可指定单个精确原始范围，绕过默认class-first
  候选发现而不绕过既有strict proof、缓存身份、完整成员与预算门禁；未指定时默认流程不变。
  失败保留请求的完整原始范围，不能用较小子组替代该请求的资格结果。入口不自动接入CLI/Lua，
  也不把路由测试或旧收据当新范围的真实资格。真实范围资格、首次费用和编辑器交付仍须
  分别验证；功能回归通过不能代替这些实际验收。
- **缺失集合纠错（2026-10-17）**：589 源四组到单组对照中的 13 个新增未解析 ID，仅作为
  当前可达头文件的关系对象出现，无直接引用或 container，独立冷单组也相同；旧全局符号表
  同样不含它们。缺失集合差分不证明旧目标曾存在，不得把新增未解析关系报成旧符号或源引用
  丢失，也不得将额外全图条件替换 Tier 1 三门。此纠错不抹去上面的全工程真实目标丢失证据，
  亦未证明完整 header 图或 LSP 内存等价。
- **严格 forced-include 前缀（2026-10-18）**：支持的完整、有序、绝对路径普通 `-include`
  序列可移入最终候选 main，保留原 UBT 命令与全部图证明，使头文件具备真实加载边；不能
  重复包含未加 guard 的头、只移动部分选项或将参数操作数误当选项。构造身份须贯穿严格
  队列、缓存、冻结产物、收据及恢复/激活，旧 collector 证明不得改标签复用。此选择不改变
  Tier 1 构造或准入；全 Sources 可达性、实际冷/暖查询、首次资格与重复准备仍分别验收。
  标准库预索引独立计费，不能等同项目重建，也不能从零项目重建推断全部工作为零。
  既有证明目录选择可限定 current/hot/full 阶段；未指定阶段保持原行为，未选择的 full
  继续普通 Tier 1 复用/队列。小范围严格证明不得使 full 丢失既有压缩，混合发布仍要求
  与已采用 Tier 1 的原始范围完全不重叠；真实工程性能和用户激活须另有实际证据。
- **有界严格剩余范围（2026-10-18）**：普通 prepare 与两类 collect 可组合分别重验的资格，
  当前 Tier 1 整组优先；其 memo 作用域必须先退出，再进入 strict 验证，重叠严格 owner
  整组排除。显式 `request.residual_strict_limit` 仅为 1 或 2，以串行剩余范围资格替代本次
  新资格队列，不默认追加；已有压缩继续保留。前次计划的有界游标只提供轮转调度，避免
  缓存拒绝永久占住队首；回访仍须当前资格检查，使头文件修复可重新验证。此接入不改变
  collector、收据或语义准入，不能由游标、缓存提示或小型混合集成测试推断全工程交付与收益。
- **实际 child owner 与缺目录选择（2026-10-18）**：strict catalog 的父范围只是查找提示，
  资格与整组互斥边界按当前验证通过的实际 receipt owner 判断；保留独立有效 child，不能
  以整个父范围未获资格为由丢掉其压缩。既有 owner 优先，重复收集/复用保持候选；父范围
  完成确认仍须单独核验。Tier 1 cache-only 仅在本次收据目录 stat 抛出 FileNotFoundError
  时直接返回原命令的未接受分组；已存在目录/文件及其他访问错误仍走原 verifier，不存
  负缓存、不跳过其他 catalog store，不改 strict 门禁。准备成本降低须单独实测，不能
  当成资格或冷 reader 提速，也不豁免完整语义与性能验收。
- **图差异的分类（2026-10-18）**：完整诊断记录会区分空 definition、完整定义与声明归属，
  其差分不得直接解释为旧已知定义丢失，也不得冒充生产准入结果；需分别核验旧目标 ID、
  非空定义位置、引用/关系及其可达性。实际单进程多 TU 的共享头缓存不保证等于各 TU 独立
  图的并集，原始侧也要实测。原始侧已有缺口不豁免候选的新损失，冷进程内可见的目标也
  不自动证明暖加载可见。诊断预算耗尽保留失败与成本，仅在新检查中继续完整比较，不能
  把未完成的输出当零差异或补写历史成功回执。
- **长期优化：clangd 索引的模块优先级（2026-10-23 记录，未实施）**：current/hot/full 只决定
  CDB 分阶段发布顺序，阶段内的执行顺序不由我们控制。源码证据：stock clangd 入队时打乱任务
  （`Background.cpp` shuffle）；`BackgroundQueue::adjust` 丢弃 SeenKeys 中已有 key 的任务，
  因此重发 CDB 不能给已排队任务重新排序；`boost(Tag)` 按文件名粒度生效，只由 didOpen 触发；
  过期检查只发生在入队时。现状还有三点：`INDEX_CORE_MODULES` 含 Engine/UnrealEd，hot 中 Engine
  约占 48%，Android 场景也带 UnrealEd；BufEnter 切模块只调整 `set_active_module` 分数并记录
  baseline 哈希，不排 current；已有 job 时不抢占。两类场景分开处理：
  ① full 尚未发布：切到其他模块后约 1.5 s 防抖重排 current，并加探针；
  ② full 已发布但仍在索引：需要目录前缀 boost（A：给 clangd 打补丁，如 `$/boostDirectory`
  在 `BackgroundQueue::boost` 做前缀匹配），或预置 shard（B：排队任务能否跳过尚未验证）。
  另外可在 current 与 hot 之间加一层渲染层（Renderer、RenderCore、RHI、平台 RHI、Core、
  CoreUObject，约 1000 条）。以上均待实测；收益未验证前不得宣称渲染模块已经优先完成索引。
- **clangd 用完归还（2026-10-26）**：Windows 版 clangd 没有 malloc_trim（`ClangdMain.cpp` 中这部分只在
  `__GLIBC__` 下编译）；当次实验在后台索引结束后仍观察到约 2.5–3 GB 未被组件统计解释的 commit，
  不能仅凭缺少 malloc_trim 推断所有已释放内存都不会归还。曾试过 Segment Heap
  （manifest 和 IFEO 两种方式），实测无效，已证伪。最初看到的下降，是因为测试用的 clangd 缺少
  `lib/clang` 资源目录，少解析了内容。因此采用重启回收（`ue.clangd_memory_reclaim`）：大规模索引完成后
  静默重启一次。实测 16 个 TU 时 3.32→1.85 GB；生产 shard 库下降到约 4.3 GB，其中约 3 GB 是必要的
  内存索引（Dex）。preamble 改为 `--pch-storage=disk`（3 个 TU 时 1291→223 MB）。disk 模式下 clangd
  被 kill 后会留下 `preamble-*.pch`，所以每个会话的 clangd 使用独立 TEMP（`ue.clangd_temp`），
  只清理所属进程已确认退出的目录。
- **回收安全窗口（2026-10-27）**：normal mode 不能作为用户空闲的证据，index job 为空也不代表
  UEPrepare 已结束；回收须读取真实 prepare owner 并检查用户活动。新进度必须使上一轮的回收定时器
  及其重试失效，避免在最新索引刚结束时提前重启。隔离的真实 Neovide/LSP 夹具已验证一次自动回收、
  原文档重新附加与既有 shard 加载后不重复回收；显式 root 与测试启动命令不代表完整 LazyVim 启动链，
  小型夹具也不能作为完整 UE 工程长期内存或性能验收。
