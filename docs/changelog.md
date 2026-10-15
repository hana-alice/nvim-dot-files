# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)
- `v1.9.0` → `docs/release_1.9.0.md` (tag pending explicit confirmation)

- `v1.9.1` → `docs/release_1.9.1.md` (tag pending explicit confirmation)
- `v1.9.2` → `docs/release_1.9.2.md` (tag pending explicit confirmation)
- `v1.9.3` → `docs/release_1.9.3.md` (tag pending explicit confirmation)
- `v1.10.0` → `docs/release_1.10.0.md` (tag pending explicit confirmation)
- `v1.11.0` → `docs/release_1.11.0.md` (tag pending explicit confirmation)
- `v1.11.1` → `docs/release_1.11.1.md` (tag pending explicit confirmation)
- `v1.11.2` → `docs/release_1.11.2.md` (tag pending explicit confirmation)

- `v1.11.3` → `docs/release_1.11.3.md` (tag pending explicit confirmation)

- `v1.12.0` → [docs/release_1.12.0.md](release_1.12.0.md) (incremental scope; tag pending)
- `v1.12.1` → [docs/release_1.12.1.md](release_1.12.1.md) (tag pending)
- `v1.12.2` → [docs/release_1.12.2.md](release_1.12.2.md) (diagnostic stage; tag pending)
- `v1.12.3` → [docs/release_1.12.3.md](release_1.12.3.md) (demand-driven recovery; tag pending)
- `v1.12.4` → [docs/release_1.12.4.md](release_1.12.4.md) (native junction verification; later ancestor-event fallback recorded; tag pending)
- `v1.12.5` → [docs/release_1.12.5.md](release_1.12.5.md) (stable directory writes and complete ancestor watches; tag pending)
- `v1.12.6` → [docs/release_1.12.6.md](release_1.12.6.md) (modified-document preflight and clean demand recovery; tag pending)
- `v1.12.7` → [docs/release_1.12.7.md](release_1.12.7.md) (automatic clean-document recovery; tag pending)
- `v1.12.8` → [docs/release_1.12.8.md](release_1.12.8.md) (padded search query cancellation; tag pending)
- `v1.12.9` → [docs/release_1.12.9.md](release_1.12.9.md) (durable search overflow recovery; tag pending)
- `v1.12.10` → [docs/release_1.12.10.md](release_1.12.10.md) (second qualified SuperUnity batch; tag pending)
- `v1.12.11` → [docs/release_1.12.11.md](release_1.12.11.md) (retain document-blocked original readers; tag pending)

- `v2.0.0` → [docs/release_2.0.0.md](release_2.0.0.md) (CodeDiff default review; Diffview retained; tag pending)
- `v2.1.0` → [docs/release_2.1.0.md](release_2.1.0.md) (daily editing and maintenance diagnostics; tag pending)

- `v2.2.0` → [docs/release_2.2.0.md](release_2.2.0.md) (IDE experience; local validation complete; tag pending)

- `v2.3.0` → [docs/release_2.3.0.md](release_2.3.0.md) (search, reading and window recovery; tag pending)

- `v2.3.1` → [docs/release_2.3.1.md](release_2.3.1.md) (daily file protection and discovery; tag pending)

- `v2.3.2` → [docs/release_2.3.2.md](release_2.3.2.md) (navigation and editing entry fixes; tag pending)

- `v2.4.0` → [docs/release_2.4.0.md](release_2.4.0.md) (memory document find and editor reuse; tag pending)

- `v2.5.0` → [docs/release_2.5.0.md](release_2.5.0.md) (document locations and copy actions; tag pending)

- `v2.6.0` → [docs/release_2.6.0.md](release_2.6.0.md) (development workbench and run-owned evidence; tag pending)

- `v2.7.0` → [docs/release_2.7.0.md](release_2.7.0.md) (named investigations and interruption continuity; tag pending)

## Unreleased

### 2026-10-15 — 收敛：探针处置、DAP 布局用例修正与全量回归

**Task**
收敛现有工作：处置未处置探针失败、修正全量回归中的真实失败，不开新方向。

**Implemented**
- 处置 11 条未处置探针失败：resolve 4 条（`already-at-definition` 为设计内结果；`cpp-switch-reindex writer-busy` 是互斥锁按设计拒绝；2 条 `codediff:` foreign-buffer 已由 10-12 修复）；defer 7 条 C++ 导航/冷 TU 性能记录，待真实 nvim 验收后复测。
- `ide_debug_spec`「rail 改成源码」用例：DAP 布局 owner 会对 rail 设置 `winfixbuf`，用例现在先解除固定再改作源码窗口，表示这是用户的主动改用；生产代码不变。

**Pitfalls / Gotchas**
- 单进程串行全量下有 10 个用例依赖执行顺序而失败（`dap_bottom_panel` 1、`keymaps_file_reference_layout` 2、`keymaps_layout` 1、`ue_build_callback` 5、加 1 个随轮次变化）；单独跑和每文件独立进程都通过。按文件边界扫描未发现残留 `winfixbuf` 窗口，「winfixbuf 泄漏」假设不成立，根因未定位。

**Validation**
- `ide_debug` 19/19。
- 每文件独立进程全量 `tests/run_parallel.lua`（JOBS=2）243/243 文件通过，539s。
- 单进程串行全量 3977/3987，10 fail，2 skip（GTAGS X1 native root、PCH stage 为宿主跳过）；失败均为上述顺序依赖。

**Follow-ups**
- 定位串行全量的跨文件状态泄漏。
- 由用户重启 nvim 后做真实 `:UEPrepare` + gd/gr 验收，再处理已 defer 的探针。

### 2026-10-15 — 原生隔离验收分阶段生产交付与早到进度守卫

**Task**
P3：让真实 prepare/index 交付链路在私有真实 UE 小输入上运行，核对查询、阶段屏障与重复 prepare。

**Implemented**
- 显式 headless fixture 校验私有输出和有界复制输入，复用真实 prepare 锁/running/schedule；后续真实生成器、worker、publisher 和 clangd reload 不由 runner 代做。
- fixture 只跳过前置扫描、GTAGS、csearch、RSP 生成和分区，仅该测试路径禁止额外后台 proof；普通生产默认不变。
- 延迟 loading 保留已观察到的 begin；只从同 generation、前阶段已完成且发布时没有旧 pending 的同 reader 采纳现存正向 pending，排除超时旧轮、外来旧轮和另一 reader。
- 新增隔离入口及进度竞态回归，记录治理 spec 的验证边界和未关闭窗口。

**Pitfalls / Gotchas**
- 原 per-file 输入与旧样本已漂移，必须用本轮 sealed receipt 的完整成员重新抽取；不能保留旧分母或公平 A/B 口径。
- 仅无 pending 或前台响应不能证明后台 idle。完整 begin/end 均早于 loading 的窗口仍未关闭，可能等待 180 秒；没有默认加入阻塞 clangd 服务线程的 `sync`，也没有用持久命令 overlay 制造假进度。

**Validation**
- 相关 filter：`index_prepare_fixture` 8/8、`index_generation` 46/46、`index_subset_async` 11/11、`cpp_semantic_index` 1/1、`clangd_commands` 23/23、`ue_api` 66/66、`ue_platform_boundary` 20/20、`index_delivery` 137/137、`index_publication_async` 18/18、`index_batch_publication` 30/30、`index_batch_background` 14/14、`ue_project_context` 15/15、`commands` 167/167、`smoke` 19/19、`stability` 26/26、`structure` 85/85；686/686、0 fail/skip，AST lint 6 文件通过。按任务要求未跑全量。
- 私有真实 clangd 22.1.5、j=1、BELOW_NORMAL：生产代码 current 8→hot 17→full 20，首阶段 end 93.472s、最终 end 202.864s，193/193 源、20 TU 各索引一次；3 符号 definition/references 正确，首次查询 14.019s，其余约 1–3ms。重复交付产物 hash/mtime 不变，未重启或重新索引。
- 第二轮全新私有 shard 定向实测：真实 begin 232.469s 早于生产 loading 232.966s，正向 pending 被采纳，end 249.463s 完成；同 reader、193/193 覆盖、20 TU 各一次、重复产物不变。两轮 clangd 墙钟累计 476.063s，单次及累计均在任务资源时限内；不作为公平性能 A/B。

**Follow-ups**
- 完整早 begin/end 窗口仍需可靠非阻塞的完成关联；本轮不证明用户完整 UEPrepare 的扫描/CDB/csearch 总耗时改善，也不证明全工程二次合并性能恢复。

### 2026-10-15 — 普通阶段追加等待前阶段后台索引完成

**Task**
P2：核实 prepare 阶段发布顺序，为普通追加加入有界完成屏障。

**Implemented**
- 同 generation 的普通纯追加由独立 publication worker 预检，等待同根普通 clangd 的 `backgroundIndexProgress` begin/end；每阶段固定 180 秒兜底，释放后重新验证输入与 lease。
- `UEPrepare!` 整轮、命令变化、冻结批次及失效回退绕过屏障；后续 full 仍完整发布，不改变二次合并资格和冻结门禁。
- 最小后台状态区分 CDB 生成、首阶段完成与超时；cached partial 的新会话仍建立屏障，待退役 reader 不能提供完成证据；更新治理 spec。
- 预检只读分类；非追加/冻结绕过后仍按 manifest→CDB 的原顺序写入，manifest 写失败不提前更换 CDB。
- 增加屏障事件与真实 worker 回归；压缩 `_build.lua` 重复注释以维持既有 800 行结构门禁。

**Pitfalls / Gotchas**
- 受控 schedule/publisher 接缝证实无后台 end 时约 1.52 秒即可发布 full，但这不是完整 UEPrepare 实机耗时。
- LLVM 会重排待执行队列，已有路径仍去重；不能称全部旧 TU 必然重索引，也不能据此断言首阶段必然变慢。

**Validation**
- 相关 filter：`index_generation` 46/46、`index_subset_async` 11/11、`cpp_semantic_index` 1/1、`clangd_commands` 23/23、`ue_api` 66/66、`ue_platform_boundary` 20/20、`index_delivery` 130/130、`index_batch_publication` 30/30、`index_publication_async` 18/18、`ue_project_context` 15/15、`commands` 167/167、`smoke` 19/19、`stability` 26/26、`structure` 85/85；合计 657/657、0 fail/skip，AST lint 14 文件通过。按任务要求未跑全量。
- 私有真实 clangd 20 TU、j=1、BELOW_NORMAL：生产屏障接真实 LspProgress，93.473s 首阶段 end，93.489s 才追加 8→20，189.754s full end；194/194 源、20 主 shard 全在，旧 8 TU 各索引一次。CDB 由私有 runner 原子追加，未实测完整 UEPrepare 链路；本样本二次合并为 0，不代表全工程性能恢复。

**Follow-ups**
- 完整 UEPrepare 原生链路、跨进程 reader 身份及全工程二次合并/索引性能仍待验收；无公平 A/B，不把两轮绝对耗时差当收益。

### 2026-10-15 — 普通索引阶段只新增 TU 时保留 clangd

**Task**
P1：核对 current/hot/full 生产交付与私有分阶段实验的接缝，补首阶段真实定义/引用查询。

**Implemented**
- `lua/ue/index/_publish.lua` 比较实际旧、新 CDB 的唯一文件与完整 argv/cwd/output，仅给纯新增发布追加标记。
- `lua/ue/index/_build.lua` 在更新 selection 前保存旧 generation；`_clangd.lua` 对符合条件的原始 reader 延后触发固定目录 CDB 重载，保留同一进程。
- 非追加重启被防抖推迟时标记旧 reader 待退役，拒绝后续追加误认；冻结批次与源码刷新沿用原有处理。
- 增补发布正反例、延迟回调失效、重启防抖与 build 回调接线回归；记录治理 spec 的选型与踩坑。

**Pitfalls / Gotchas**
- 阶段名称不能证明 TU 超集；exact overlay 和 watched-files 通知不能保证重读目录 CDB。
- 冻结二次批次仍使用独立 CDB/cache，不能据普通追加宣称所有阶段无重启。

**Validation**
- `index_generation` 46/46、`index_subset_async` 11/11、`cpp_semantic_index` 1/1、`clangd_commands` 23/23、`ue_api` 66/66、`ue_platform_boundary` 20/20、`index_delivery` 108/108、`index_batch_publication` 27/27、`index_publication_async` 13/13，均 0 fail/skip；AST lint 6 文件通过。
- `structure` 85/85，合计 400/400、0 fail/skip。私有真实 UE 同进程固定根 8→20 TU：首阶段 108.07s、80/80 源；完整小样本 232.52s、194/194 源；首 8 TU 未重索引，3 符号 definition/references 核对通过。本样本无二次合并命中，不构成全工程性能验收。
- 首轮错误复制 4 个 exact 源的完整覆盖结论已弃用并重跑；两轮 native 合计 452.87s。未运行全量回归，未触碰运行中用户客户端。

**Follow-ups**
- 冻结路径阶段连续性、跨进程 reader epoch 与全工程压缩/索引性能仍需独立验收。

### 2026-10-14 — shader GTAGS 分根验收与真实失败提示

**Task**
修复 scan2 A1/A2 空 GTAGS、跨盘项目被忽略，以及 B5 shader 失败一概称 GTAGS empty。

**Implemented**
- prepare/sync/watcher 共用显式配置、独立 roots、输入快照、正向 witness、writer lease 与原子发布；失败保留旧库。
- 定义/shader/references 组合查询；shader callback 传实际 backend/reason/coverage，并防止迟到跳转；私有有效配置补齐 GLSL。
- 删除重复冷 GTAGS 构建和单库 helper，ue.lua 减少 138 行。

**Pitfalls / Gotchas**
- ignored 警告仍可 exit 0；三文件非空不证明定义存在。
- 同样 shader 清单中现有 parser 仍漏部分入口函数，具体原因待验证，不能写成 100% 恢复。

**Validation**
- gtags 22/22、compat 14/14、ue_api 66/66、ue_goto_behavior 105/105、commands 167/167、host_resource_discipline 13/13、stability 26/26；均 0 fail/skip。AST lint 3 文件通过。
- 两个指定真实样例通过；完整清单路径覆盖 1820/1820；固定 100 定义 87 命中、13 缺失，0 行号陈旧/查询错误。真实用户 GTAGS 未变化。

**Follow-ups**
- 保留 13 个 parser 漏定义与真实实例重建验收；旧版本空间回收另议；全量回归留待合入门禁。

### 2026-10-14 — 防止 csearch 在输入或覆盖不可判定时静默跳过

**Task**
X2：A3、C01、C02、C03。

**Implemented**
- 为 fd 清单增加遵循实际 Git ignore 大小写语义的 tracked 补全函数，保留范围/目录排除；`ue.lua` 接线补丁待 X1 合入。
- 主索引缺失/损坏时 Smart reset；原生 watcher loss 持久记账并复用 Git/reset 补偿；Git capture 失败明确 unavailable，不再成功 skip。
- 保留 W1 的覆盖 HEAD、增量内容自检和原单写者保护。

**Pitfalls / Gotchas**
- 清单快照/观察 HEAD 不能证明主索引可用或完整内容覆盖。
- 连续 overflow 的 source refresh 可以合并，持久 loss 证据不能因此丢失。

**Validation**
- `search_` 135/135、`file_inventory` 24/24、最后 X2 原生正向补测 7/7、`stability` 26/26、`host_resource_discipline` 13/13、`multi_instance_state` 28/28，均 0 skip；独立 csearch/ue_watch filter 结果见上表。
- 真引擎 12 文件从 0/12→12/12；私有新 token/WorldPartition 查询均命中；8 文件 AST lint、diff whitespace 和补丁可应用检查通过。未跑全量/Go。

**Follow-ups**
- X1 合入两处零行数增长接线；后续授权时验证真实清单/旧索引恢复与全工程性能。

按用户要求，仅在此给出草稿，未写 `docs/changelog.md`：

### 2026-10-14 — 保留导航失败证据与断点、恢复存储的失败意图

**Task**

修复 review-gd X3 的 B1–B4、C08/C09/C11，并统一 27 个导航 reason 的提示。

**Implemented**

- `reading.lua` 记录每次引用请求及 provider/GTAGS 终态；`lsp_transport.lua`、`semantic_navigation.lua` 正确保留与分类编译准备失败；`clangd_referent.lua`、`semantic_report.lua` 用编译器证据解释空身份，展示脱敏的各 client/目标证明错误与构建选择。
- `_persist_bp.lua` 保存失败不消费清空意图，恢复失败逐项保留并让已成功设置的 live 断点优先；`edit_recovery.lua` 区分读取失败、部分结果与首次 ENOENT 空库。

**Pitfalls / Gotchas**

- 空 USR/AST=null 不能证明宏消参或 inactive；准备失败不能归为 identity-missing。
- 部分恢复后的保存不能丢失失败项，也不能让旧 pending 覆盖用户已成功设置的同行断点。
- ENOENT 只比较错误码，不能在包含路径的整条错误中搜索子串。

**Validation**

指定窄回归全部通过、无 skip：ue_goto_behavior 105、reading 58、relations 18、cpp_semantic_ 150（RequireNative）、新增 X3 12、断点失败 9、恢复读取 7、既有 ide_recovery 17 / dap_spec 115 / dap_failure_layer 100 / multi_instance_state 28 / utils 49 / ue_platform_boundary 20；13 文件语法/AST/bare-global lint 通过，修前/修后重放通过。重叠 filter 不重复累计。未跑全量。

**Follow-ups**

保留缺少 subject 的用户现场与真实设备/掉电耐久性的验证缺口；不将私有 fixture 通过表述为真实工程导航或全工程索引性能已恢复。

### 2026-10-14 — CDB 必需输入和提交后交付如实报告失败

- **Task**：X4 C04/C05/C06/C07/C10/C12；阻止部分 CDB/工具链成功被报为完整成功。
- **Implemented**：`lua/ue/cdb/shards.lua` 检查原子发布并对 declared shard 读错 fail closed；`tools/cdb_transaction.py` 核对 raw shard 声明条数；`tools/expand_response_cdb.py` 完整展开 command/arguments 的必需 RSP；`lua/ue/cdb/pipeline.lua` 检查必需 stage/receipt helper、只统计真实 unlink 成功；`lua/ue/cdb/transaction.lua` 区分 committed/refresh-requested/refresh-failed，失败交原 index owner 恢复。
- **Pitfalls**：pcall 成功不等于 libuv 操作成功；最终压缩 CDB 条数不能当 raw shard 条数；refresh 调用成功不是实际 attachment；失败恢复不得提前确认 prepare 成功。
- **Validation**：新增 42 项通过；15 个相关窄 filter 共 365 PASS / 0 FAIL / 1 真实宿主 SKIP；Python CLI 夹具、Lua 8/8 语法、Python 2/2 AST、7 collector 哈希不变、diff/待合入补丁 check 通过。未跑全量及真实工程性能验收。
- **Follow-ups**：合入本报告 `lua/ue.lua` 零净增行接线补丁后，验证 producer/swap 错误终止；再由对应 owner 做真实实例交付验证。

- 统一合入：X2 清单补全接线（x1-inventory.patch）与 X4 CDB facade 失败传播（ue-lua-required.patch）已应用到 lua/ue.lua（9718 行，未增加）；X1 GTAGS 方向说明已追加到 openspec/specs/multi-instance-state-isolation/spec.md。
- 独立复跑（RequireNative）：gtags 22（1 SKIP=私有 native proof 需显式环境变量）、ue_goto_compat 14、ue_api 66、file_inventory 24、csearch_ 91、search_ 136、ue_goto_behavior 105、ue_goto_reading 58、cpp_semantic_client 70、dap_persist 9、edit_recovery 7、ide_recovery 17、ue_cdb 207（1 SKIP=宿主能力守卫）、index_delivery 96、index_batch 260、commands 167、stability 26、host_resource_discipline 13、smoke 19，0 FAIL。

### 2026-10-13 — 证明 Test 消参宏中的 gd 缺少语义身份

**Task**
调查 VulkanMemory.cpp:5213 的 FFence/EState/NotReady `identity-missing`。

**Implemented**
- 独立受限 clangd 对照同根 CDB inferred/exact command，通过实际 hover、AST 和相邻 USR 确认 check 参数被消去。
- `tests/cases/ue_goto_behavior_referent_spec.lua` 增加两个真实 clangd 负向用例，保证消参位置不伪造身份或跳转。
- 保留运行时严格语义失败及原有 CDB、压缩/覆盖行为。

**Pitfalls / Gotchas**
- synthetic 根 CDB 不直接列 source 不足以证明错误命令；必须用 exact 对照验证。
- 同行多个标识都没有 identity 不等于整个文件 AST 坏；本例 compiler 展开明确为 `{ ; }`。

**Validation**
- `NVIM_TEST_REQUIRE_NATIVE=1`：cpp_semantic_ 150/150、ue_goto_behavior 103/103、ue_goto_reading 58/58；零失败、零跳过。
- 两轮原 CDB 字节签名未变，独立 source 0 error，Job 守卫没有内存上限事件；diff whitespace 检查通过。

**Follow-ups**
- 用户旧实例不可达；未完成现场内存状态核验。
- 当前 Test 消去参数的位置仍不能提供编译器身份；如改进提示，应继续明确这项语义边界。
- 独立复跑（RequireNative）：ue_goto_behavior 103、cpp_semantic_client 70 全绿（cpp_semantic_ 150、ue_goto_reading 58 为 Codex 结果）。
- 说明：这是**测试构建的真实语义**（DO_CHECK=0 → check 展开为 `{ ; }`），不是 adapter 缺陷；测试构建下该位置无 canonical identity，未放宽语义规则、未改引擎/CDB。

### 2026-10-13 — 防止 csearch 普通提交漏更新并核对增量内容

**Task**
修复文件清单不变、watcher 漏记时的新提交长期不可搜，并拒绝原生增量部分成功。

**Implemented**
- 普通 Smart 构建在 skip 前核对完整覆盖 HEAD；缺有效 Git 基线保守 bootstrap。
- Go 增量在 Merge 前验证要求更新的 staged names，输入错误不得发布部分成功。
- 增量异步抽查完整小文本文件的长标识符；明确不命中时原锁与宿主准入内最多 reset 一次，记录探针，修复清单用于最终快照。
- 同步 ue-code-search spec；保留删除和前缀遮蔽闭包。

**Pitfalls / Gotchas**
- observed HEAD、名字清单、格式头和通用词命中均不证明内容覆盖。
- 文件读取/查询错误不得冒充内容不一致；部分清单不得用于 reset；正常文本过滤不得触发重建循环。

**Validation**
- 14 个窄 filter 554/554，0 失败、0 跳过；Go 10/10，go vet 与目标 diff 检查通过。未跑全量。
- 原生 stale-trigram fixture、自检一次修复、租约保持、失败不二次 reset、同 stat 内容替换及前缀/删除回归通过。

**Follow-ups**
- 更新已安装 Go 工具并采用新 Lua 代码；用户真实索引按需通过既有 UEBuildCsearch 恢复。本轮未执行。
- 全工程耗时及大文件内容一致性不在本轮验证范围，历史漏写时刻未唯一还原。
- 独立复跑（RequireNative）：csearch_build_guard 29、search_ 129、host_resource_discipline 13、stability 26；tools/cindex-uefilter `go test` OK。

### 2026-10-13 — 冻结批次快照补齐父目录相对 include 的编译器目录证据

- Fixed：冻结批次补齐普通父目录include的编译器目录证据，并验证实际mixed lookup的多级父路径，保留封闭快照与同名头消歧。
- Validation：上述8个required-native窄filter全绿、FAIL/SKIP均0；新增相对路径正反例；Renderer-g1真实proof为拒绝：`admission-rejected: references-removed-or-retargeted`；4/6 GiB Job、IDLE、串行守卫无超限。collector改变会使13旧组失配，完整旧源码已归档，严格迁移/真实性能恢复未验收。
- 独立复跑（RequireNative）：index_vfs_aliases 6、index_verified_batch 27、index_unity_receipt 14 全绿。
- **C11 待处置**：collector 身份 31573be0… → 0d1ecb39…，已发布 13 个 Batch 将失配并回退原 UBT（R1b 实测这 13 组无可测收益）；严格 migration 未执行，需用户确认是否对真实 store 运行。

### 2026-10-13 — 保护同步跳转回调的新选择并减少被动布局开销

**Task**

修复 N1 scan 的 split/tab/load/buffer/native jump 交接错误，统一阶段复验，去掉旧 review selector，并缩短 root readiness 空等。

**Implemented**

- layout_handoff 集中短生命周期同步观察与 win/tab/buf/role/owner 复验；迁移 reading、build/logcat/Yazi、loclist、review/jumper、picker 与 layout 创建/focus。
- confirm 留 facade；旧 selector 删除；被动 discover 限单 tab；root/start/LspAttach 立即复检，50ms 保留安全网。

**Pitfalls / Gotchas**

- 区分原生 autocmd 临时窗与真实用户选择；WinNew 允许创建阶段继承 buffer，完成后仍绑定目标。
- 新 normal tab 清理继承的 diff/pin 选项；同时冻结 tab owner 与窗口 registry owner，拒绝新建窗被回调接管。

**Validation**

- 指定 13 filters 全绿（layout 158、review_goto 30、git_review 77、ue_goto_behavior 101、ue_goto_reading 58、ide_problem_navigation 27、keymaps 85、terminal_layout 27、ue_goto_layout 22、keymaps_file_reference_layout 9、android_ide 45、stability 26、smoke 19），全部 native-required / 0 FAIL / 0 SKIP。
- 另四个 ue_goto 本地规则 filters 全绿；原 scan 9 次运行通过，syntax 17/17、production AST lint 9/9 与 scoped diff check 通过。
- 同 headless 探针：60 tabs native switch median 41.5785→0.2469ms；10ms root delay 组就绪后额外等待 46.6784→0.1218ms。详细限定与原始数据见 result-n1。

**Follow-ups**

- 用户 GUI、真实 UE/索引性能与既有历史失败探针未验证；本轮仅交付 N1 范围，不替其它并行任务报完成。

### 2026-10-13 — DAP 底栏归还失败不再阻断结束清理

**Task**

- 修复 pinned borrowed host 归还 E1513、UI 恢复异常阻断 session-end 清理及历史 debug group 保留重 token。

**Implemented**

- borrowed set-buffer 边界临时解 pin，finally 恢复原 pin 并保留原异常。
- per-owner UI 归还失败继续其它 owner；session-end 明确报告 UI 原因，并继续现有平台 cleanup/end_session/reset。
- dap owner 原地退休关闭/结束 group 的重 token，保留 ID、轻量 metadata 与失效理由；活跃会话可用新 invocation 重开 UI。

**Pitfalls / Gotchas**

- 先恢复 pin、再 set-buffer 会让 review 自动固定的 bottom host 抛 E1513；异常不能截断结束清理。
- 清空 owner 本地 invocation 表不等于历史 group 释放 token；需要在实际登记 record 上退休。
- 日志通知经 schedule，测试需等待通知事件；关闭 UI 仍保留活跃业务会话，不等于结束调试。

**Validation**

- dap299/299、dap_failure_layer100/100、platform93/93、ue_platform_boundary20/20、android_ide45/45、workarounds48/48、smoke19/19；0fail/skip，按任务未跑全量。
- 新增16场景原生UI回归全绿；原四模式前后复验，历史 token8→0；三文件ASTlint与两生产文件diff check通过。
- 只在独立headless进程和自有fixture验证，未操作用户实例/UE/设备。

**Follow-ups**

- 真实 GUI/现有会话、adapter/设备 cleanup 与长期资源变化留待现场验证；不以 fixture 或 weakref 数据宣称该部分已完成。

### 2026-10-13 — Prepared文件清单可靠收尾并补布局来源提示

**Task**

- 修复prepared-list取消时fd泄漏与读错误报完整；补review/debug进入编辑tab后的来源、返回方式和列表辨识。

**Implemented**

- find_list登记Async abort清理，幂等close，callback/yield异常close后保留错误语义；fs_read error与EOF分开，保留完整前缀与失败原因。
- layout只读getter读取已有Back/source；layout_notice在UI事件后更新缓存并给一次来源/返回提示，CodeDiffClose在owner清理后刷新。statusline仅读缓存。
- UELayout显示已有base→target与选中文件；UEView code空review提示wN/wR；两份帮助说明Ctrl-O不跨tab返回、wC仅聚焦已有code。

**Pitfalls / Gotchas**

- Async abort会中断finder尾部，正常末尾close不能覆盖取消；nil/EIO不能等同正常EOF。
- Close事件早于owner cleanup，缓存刷新也须排在记录退休后；状态栏重绘不能调用layout discovery。
- 审阅两侧为aux是正确隔离，空code应解释下一步，不把paired pane改为可覆盖code。

**Validation**

- file_inventory20/20、search_115/115、layout154/154、keymaps85/85、commands167/167、cheatsheet223/223、review_editor9/9、smoke19/19，0FAIL/0SKIP，按任务未跑全量。
- 原取消探针5次open后0个活fd泄漏；EIO明确error/complete=false；真实CodeDiff UI小夹具证明来源提示、Back及四个修订文本检查。50次renderer无来源getter调用；独立关闭刷新复现修后PASS。
- 9文件AST lint、4文件StyLua、tracked diff检查通过。所有验证使用自有进程/夹具，不操作用户实例或真实工程。

**Follow-ups**

- 后续现场验证用户GUI宽度、旧进程重新加载及长期切换；提交/合并前仍需全量门禁。历史真实UE/索引probe和性能验收保持独立。

### 2026-10-13 — 保留索引资格并补齐批次观测、切分支交付与 TEMP 证据

**Task**
- N4：解释 13:57 后 collection 停滞，补安全恢复接缝与显式切分支入口，盘点真实 TEMP，保持只读现场边界。

**Implemented**
- 持久记录 proof/collect/最后成功 collect/pending/owner；旧 result 仅作发现提示，原 leases 下重新 receipt 校验后恢复收集。
- 新增 UEIndexSwitchReindex，generation baseline、uncovered prepare、一次 start/final 通知与 reader acknowledgement；注册在 ue 子模块，ue.lua 行数不增。
- 新增 UEIndexBatchWorkInventory，只读传递引用/活性分类与路径清单；无删除实现。更新 Markdown 命令说明与 cpp index 方向级选型/踩坑。

**Pitfalls / Gotchas**
- 14:02 已触发 collect；不能将停滞归咎于最后 references 拒绝。历史直接中断原因仍缺日志。
- 历史 ok、PID 活性、TEMP 年龄均不授予资格；未知项保守。prepare 完成必须等待实际 reader attachment，重试保留原 delay。

**Validation**
- index_batch 260/260、index_verified_batch 27/27、index_switch_reindex 28/28（1 真低 commit skip）、index_switch_reindex_python 8/8、index_generation 46/46、commands 167/167、cheatsheet 223/223、host_resource_discipline 13/13、stability 26/26，均 0 fail；追加 source/observer/structure 与 AST/whitespace 检查通过。
- TEMP dry-run 17,988,440,967 逻辑字节/133,766 文件，61.348608s，0 错误；引用 17,980,269,608 字节，unknown 8,171,359，可证明可回收 0。未跑全量或真实 UE 发布/性能测试。

**Follow-ups**
- 补历史进程/collect 证据，在授权现场验证恢复发布与 C11 性能；补未知 TEMP 原 store 元数据；真实同大小/时间戳内容变更与低资源门禁缺口继续保留。

- 独立复跑（RequireNative）：layout 158、review_goto 30、git_review 77、ue_goto_behavior 101、ue_goto_reading 58、ide_problem_navigation 27、keymaps 85、terminal_layout 27、dap 299、file_inventory 20、search_ 115、commands 167、cheatsheet 223、index_batch 260、index_switch_reindex 28、index_verified_batch 27、stability 26、smoke 19、workarounds 48、android_ide 45 全绿。

### 2026-10-12 — 审阅定义跳转主动附加 clangd，外部导航切到 normal 布局

**Task**

修复修订窗 gd 的 clangd 启动/附加缺口，并按用户要求将 review/debug 外部浏览整屏切到编辑布局。

**Implemented**

- 复用正常 clangd 配置，校验 root/initialized/alive/attached；超时反馈等待耗时与 client 状态，语义请求仅发送到真实附加文档。
- layout.resolve/confirm 统一 normal group 创建/复用、源位置 Back 与变化取消；各入口保留原 owner/history。DAP stopped/frame 显式留在 debug。
- 释放关闭审阅的 session token，保留布局元数据与失效提示；迁移原 browser 用例，并同步 git-review-workspace 方向 spec。

**Pitfalls / Gotchas**

- 隐藏 loaded buffer 再次 bufload 不保证触发 FileType；CodeDiffClose 早于 session 清理，且按需 Git 初始化不经过 layout 命令 setup。
- Ctrl-O 原生回溯文档位置而不跨 tab 返回原 UI；跨 tab 布局返回使用 UELayoutBack。loclist/cwd 查询需显式考虑非活动 tab。

**Validation**

- 指定 9 个窄 filter 826/826，0 fail/skip；相关补充窄回归全绿；21 文件 AST lint、范围 diff check 通过。
- 真实两 commit CodeDiff range + LLVM clangd：冷启动、hidden loaded、wrong-root、exit=1 后恢复、清晰超时；请求均指向真实 attached main.cpp，成功到另一文件定义，原两侧与 Back 保全。

**Follow-ups**

- 旧用户实例尚未加载本轮改动；真实 UE PPI_SceneDepth 完整链及索引性能待独立验证。本轮未操作旧进程或缓存，不作该部分已修复声明。

**Validation**
- Codex 窄回归 826/826（RequireNative）；独立复跑 review_goto 31、layout 117、git_review 77、ue_goto_behavior 101、ue_goto_reading 58、ide_problem_navigation 26、keymaps 85、dap 283、workarounds 48 全绿。真实 clangd 小 fixture 四种场景端到端跳到定义。

**Follow-ups**
- 真实 UE（PPI_SceneDepth）与 GUI 现场未验证；需重启 nvim。

### 2026-10-12 — 接入生产 DAP debug 布局 owner

**Task**

- 让 UELayout debug 通过真实 DAP/UI owner 聚焦、恢复布局，业务调试与任务操作保持独立。

**Implemented**

- setup_dap 注册 debug group/owner，token 复用 `_layout` invocation；会话结束和 UI 关闭给出具体失效理由。
- 显式恢复可修复缺 rail，保留用户新 split、脏 buffer 与 source；关闭后重新打开使用新 token。
- ui_only 禁止无 buffer 的 logcat reader 隐式启动；normal 候选排除当前仍由 review/debug 使用的 tab。

**Pitfalls / Gotchas**

- dap-ui 部分 rail 关闭仍判 open，reset 仅改尺寸；需要 owner 有界公共 close/open。
- debug 初始化前的旧 normal group 不能继续抢 normal 命令落点；用户重用的 rail 必须明确拒绝收回。

**Validation**

- dap 283/283、layout 107/107、keymaps 83/83、commands 165/165；0 fail/skip，未跑全量。新增真实 owner 场景 8/8 已包含其中。
- 4 文件 AST lint、范围 diff check 通过；业务及 reader 启动计数全 0，child cache/PID 日志隔离通过。

**Follow-ups**

- 补真实 GUI 与活会话的 UI 切换/恢复验证；保留单 UI owner 和原 attach/symbols/设备政策边界。
- 独立复跑：dap 283、layout 107、keymaps 83、commands 165 全绿。

### 2026-10-12 — 统一 DAP 源码窗并保护共享调试面板

**Task**

- layout 第 3 阶段：接入 native stopped 与 dap-ui 手动源码打开，复用现有 owner，保护 debug 面板与共享底栏切换。

**Implemented**

- `_layout` 同步 code/panel 并统一 resolve/focus/jump；native switchbuf 与 dap-ui select/open 接入，共用首次打开恢复采样。
- config 阶段捕获来源 tab，initialized UI/进度保持该归属；关闭 UI 保留用户新 split、脏 source 和阅读位置。
- bottom_panel 的 owner 内容交接同步释放并恢复 winfixbuf，debug/logcat/qf 不因 pin 而拒绝切换。

**Pitfalls / Gotchas**

- dap-ui 已有 target 绕过 selector；native 同 buffer/行绕过 switchbuf，需各自覆盖入口。
- 首次手动 source 打开早于 native frame bracket；初始化进度浮窗也需要来源 tab scope。
- 初轮 DAP 测试公共日志隔离遗漏如结果正文所述；最终已通过 cache/PID 隔离断言，旧公共日志影响无历史快照可补证。

**Validation**

- dap 275/275、dap_failure_layer 100/100、layout 99/99、platform 93/93、ue_platform_boundary 20/20、android_ide 45/45、ide_workspace 24/24、workarounds 48/48、smoke 19/19，全绿无 skip；structure 85/85。
- 新增 DAP 16/16 与底栏 7/7 已包含在上述 filter；8 文件 AST lint、范围 diff check 通过；未跑全量。
- 真实 UI/module + protocol fixture，无 adapter/真实设备会话；L0–L4 策略未改。

**Follow-ups**

- 补真实 GUI/adapter 协议与长时间多次切换的现场验证；保留现有单 UI owner，不扩展为多会话状态系统。

### 2026-10-12 — 审阅布局内定义、阅读、问题与工具文件跳转统一目标

**Task**

- 执行 layout 第2阶段，使配置可达文件跳转进入 code，保留 tree/双侧 diff/面板、compiler identity、native 结果归属与普通 tab 行为。

**Implemented**

- jumper/reading owner/results 与 semantic lineage 交接；qf/loclist adapter 与 Trouble public custom actions；bottom_panel review pin、first-error/Logcat/Yazi 开文件边界；Ctrl-mouse 原生 gf code 交接及其回归。
- 复用 layout resolver与原 owner；保留 hidden/dirty buffers、来源 stale 取消、显式 split/tab、Ctrl-O/I 与 tagstack。没有新依赖或插件源码补丁。

**Pitfalls / Gotchas**

- nowrite 来源的 Snacks default main 不等于 source owner；source 与 destination 必须分别处理。
- loclist native ll 绑定原 owner；不能用复制列表到 browser 或“最新 Trouble 结果”替代。
- Trouble Main.set 不足以覆盖 nowrite/pinned/foreign main；共享 host 内容 handoff 需窄释放 pin。窗口切换中的 cwd 查询须区分 source localdir 与目标 global/tab/window ownership。

**Validation**

- 13个要求窄filter与3个RequireNative语义filter最终全绿，具体数字见上表；AST lint12文件与diff-check通过。安装版Snacks/Trouble独立交接通过，没有跑全量。
- 用户活GUI、真实Yazi进程、真实UE现场与资源采样未实测，不声明历史probe或全工程性能恢复。

**Follow-ups**

- 后续按 owner 补活GUI/Yazi交接验收；DAP双链与视图管理继续由阶段3/4承担。
- 独立复跑：layout 97、keymaps 83、commands 165、cheatsheet 219、ide_problem_navigation 23、ue_goto_reading 58、ue_goto_behavior 101、ide_workspace 24、android_ide 45、workarounds 48、smoke 19、stability 26 全绿。

### 2026-10-12 — 布局与角色视图管理命令

**Task**

- 交付 layout 阶段 4：显式切换、恢复、视图聚焦与返回，保持业务 owner 和未保存内容。

**Implemented**

- `lua/utils/layout.lua` 增加实例内 group/owner 管理与安全恢复；`layout_commands.lua` 提供 UELayout/UELayoutRestore/UEView/UELayoutBack。
- keymaps 九个窗口前缀入口与两份 cheatsheet 同步，辅助命令及可搜索帮助清单有回归。
- 复用 CodeDiff panel split、bottom_panel 和现有 buffer，不引入依赖或另一套调试/任务状态；debug 注册接口交给原 owner。

**Pitfalls / Gotchas**

- CodeDiff toggle_visibility 会完整刷新；布局恢复只显示保留 split。inline 与单侧可见窗口不能按固定双 pane 判断。
- 原生 open_win 会复位 WinNew 回调焦点；本次操作的局部监听保持用户已有窗口选择，无全局回拉。
- 首轮完整 init 键位实验触发 session/记录路径，越过隔离边界；旧缓存可能副作用保留，最终验收改为隔离 lifecycle。

**Validation**

- 窄回归：layout 83/83（K 独有管理用例 23/23）、ide_workspace 24/24、ide_work_context 41/41、keymaps 82/82、commands 165/165、cheatsheet 219/219、review_editor 9/9、ide_session 6/6；均 0 FAIL/0 SKIP，范围重叠不累计。
- installed-plugin 映射审计 213 项通过；6 文件 AST lint 与定向 diff 检查通过。真实 CodeDiff 恢复刷新/文件重选计数均 0；真实测试 job 句柄存活。未跑全量，未真实 DAP/GUI 验收。

**Follow-ups**

- J 接入生产 debug group/owner 注册接口并验证真实 UI 生命周期；后续补 GUI/真实会话与最终合并门禁。
- 键位检查只用隔离最小生命周期，不能拿 health no-mutate 标志代替 state/cache/cwd/session 隔离。
- 独立复跑：layout 97、keymaps 83、commands 165、cheatsheet 219、ide_problem_navigation 23、ue_goto_reading 58、ue_goto_behavior 101、ide_workspace 24、android_ide 45、workarounds 48、smoke 19、stability 26 全绿。

### 2026-10-12 — 防止 CodeDiff 修订缓冲区进入 clangd 与 UE 文件处理

**Task**

修复冷 session 恢复/切换 CodeDiff 文件时的非 file URI 请求、foreign-buffer 告警与 changetracking nil 崩溃。

**Implemented**
- 在原生 URI 读取事件懒加载 CodeDiff reader，保留修订缓冲区 ft 空/nowrite。
- 共享文件身份判断，过滤 lazy session、UE foreign/启动/文件事件路径中的虚拟 URI。
- 在 clangd 附加及延迟初始化前拒绝非文件 buffer；LspAttach 漏入时 schedule 后安全脱离。

**Pitfalls / Gotchas**
- Neovim 0.11.5 的 LspAttach 晚于 didOpen；在事件中同步 detach 会被后续 attached_buffers 标记复写，删除时二次 reset_buf。
- CodeDiff 命令懒加载不覆盖原生 session 的 URI edit；归一化后的 codediff:/ 仍必须排除。
- callback 错误可伴随 exit 0/pcall 成功，回归必须检查 v:errmsg 与真实状态。

**Validation**
- workarounds 47/47、git_review 77/77、review_goto 27/27、layout 11/11、ue_goto_behavior 101/101；额外 ide_session 6/6、ue_project_context 15/15、ue_api 66/66、ue_platform_boundary 20/20；0 skipped。
- 真实 CodeDiff/clangd 正常入口虚拟 textDocument 流量 0、切换与删除正常；原生 session 去掉加载 event 的负对照重现 FileType cpp。
- AST lint 8 文件与 git diff --check 通过；补充 stability 25/26，范围外 batch_runtime.lua 813 行门禁失败已记录，不声称工作区全绿。

**Follow-ups**
- 用户 GUI 当前运行实例的现场验收尚未执行；batch_runtime 行数失败由其 owner 处理；任务未运行全量回归。
- 独立复跑：workarounds 47、git_review 77、review_goto 27、layout 11、ue_goto_behavior 101、ue_project_context 15、ide_session 6 全绿。

### 2026-10-12 — 状态栏 IDX? 按选中 phase 产物判断；审阅视图统一跳转目标；收窄 SuperUnity 冻结输入

**Task**
- 索引 full ready 时状态栏误报 `IDX?`；审阅 tab 外部跳转需统一落到代码窗（layout 第 1 阶段）；已证明 Batch 冻结激活被 watcher 撤权。

**Implemented**
- `lua/ue.lua` `index_output_paths`/`index_status_token`：检查 summary 选中 phase 的 `*_index` 产物，不再要求已废弃的 `<project>.idx`；CDB 字段缺失明确报 `IDX?`（ue.lua 净减 5 行）。新增 `tests/cases/ue_index_status_spec.lua`。
- `lua/utils/layout.lua`（新）：每 tab `code/panel/aux` 窗口角色注册与 `resolve/focus/confirm`；`git_review`、`review_goto`、`search_recipe`、`plugins/snacks.lua` 默认 confirm/jump/edit 接入。审阅 tab 内搜索/gd 落入单个复用的 browser split，不覆写 explorer、diff 两侧与 merge result。新增 `tests/cases/layout_spec.lua`。
- `lua/ue/index/batch_{guard,runtime,background}.lua` 与 `tools/{clangd_batch_activation,cdb_verified_batch,clangd_receipt_migration,cdb_background_batch,build_full_cdb,build_clangd_index}.py`：仅 inventory 递归订阅，工具/资产改精确文件+direct 祖先；proof/replay/migration 工作目录移到 TEMP，完成证据内容寻址封存；grouped 回调同轮注册；计划/cache/proof/collect/冻结/客户端 Batch TU 分开观测；外部 selector zero-hit 明确提示（策略不变）。

**Pitfalls / Gotchas**
- grouped watcher 错误会广播到所有回调，日志里的 `root=C:/` 只是观察订阅，不是溢出源。
- 改 collector 源码会使旧证书整体失配：U full 批次曾回到 0，需要当前版本后台重新证明（13:38 已回升到 6），安全回退不等于性能恢复。

**Validation**
- Codex：ue_index_status 29、ue_api 66 等 187 项；layout 11、git_review 75、review_goto 27、review_editor 9、search_ 115、file_inventory 13；index_batch 247、index_verified_batch 27 等唯一 464 项（含 RequireNative query_profile 8/8）。均 0 FAIL/0 SKIP。我独立复跑 ue_index_status 29、layout 11、git_review 75、review_goto 27、search_ 115、index_batch 247、index_verified_batch 27 全绿。

**Follow-ups**
- 用户 nvim 未重启，三项均未现场验证；Batch 实际被 clangd 采用及同 build 冷/热索引性能（C11）未验收；TEMP 证据回收策略未做；layout 第 2–4 阶段未做。

### 2026-10-12 — 审阅修订 gd 交接工作区；picker 跳转不落进 explorer

**Task**
- codediff range review 中修订缓冲区（`codediff://`，nowrite、无 clangd）gd 全部失败；搜索/picker 确认后代码显示在左侧 explorer 树。

**Implemented**
- `lua/utils/review_goto.lua`（新）：解析 codediff URL，用 `vim.diff` indices 把修订行映射到工作区文件，在同 tab 新开代码 split 打开真实文件，异步等 clangd attach（10 s 上限）后再走原 `M.definition()`；`lsp_fallback.lua:M.definition` 加一行前置入口。
- `lua/utils/git_review.lua:M.setup()`：CodeDiffOpen/FileSelect 时给 explorer/history 面板设 `winfixbuf`，modified（失效回落 original）窗标 `vim.w.snacks_main`；CodeDiffClose 清标记。

**Pitfalls / Gotchas**
- 修订 buffer 是 `bufhidden=wipe`，refresh 监听 BufWipeout 会 cleanup 整个会话——不能在 modified_win 里直接换 buffer，只能另开 split。
- 只给面板设 `winfixbuf` 不改变 Snacks `Main:find` 选窗：nowrite/nofile 全被 file 过滤排除后回落 `non_float`，必须显式 `snacks_main`。

**Validation**
- `review_goto` 27/27、`git_review` 75/75、`ue_goto_behavior` 101/101，均 0 FAIL/0 SKIP（敏捷模式，未跑全量）。

**Follow-ups**
- 未在用户在跑的 nvim 现场验证（需重启 nvim 生效）；面板 hide/show 后新窗口的保护要等下一次 Open/FileSelect 事件。
- 统一窗口角色/视图管理见 `.tmp/layout-research/report.md`（未实施）。

### 2026-10-12 — 切分支重索引接线、协议与发布写入边界

**Task**
- 源码刷新重启前，以两个私有 clangd worker 共享 shard 目录加速；完成真实参数协议重测与既有发布 lease 接线。

**Implemented**
- `tools/clangd_switch_reindex.py`：变化清单、include 闭包加权覆盖、LPT 分配、junction 共享、Windows Job 内存与生命周期边界、残留清理；isolated Python 导入和内联 JSON server-profile 协议已对齐。
- `lua/ue/index/switch_reindex.lua` 和 `_source.lua`：异步 helper、scope 去重、任务登记、退出终止、探针与原重启确认；下一轮事件循环取得既有 index build / active CDB writer lease，完成或异常释放后才回退重启。
- `index_switch_reindex_python_spec.lua`、`index_switch_reindex_spec.lua` 覆盖真实 junction / Job、清单与覆盖、Lua 回退和真实 lease 竞争；宿主 spawn 审计条目已加入。

**Pitfalls / Gotchas**
- phase 完成回调尚持 build lease；同步取锁会拒绝自己的 helper，因此只延后 helper 启动，不向 `_build.lua` 或 `batch_runtime.lua` 增加逻辑。
- prepare 的 header shard migration 使用 active CDB writer lease，普通和 batch 发布使用 index build lease；冻结 seed 的目标是独立 verified 缓存、原缓存只读。存量 clangd 的原子 shard 写入不纳入发布 lease，也不操作用户进程。
- 前两次真实 argv 重测因可用提交内存低于 6 GiB 被安全中止；同参数、同扰动库的第三次重测成功，worker 峰值与中止轮基本相同，并发采样最低可用提交 12.26 GiB。守卫读的是**全机**可用提交，会因宿主其他负载中止（job 自身已有 16 GiB 上限）；守卫未放宽，中止耗时不计为收益。

**Validation**
- required-native：`index_switch_reindex` 16/16、`host_resource_discipline` 13/13、`index_source_refresh` 15/15、`index_delivery` 96/96、`ue_watch_csearch` 22/22、`stability` 26/26，均 0 失败、0 跳过。
- 两次私有重测：changed=1176、cover=136（68/68）；76.032 s / 26.651 s，worker failed=1/1，reason=`available-commit-below-6-gib`；第一轮峰值 6,443,573,248 / 6,643,523,584 bytes，第二轮 5,838,798,848 / 6,137,344,000 bytes。
- 第三次私有重测（真实 Lua argv，`python -B -I` + 内联 JSON profile）成功：changed=1176、cover=136（68/68），工具 76.371 s / 墙钟 77.0 s，failed=0/0，峰值 6,488,072,192 / 6,581,518,336 bytes，期间最低可用提交 12.26 GiB；`srcs-manifest.json` 已刷新。
- 全量 1308 条 CDB 重启（上一轮主代理实测，同一私有库）：28.1 s、reindexed_tus=0、failed=0、compile failure 0、shard 33228；本轮成功 reindex 后未再单独复跑该重启。
- required-native 全量 `nvim --headless -l tests/run.lua`：3443/3443，0 失败、0 跳过，977.385 s，exit=0，30 分钟预算内完成；Lua AST lint 2 文件 OK，Python AST OK，diff whitespace check 通过。spec 已记录 writer lease 与不同 shard 目标的选型边界。

**Follow-ups**
- 内存守卫改为以 job 自身占用为主、全机可用提交为辅的判据（待定，需单独评审）。
- `batch_shard_seed.lua` 以原 CDB 的 `.cache/clangd/index` 为只读 source、不持 writer lease：已核对无需接锁——switch helper 只经 clangd worker 写 shard（`llvm::writeToOutput` 临时文件 + rename），seed 的 `_shards` 排除 `.temp-stream-` 名，硬链接指向 rename 前的完整 inode，不会读到半写 shard；升级 clangd 时须随 seed 前提一并复核。
- 成功 reindex 后复跑全量 CDB 零重索引；真实编辑器内切分支验收；本轮不宣称全工程索引性能恢复。

已将具名调查切片归档至 [2.7.0](release_2.7.0.md)。

### 2026-10-10 — 文本恢复列表回调不再落在 fast event

**Task**
- 启动时报 `E5560: nvim_exec2 must not be called in a fast event context`（`edit_recovery.lua` 启动摘要里的 `redrawstatus`）。

**Implemented**
- `edit_recovery.list` 的最终回调改走 `vim.schedule`：最后一条记录走的是 `uv.fs_stat` 回调分支时，`done` 原本直接在 libuv fast event 中执行。

**Pitfalls / Gotchas**
- 只有“最后一条记录命中当前工程”时才走到 fast 分支，所以时有时无；lazy.nvim 检查更新时的 `vim.wait` 只是让它暴露出来，不是原因。

**Validation**
- 测试先红后绿：`ide_recovery` 的 `records()` 断言回调不在 fast event，修复前 7/17、修复后 17/17；`ide_refactor` 30/30、`ide_continuity` 2/2、`ide_session` 6/6、`commands` 161/161。

### 2026-10-10 — 文件 picker 恢复读 prepare 清单；fd 回退只扫 prepare 范围

**Task**
- `<leader><space>` 在真实工程列出三百多万文件：`429405b` 把清单式 picker 换成对整个 `project_root` 的 fd 扫描（含 SoundBanks/Content）。

**Implemented**
- `utils/file_inventory.find_list`：流式读取 `:UEPrepare` 写出的 `workspace_all.files` / `workspace.files`（相对路径按 workspace root 解析），不启动目录遍历；`cached_files` 有清单就用清单。
- 无清单时 fd 回退与 grep 回退的 `picker_search_dirs` 只用引擎 picker 目录 + `project_index_dirs`（经 `scan_roots.converge` 去掉嵌套目录，避免 rg 重复命中），不再加整个 `project_root`。

**Pitfalls / Gotchas**
- `project_index_dirs` 可能同时含祖先与子目录；不收敛会让 grep 同一文件报两次（`search_interaction` 4→8）。
- 实例中 `project_index_dirs` 本身过宽（`.uproject` 位于 `Source/Client` 时带入 SoundBanks 与约 100 个 Templates 目录），未在本条修复。

**Validation**
- `file_inventory` 13/13、`search_` 115/115、`grep_cache` 36/36、`multi_instance_state` 28/28、`ue_platform_boundary` 20/20、`ue_api` 66/66、`commands` 161/161、`smoke` 19/19、`stability` 26/26、`ide_hub` 34/34；全量 `tests/run.lua` 3427/3427 通过。

### 2026-10-10 — prepare 主循环热点移入 worker；发布 generation 修复；快速路径有序屏障与只读工具身份复核

**Task**
- 定位并移除 prepare 期间约 4.3 s 父端同步 CPU；修复后台发布反复 `publication generation changed`；修复快速路径“固定等 100 ms”的正确性缺陷，并让默认安装（Program Files 只读工具链）下的快速路径继续可用。

**Implemented**
- `ue.lua` 的 `project_index_dirs` 目录遍历（采样实测 5.68 s）移入新 `ue/cdb/prepare_scan_roots.lua` worker：同步调用 5680 → 0.03 ms（缓存），worker 3.79 s 但父端 CPU 仅 +78 ms；seed prepare 主循环最大卡顿 5871 → 463 ms。
- `batch_publish_worker` 显式同步计算 generation，不再在 worker 中走编辑器异步摘要路径拿到 pending 空值；真不一致仍报错。真实队列 319 s 完成 2 组、接受 1 组、发布 1 批。
- 新 `utils/platform/input_watch_barrier.lua` + `watch_barrier_marker.lua`：可写监听根写隐藏 marker，等待 write/metadata 两路事件都回到才判断复用；超时、错误、marker 删不掉一律走完整路径。修复 libuv 缓存时钟导致定时器提前到期。
- 只读工具根（原生 CreateFileW access-denied/write-protect 分类）不写 marker，改为复核实际使用的工具身份（路径、类型、大小、mtime、ctime、inode、dev、realpath），libuv 异步、最多 8 并发；只绑定 argv 编译器、clangd/clang/libclang、resource include、gcc-toolchain/sysroot 子树，不遍历整个安装树。argv 编译器的隐式资源目录（`lib/clang`、`lib64/clang`）一并绑定；非标准布局在 inventory 子进程中调用 `-print-resource-dir`（3 s 超时），推导不出则关闭复用。

**Pitfalls / Gotchas**
- 只看子代理报告就推进出过两次漏洞：W 的十连跑用了可写工具链副本，默认安装下 10 条失败；Y 只跑窄 filter，漏掉其缩窄身份集合导致隐式 builtin 头未绑定（3 条红灯）。验收必须在默认安装下由 Claude 自跑 `ue_cdb` 与全量。
- X 的整树身份复核使命中耗时贴着 1 s 断言（982/985 ms），负载下飘忽失败；不是正确性问题，按提速修复而非放宽断言（断言最终收紧到 300 ms）。
- 新增的 `-print-resource-dir` spawn 需要在 `host_resource_discipline` spawn 审计中登记（subprocess-only）。

**Validation**
- 默认安装（Clang 22.1.5，未覆盖工具链）`ue_cdb` 由 Claude 连跑 3 次均 165/165；子代理侧 15 次命中 103–156 ms（屏障 6–17 ms），只读复核 325 项身份。
- 全量回归（spawn 审计登记后复跑）3426/3426，0 失败、0 跳过；首轮 3425/3426 唯一失败为 `-print-resource-dir` spawn 未登记，登记后 `host_resource_discipline` 13/13。

**Follow-ups（未达标）**
- 只读工具复核仍是资源 include 整子树（约 301 文件），不是精确依赖闭包；真实大 CDB 冷收集开销未测。
- 只读工具根有任何事件即撤销复用，无关文件变化也会走完整路径。
- 多 Neovim 实例的 marker 会互相触发一次完整路径；写句柄未关时的判断不在已证明范围。
- 真实 Android/Test 工程上未重新测量无变化 prepare 耗时与整工程索引性能；SuperUnity 后台证明吞吐（约 6 h 铺满 304 候选）未改善。

### 2026-10-09 — 大型 CDB 摘要与语义发布移出主循环；旧证明回执安全迁移

**Task**
- 消除启动/发布时主循环的同步大文件计算；让旧格式的 SuperUnity 证明回执在可重新证明时复用，并验收后台证明真实耗时。

**Implemented**
- `index/_generation_digest` + 新 `generation_digest_worker`：超过 1 MiB 的冷 CDB 摘要在独立 nvim worker 读取/解码/规范化/hash，父端只收小结果；缓存绑定 size/mtime/ctime/dev/ino，计算期间输入被替换即作废重算，连续变化 3 次明确失败。generation 区分 pending 与 failed，pending 不报 ready、不透传旧 generation。
- 新 `_publication_async` + `publication_worker`：普通 phase manifest 与语义发布的读写/hash/合并在 worker 执行，主循环持有 job 与 writer lease 至回调完成；worker 失败显式报错，不同步回退。
- 新 `tools/clangd_receipt_migration.py`：旧回执仅当 collector/helper 源码身份、编译器真实路径/版本/字节/query 输出、输入/依赖/快照/图 SHA 均能重新证明一致时才升级复用，否则保持失效。

**Pitfalls / Gotchas**
- Windows dev/ino 经 JSON 传输需转字符串，否则丢精度。
- 覆盖统计必须用生产者的 portable member 函数；按 cwd/engine 拼路径或大小写折叠都会给出错误覆盖数（已作废留底）。

**Validation**
- 真实 Android/Test：主循环冷摘要 span 2363 ms → 371 ms（CPU 2359 → 31 ms），父端不再读写 291 MB CDB；启动最大 gap 4080 → 2378 ms。14317/14317 C/C++ 源成员覆盖、缺失 0。
- 旧回执迁移恢复 1 批（另 6 批缺旧 collector 源码档案，保持失效）。
- 全量回归 3360/3360，0 失败、0 跳过；前后工作树哈希一致。

**Follow-ups（未达标）**
- 卡顿目标 <200 ms 未达成：prepare 期间 max gap 4310 ms（父端 CPU 约 4.3 s 同步计算，热点未定位）；启动仍有约 1.9 s 未归因。
- 后台发布反复 `publication generation changed`，队列卡在 collecting；frozen activation `watch-error`（原安全回退仍生效）。
- 固定组 [29,30] 整组证明 127.5 s，比上轮 109 s 慢 17%（图解码 26.3 → 10.7 s，原 TU 索引 35.7 → 58.1 s；缓存与负载未控制，不是有效 A/B）。

### 2026-10-09 — 无变化 prepare 0.2 s；后台证明阶段计时与图处理缓存

**Task**
- 让输入不变的 prepare 在真实工程上真正走快速路径；拆解后台 SuperUnity 证明约 70 s 的未分阶段耗时。

**Implemented**
- `cdb/prepare_inputs`：支持 `--gcc-toolchain=`、`-gcc-toolchain=`、`--gcc-install-dir=` 及分离式写法，外部工具链目录纳入原生递归监听与根身份核验；重复路径解析进程内去重；owned 的 `engine/.cache/nvim-ue` 从递归订阅拆出，父目录非递归监听新增/替换。
- `cdb/prepare_cache`：修正 Python cache 过滤漏掉 `__pycache__` 目录本身；真实工具 `.py` 修改仍立即撤权。
- 后台证明：各阶段计时（失败路径也保留）；单次原 TU 收集内 64 MiB header shard 缓存，SHA 命中后仍比较完整字节，含 main Cmd/MainFile 的 shard 不缓存；最终回执复用已保存图的 SHA，不再重复全图 JSON/hash。
- 原生 query-profile 回执的环境身份改为编译器真实路径、版本、字节与 query 输出；PATH/PATHEXT 只作启动上下文。

**Pitfalls / Gotchas**
- 70 s 残差主要是图解码/处理（原 TU 侧约 17 s、候选约 9 s），不是 freeze/hash（freeze 合计 1.2 s）。
- 新启动 3.77 s 主循环卡顿：冷 `normalized_cdb_digest` 同步读 291 MB CDB 并 hash 260 MB JSON，占 2.27 s CPU。
- 未分类的 `nvim_ue_members` union（16626）含 shader/别名，不能当 C/C++ 源数。

**Validation**
- 真实 Android/Test：seed 169 s 后两次无变化 prepare **0.273 s / 0.222 s**，走快速路径，产物 SHA/size/mtime 不变，clangd PID 不变；改源注释后监听 epoch 0→4、进入完整生成（完整生成在限时内未完成）；源文件按字节与 mtime 恢复。
- 离线真实产物：图处理 13.930 → 9.556 s（−31%），三张规范化图 SHA 全等；锁内整组证明 109 s，尚未测到整体提速（header 缓存在该次实测后加入）。
- 全量回归 3336/3336，0 失败、0 跳过；前后工作树哈希一致。

**Follow-ups**
- 冷 generation 摘要与普通发布改为异步，消除 3.77 s 卡顿。
- header 缓存后的整组证明真实收益与 304 候选吞吐推算；旧 collector/helper 回执安全迁移。
- 改注释后完整 prepare 的耗时与发布结果未取得。

### 2026-10-09 — 后台 SuperUnity 证明、prepare 输入缓存骨架与头文件 clangd 目标校验

**Task**
- 用户约束：Windows 文件系统是索引瓶颈，任何方案都不得依赖等 clangd 后台索引全部完成。本轮把二次合并证明挪出 prepare，并为无变化 prepare 与头文件跳转打基础。

**Implemented**
- 后台 SuperUnity 证明：正常 full 只复用缓存回执，交付后启动后台队列；最多 2 个私有 clangd（-j=1、IDLE 优先级、宿主准入），120 s 攒批后排空再增量发布；大 CDB 合并/hash 放到独立 `batch_publish_worker`，编辑器只接小结果并走原冻结激活流程。新增 `index/_batch_background`、`batch_background`、`batch_publish_worker`、`tools/cdb_background_batch.py`。
- prepare 输入证据缓存：`cdb/prepare_cache` + `prepare_inputs`，在 writer lease 内用 Windows 原生 watcher epoch 与产物身份判断输入未变时跳过 raw/pipeline/partition/commit/current/hot/full；未知参数、未知 VFS、监听溢出/停止、产物缺失或损坏、工具源码变化一律回退完整路径。
- 头文件 clangd 兜底：跳转前校验目标 exact-command AST 的 canonical USR、definitionRange/body 与 changedtick；删除无定义体时悄悄回跳声明的成功路径。

**Pitfalls / Gotchas**
- clangd 冷启动读入 33,026 个 shard 约 9.7 s、内存重建约 9 s，约 19.5 s 才能回答头文件定义；不必等 background end，但首次 <3 s 不可达，瓶颈即 shard 数量。
- 并发 clangd+sidecar 原型被真实反例否决（只校验目标位置不足），已撤回。
- 旧证明回执因 compiler PATH 不同全部失效，门禁正确拒绝；需环境身份规范化。
- 跨子进程 JSON 会丢失 Windows 大整数 inode 精度；签名需带类型与长度的稳定编码。

**Validation**
- 全量回归 3329/3329，0 失败、0 跳过；回归前后工作树哈希一致。
- 真实 Android/Test 后台证明约 8.7 min：完成 7 组（接受 4、拒绝 3），发布 2 批；prepare 51 ms 返回，full 交付约 40 s；单组约 130 s（原 TU 两次约 40 s、候选约 18 s、约 70 s 未分阶段）。
- 真实头文件 gd（独立冷进程）：P01 37.9/38.7 s、E02 33.7/32.2 s 超时；P12 重复跳对 `.cpp`；无错误目标。

**Follow-ups（未完成）**
- prepare 快速路径在真实工程**未启用**：真实 argv 含 `--gcc-toolchain=` 被保守拒绝；无变化 prepare <10 s 未实测。
- 后台证明铺满 304 候选推算约 6.3 h；PATH 规范化、70 s 残差拆解、headless 心跳最大 3.7 s 卡顿待处理。
- 头文件首次/重复 gd 延迟未达标；新增 clangd 兜底分支尚无真实工程触发证据。

### 2026-10-09 — 二次合并随 prepare 逐轮增长

**Task**
- 上一版正常 prepare 交付 1 个二次批次后再也不增长；让 SuperUnity 合并能逐轮扩大。

**Implemented**
- `tools/cdb_verified_batch.py` 判断本轮验证是否完成时只看本轮新接受的批次（`new_batch_count`），已缓存批次不再阻断下一组候选；整体失效时一并归零。每轮仍最多新证明 2 组、新接受 1 批。
- 同步 `cpp-semantic-index-coverage` spec 的阶段选型说明。

**Pitfalls / Gotchas**
- 原判断用总 `batch_count`（含缓存批次），有 1 批后所有新组都被记为 `verification-stage-complete`。
- 工具源码身份变化会让旧 proof 全部失效重证明，首轮属迁移轮，不能与热缓存轮比较。

**Validation**
- 原生夹具先红后绿：第二轮 1→2 批；纯缓存轮字节/mtime/proof store 不变；零预算、同大小源码变化、构建参数变化均回退原命令。
- 真实 Android/Test：连续 prepare 1→2→3 批，改一行注释后再到 4 批；raw/原始语义 CDB SHA 与 14317 个逻辑成员不变；被引用门禁拒绝的组保留原 UBT。新接受组独立冷索引比两个原 TU 快 50–56%（仅该组，不代表全工程）。
- 全量回归 3283/3283，0 失败、0 跳过。

**Follow-ups**
- 每轮只增 1 批，铺满 304 个候选不现实，需要后台并发证明。
- 改注释那轮不能证明完整输入变化检测（每次 prepare 本就全量重验）；无变化 prepare 仍约 150 s。

### 2026-10-08 — 头文件语义导航、重复 Prepare no-op 与首个真实二次批次

**Task**
- 按真实工程基线修 P0：头文件 gd/gr 全失败、头源切换误跳、重复 Prepare 非 no-op、二次合并为 0。

**Implemented**
- 新鲜度：header gd 改为以 active selection 与 raw/merged 内容 SHA proof 判定，不再比较 manifest mtime（`cdb_transaction` 的 copy2 保留 stage mtime 导致误拒）；切换选择后旧 merged 仍在 prove 阶段被拒。
- header 编译上下文：gd/gr 从真实 donor TU 取编译命令，并由 libclang native inclusion（`clang_getInclusions` + `clang_File_isEqual`）证明包含当前头文件；VFS 别名须源码字节一致才映回用户位置。无法证明时明确失败，不借 GTAGS 变绿。
- sidecar 补齐 LLVM 22 builtin resource 目录（原注入 NDK Clang 9 资源头导致 NEON 大量编译错误）；catalog donor 发现改为请求内线性索引。
- 头源切换拒绝生成文件与未证明的 companion。
- TU 缓存 1→4（受 RSS/宿主剩余内存约束），空闲回收 30 s→300 s；进入头文件异步低优先级预热已证明 donor，前台请求可取消；CDB 解析缓存绑定内容 digest。
- 重复 Prepare：`module_keys` 规范排序、全部 provenance 一致才复用 `completed_at`、manifest 深比较相等不写盘；缓存命中不再创建 proof 目录（原触发 watcher 撤权并重启 clangd）。
- 正常 full prepare 有界证明最多 2 个未缓存候选（原路径恒 `--reuse-verified-only`，永远不生产 proof）。
- 新模块：`reading_companion/compile/context`、`semantic_prewarm`、`semantic_cdb_cache`、`semantic_context_hash`、`semantic_sidecar_inputs`、`index/_generation_digest`（含为 800 行门禁做的机械拆分）。

**Pitfalls / Gotchas**
- preserved-size/mtime 的内容 hash 复用曾出现一次 false acceptance，未复现根因；已改为每次实读 hash，并加 metadata 相同、内容替换的拒绝反例。
- 首次与缓存读回的 batch 字段顺序不同会导致等价 CDB 被重写。
- 测量驱动：启动期异步切窗会让“头文件 gd”实际落在源文件上，调用前须校验 buffer/path/cursor。

**Validation**
- 真实 Android/Test 30 样本（同 SHA）：gd 11/30→22/30、gr 11/30→22/30（header 0/19→11/19），头源切换 24/30→30/30（误跳 6→0），cpp 起点 11/11 不变。
- 重复 Prepare 缓存轮：受控产物 SHA/size/mtime 全同，clangd PID 不变，0 spawn/0 detach。
- 二次合并 0→1 批（2 个 UBT 输入；997 UBT → 995 + 1 batch，full 条目 3329→3328），exact 215、shader 2117 不变。
- 合批全量回归（含 800 行门禁拆分）：3283/3283，0 失败、0 跳过，包含 legacy。

**Follow-ups（未达标，不宣称完成）**
- **延迟未达预算**：header 首次 gd 30–41 s 或超时（P01/E02），同 donor 重复 208 ms 达标。逐请求冷解析 TU（≈8 s/个）是结构性瓶颈；下一步改为先用 clangd 后台索引按 USR 查定义，sidecar 只做歧义/缺失回退。
- 剩余 8 个 header 中 P09/E09/E15 native 校验已恢复，端到端 gd 与 P10/E10/E11/E12/E14 未实测；E02 触发 64-context 上限。
- 增量二次合并未实施：`cdb_verified_batch.py` stage-complete 用总 batch_count（含缓存批次），已有 1 批后不再接受新组。
- 缓存轮 Prepare 仍重做输入验证，墙钟约 164 s；全工程 SuperUnity 性能未恢复。

### 2026-10-08 — 用工作台贯通开发入口、恢复与首次上手

**Task**
- 产品复盘后收敛入口：多个顶层入口与六类“恢复”概念让用户先要理解差异；改为以工作台为主线，并缩短首次上手与手册阅读路径。

**Implemented**
- `development_workbench` 首屏分为当前目标 / 下一步 / 最近结果 / 运行中任务 / 恢复五区；局部键 `g` 向导、`R` 恢复、`p` 命令中枢。恢复按意图组织，直接复用原 Workspace / WorkContext / SessionRestore / Recovery owner，不复制存储或逻辑。
- 新增 `utils/ue_onboarding`：按缺项依次走工程 → 平台/配置 → 设备/包名 → Prepare（单独确认）→ UEDoctor，取消即失效后续步骤；`ue.lua` 的原选择命令接受可选 flow guard，覆盖内层迟到回调与 Prepare 延迟启动。
- `USER_GUIDE.md` 只讲“想做什么 → 按什么”（592 → 326 行），边界说明迁到 `USER_GUIDE_LIMITS.md`；同步 Markdown/浮动速查与命令中枢 Recovery 分组；保留全部旧直达键。

**Pitfalls / Gotchas**
- 外层 picker 取消挡不住平台选择器的内层迟到回调（实验观测到取消后仍 fast swap 1 次），必须在内层与 Prepare launcher 处复核 guard。
- 包名选择要绑定发起时设备；Snacks 的 Esc 只切模式，不等于关闭向导 UI。
- 合批全量首轮 3178/3180：`ide_work_context_native` 两条用例仍按旧工作台主屏断言（调查备注行、主屏「继续已保存调查」）。这是入口有意迁移造成的过期断言，不是功能回归；改为断言主屏「当前调查」行，并经恢复菜单的 `UEWorkContext` 动作继续，原有恢复/备注详情断言保留。

**Validation**
- 26 个 MAP filter 全绿；cheatsheet/structure 冻结瘦身前 57 个命令、87 个键位、29 个组合键均仍可查。
- 真实 Neovim + Snacks 按键回放：工作台 → 恢复 → 找回关闭的构建日志 7 键；空配置 → 向导 → 取消 5 键，取消后 1800 ms 无新任务。
- 合批全量（含 B/C 与本条测试修正）：3180/3180，0 失败、0 跳过，包含 legacy。

**Follow-ups**
- 真实 UE 工程完整 fresh 上手（含设备/应用选择）、极窄窗口布局、其它宿主仍未验收。

### 2026-10-08 — Android 无 Python 的 UE 调试变量显示

**Task**
- 让 FString、FName、容器与指针在真实 Android DAP 变量面板中可读。

**Implemented**
- `_android_engine` 的 formatter 命令委派给新 `_ue_formatters`：对引擎自带 LLDB formatter 做非致命 `command script import`，始终保留原生 fallback，删除按 Python 目录推断能力的旧分支。
- 新增 `_ue_values` / `_ue_array`：attach 成功后安装会话级显示层，按真实 `readMemory` 解码 FString（UTF-16、空态）、TArray 有界元素、TMap/TSet Num、NULL UObject/SharedPtr，FName 显示 index + Number；continue/step/detach 作废旧观察。

**Pitfalls / Gotchas**
- 当前 lldb-dap 22.1.6 导入 Python 报 `No module named 'lldb'`（L0 外部工具链），引擎 Python formatter 无法生效。
- 真机上 typed array cast 让 adapter 以 0xC0000409 退出，该路线已删除；内部崩溃机制待验证。
- 正的弱指针 index/serial 不等于有效；不执行目标函数，不把源码字符串冒充已解码 FName。

**Validation**
- dap 252/252、platform 66/66、dap_failure_layer 100/100、ue_platform_boundary 20/20、android_ide 45/45；新增 `dap_ue_values_spec` 15 项。
- 真机同 BuildId：5 个非空 FString、61 个数组元素、FName 索引、TSet/TMap Num、NULL 指针可读；no-kill detach 后游戏存活、TracerPid=0。

**Follow-ups**
- Python 成功分支、有效 UObject 名称、FName 名称解析、真实弱指针、复杂元素数组、GUI 展开仍待验证。

### 2026-10-08 — 真实工程体验基线（只测量）

**Task**
- 在真实 Android/Test 工程上测导航命中率、索引规模与耗时、重复 Prepare 与首次上手，按数据决定下一轮优先级。

**Implemented**
- 无生产代码改动；原始证据与可复跑驱动保存在被忽略的本地证据目录。

**Pitfalls / Gotchas**
- 测量驱动反复 `:edit` 同一文件会让 clangd 短暂脱离（1→0→约 500 ms 后 1），该批数据已作废重测。
- 非当前构建分支（`WITH_EDITOR=0`）与不在 build 内的插件样本不能计为产品缺陷。

**Validation**
- 30 样本：gd 11/30、LSP 引用 11/30、头源切换 24/30；11 个 cpp 起点全部成功，19 个头文件起点全部失败。
- 当前 build 16434 输入、1212 条发布 CDB（997 UBT Unity + 215 exact），覆盖 missing/extra 均 0；**真实二次合并 0**（304 组 verification-not-cached），不满足 C11 阶段验收。
- 后台索引：首次追赶 1612.6 s，热启动 23.4–62.2 s；重复 Prepare 120.7 s，主 CDB 未变、clangd 未重启，current/hot 产物有写入（输入是否不变待验证）。

**Follow-ups**
- P0：头文件 gd 被 `merged-cdb-predates-active-selection` 时间门禁拒绝；头文件 gr 无编译命令（`compile-command-missing`）。
- P0：恢复真实二次合并（C11）。
- P1：头源切换 6/30 跳到 `.gen.cpp` 或无关头文件；新 TU 首次 gd 等待 9–27 s。
