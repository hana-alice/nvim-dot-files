# hana-alice/nvim 2.7.0 — 保存和继续具名调查

> 版本：2.7.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-05
> 类型：Minor；把相关文件、搜索条件与下一步接成可继续的调查。
> 发布流程：本机验收后按既有授权脱敏归档、提交与推送；tag 待明确请求。

## 1. 本次交付范围

- 工作台 `<leader>uH` 的「保存当前调查」依次填写名称和下一步；「继续已保存调查」按名字找回。
- 保存当前标签页可见的普通文件及位置；单窗口阅读时可以显式追加文件。完整搜索条件属于原工程时一并关联，也可以显式从历史选入。
- 中断调查去编辑另一文件、搜索或运行任务后，继续调查只打开活动文件，其他文件按需打开；另一项工作的未保存内容和进程保留。
- 文件位置、查询意图与下一步按工程跨重启保存；原结果只在原实例且列表身份、版本及生产者仍匹配时可用。查询重跑是独立动作。
- 操作手册、速查、任务方向规格、架构导航与回归映射同步；复用已有窗口、输入、搜索与发布通知，无新依赖。

## 2. 验证与剩余范围

最终同版完整回归 **3136/3136**，0 FAIL、0 SKIP，包含 required-native 与 legacy，
耗时 **645.77 秒**。15 个候选 Lua 源码与测试在运行前后字节一致；实际 UI 的两条流程
及两条独立复验均绑定最终 14 个生产输入。25 个候选文件全文、Git 身份和实际 Lore
消息通过外置私有 denylist 与通用扫描；提交和推送保留正常隐私 hooks。

调查保存的是导航元数据，不包含未保存文本、结果正文、日志或进程。异常退出的文本仍由
`UERecovery` 管理。新实例不会复用旧的原生编号，不自动加载会话、应用历史 target、构建、
搜索或索引。每工程最多 16 个调查、每个最多 32 个关联文件；满额明确拒绝，不静默删除具名工作。
旧坐标不能证明当前语义位置有效，文件缺失、位置失效或回调选择新状态均给明确提示。

真实 UE 工程、设备与实体 GUI 验收仍独立进行；本次没有改 CDB/SuperUnity/prepare/DAP 政策，
也没有宣称全工程索引性能恢复。三条缺原 subject/build 的历史探针复发保留既有延期处置和计数。

## 3. 本次工作归档

### 2026-10-05 — 保存和继续具名调查

**Task**

中断一次调查后，能按名字找回关联文件、搜索条件与下一步；另一项工作的修改和任务保持原状。

**Implemented**
- 工作台与命令中枢接入具名调查，提供保存、继续、关联当前文件、下一步说明及完整搜索条件。
- 导航元数据按工程异步保存、锁内 CAS/merge、原子发布及回读；本实例原结果引用另行保留，不跨重启复用原生编号。
- 恢复按需打开源文件，保留另一项工作的未保存内容；查询重跑、原结果查看和删除调查均为独立明确动作。
- 操作手册、速查、任务方向规格、架构导航和回归映射同步，无新依赖。
- 修复 Windows 双实例 lease owner 读取阻止锁释放的问题；真实跨进程读者回归覆盖，PID/token 与过期回收规则保持。

**Pitfalls / Gotchas**
- 调查记录不是文本备份或完整会话；原实例结果/日志、未保存文本和历史坐标的有效性分别说明。
- 缺失 bucket 属首次使用，不能把 Lua 的 and-nil-or 当作空库分支；保存成功必须回读真实发布结果。
- 原生 buffer 路径查询可按 pattern 匹配相似名称，必须复核真实文件身份；恢复窗口时回调的新输入与光标选择优先于旧坐标。
- quickfix 原位替换可能保留构建标记；关联原结果须同时核对原生产者冻结的列表 ID 与版本。
- 冷读取回调可改写文本后清掉 modified；只看该标记会误继续旧定位。仅观察本次目标的真实文本变化，正常读取后停用自身监听，待后续事件自行清理，不拆其它监听。
- 首轮全量的唯一失败是协调器 898 行超过新 Lua 文件 800 行门禁；原生文件恢复生命周期抽到独立模块，保留原公共接口、回归与门禁，不增加豁免或压缩排版。
- 第二轮全量暴露既有双实例历史丢计数；独立原生复现确认锁文件删除 `EBUSY`、释放失败后自身活 PID 锁阻塞，最终 52 个待写项被清空。Windows stdio 持有读取句柄阻止删除，UV 读取允许删除；修复只调整 owner 读取传输，保留租约规则与原 240 次计数断言。失败瞬间具体对端句柄重叠没有直接证据，不据此推定。

**Validation**
- 原生保存层 21/21、调查核心 18/18、真实 UI 2/2；另保留两条独立 linegrid 流程，全部绑定最终 14 个生产输入与前后字节一致。
- 工作台 4/4、命令 148/148、窗口恢复 24/24、并发状态 28/28、搜索 115/115、Hub 34/34、平台边界 20/20、Android 接线 45/45、结构 78/78、速查 205/205、审阅入口 9/9、键位 64/64、稳定性 26/26 均通过。
- 新增跨进程读取句柄回归在旧实现中实际抵达释放断言并失败，修复后通过；原搜索历史双实例用例的 240 次计数和两项具名记录断言保留并通过。首次新夹具脚本写法错误导致的 barrier 失败另行留底，没有计作机制证明。
- 两轮独立审查批准最终源码；实际冷/热重复恢复、BufLeave 新输入、BufEnter 新光标、冷读取清 modified 和其它监听保留已闭环，未用假宿主替代 native 能力。
- 候选 15 个 Lua 源码/测试的 LuaJIT 与真实 Tree-sitter AST 通过；四个新模块及测试、工作台与回归的 StyLua 检查通过，共享文件仅检查改动范围。
- 实际 LuaLS：9 文件候选与 5 文件基线均 0 Error/19 Warning，新增 0，源码前后字节不变；两个 CLI exit 1 如实保留。两个治理规格的 strict validate 通过。
- `CI=true NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`：3136/3136，0 FAIL、0 SKIP，legacy 启用，exit 0；645.77 秒，15 个输入前后 SHA 一致。
- 25 个候选文件全文、Git 身份与实际 Lore 消息经外置私有 denylist 和通用扫描，两者 exit 0，扫描前后源码、身份和消息未变；提交/推送不绕过正常隐私 hooks。

**Follow-ups**
- 原结果/日志不跨重启持久化，历史目标配置不自动重放；真实 UE/设备/实体 GUI 仍独立验收。
- 三条缺原 subject/build 的历史探针复发沿用延期处置，不改计数、不宣称索引修复。

## 4. 改动文件与简化

- 调查模块：`lua/utils/work_context.lua`、`work_context_restore.lua`、`work_context_store.lua`、`work_context_ui.lua`。协调器和原生恢复生命周期拆开；保存与恢复复用既有输入、搜索、窗口和通知接口。
- 现有入口：`lua/utils/development_workbench.lua`、`ue_hub.lua`、`bottom_panel.lua`、`cheatsheet.lua`；租约修复：`lua/ue/file_lock.lua`。
- 回归：`tests/cases/ide_work_context_spec.lua`、`ide_work_context_store_spec.lua`、`ide_work_context_native_spec.lua`、`ide_workbench_spec.lua`、`commands_spec.lua`、`multi_instance_state_spec.lua`；范围映射：`tests/AGENTS.md`。
- 手册与归档：`docs/USER_GUIDE.md`、`ue_lazyvim_cheatsheet.md`、`testing-regression.md`、`changelog.md`、`release_2.7.0.md`。
- 架构与治理：`docs/architecture/overview.md`、`memory/project_overview.md`、`openspec/specs/task-management/spec.md`、`openspec/specs/multi-instance-state-isolation/spec.md`。
