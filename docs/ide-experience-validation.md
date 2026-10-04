# IDE 体验实施与验收（2026-10-03）

用户授权执行完整产品规划。基线为 `b6488d7`；按可独立验证的切片实现，
证据区分行为回归、真实外部 UI、真实 UE 工程/设备与物理 GUI。

## report-first

开始实现前读取真实 state 的 `ue_probes.json`。三条历史复发仍未闭环：
provider/complete failures 6、旧处置 3；identity-missing/complete 3、旧处置 1；
semantic-tu-unavailable/complete 3、旧处置 2。历史记录缺 subject，
继续沿用 `daily-edit-validation.md` 的待验证理由，另做当前可复现实例调查；
不修改历史证据、计数或宣称已经修复。全工程 SuperUnity 性能仍未验收。

## 实施清单

| 范围 | 状态 | 验证 |
|---|---|---|
| U1 构建焦点 | 原生 UI 已验证 | 插入模式失败保留焦点、位置和脏内容；首错跳转及一次 Ctrl-O 返回 |
| U2 调试布局 | 原生窗口已验证 | 两 tab、分屏比例、frame 前后阅读点、主动修改保留；双 listener 顺序 |
| U3 阶段结果与上下文 | 冻结选择与完成回应已验证 | 旧 owner/取消隔离、0/6/-1、结构化 attach 失败、阶段历史；非真机循环 |
| U4 工程就绪引导 | 选择/能力范围已验证 | 7/7；取消、过期输入/工程/意图不执行，实际 client capability；不等于完整索引/设备健康 |
| U5 UE 代码片段 | 实际 Blink 已验证 | 默认 63 项 = 12 UE + 51 普通；实际 accept/Tab/undo；12 条 native expand |
| U6 重构预览与恢复 | 原生批次及独立审查通过 | 30/30；跨文件、Unicode、磁盘/版本漂移、部分失败、新输入、整批撤销及 UI 确认 |
| U7 实际代码操作 | compiler 返回范围已验证 | 实际 clangd rename、ExtractVariable 应用/撤销；UE 只读探测 extract/include，outline 有限制 |
| U8 日志阅读 | 实际 reader 已验证 | 保留原始历史、暂停/跟随、筛选、Unicode 分片与尾行、隐藏/停止后回看、淘汰提示 |
| U9 命名运行配置 | 独立复核通过 | 22/22；真实并发字段 receipt/CAS、同值 ABA、相同 tuple 零 setter、无法证明的 target 回滚拒绝 |
| U10 会话/重启/文本恢复 | 原生进程已验证 | recovery 17/17、session 6/6、restart 2/2；跨 PID、清理竞态、重复 setup、64+64+1 历史与外工程预算隔离 |
| U11 阅读上下文 | 复用现有能力已验证 | 实际 112×48 RPC UI，长 C++/宏/两 split/两 tab；[c 与 Ctrl-O；短窗口/宏展开边界 |
| U12 UE 类型调试 | 所选 Android 设备原生限定样本已测，易读显示未完成 | 同 BuildId、后台冻结解除后真实 attach；空 FString/数组、非零 FName、NULL UObject；无 typed variables/GUI/非空数据证明 |
| U13 循环与索引性能 | 只接入已证明的部署复用 | SHA-256 unchanged marker 才报 skipped；UBT 输入证明及全工程索引仍未完成 |
| UE 类创建 | 原生文件与 UObject UHT 已验证 | 模块限制、预览/取消、wx 冲突、部分失败所有权；UObject UHT exit 0，非完整工程编译 |
| UE Editor 测试 | 入口/生命周期已验证，实际发现未过 | 16/16；真实 binary/argv；隔离 Editor 发现限时退出，尚无真实测试列表/结果 |
| Blueprint / Editor 资产关联 | 缺少可用桥接能力 | 实际插件默认/项目启用配置不提供现成后台；未用二进制资产文本搜索伪装语义 |

主要改动与归属：

| 用户流程 | 实现文件 |
|---|---|
| 构建反馈、阶段日志与可信运行 | [ue.lua](../lua/ue.lua)、[build_diagnostics.lua](../lua/ue/build_diagnostics.lua)、[bottom_panel.lua](../lua/utils/bottom_panel.lua)、[Android iterate](../lua/ue/workflows/android/iterate.lua)、[task_registry.lua](../lua/utils/task_registry.lua) |
| 调试布局与日志阅读 | [dap.lua](../lua/ue/dap.lua)、[_layout.lua](../lua/ue/dap/_layout.lua)、[_log_view.lua](../lua/ue/dap/_log_view.lua)、[_operation.lua](../lua/ue/dap/_operation.lua) |
| 多文件修改、预览与批次撤销 | [refactor.lua](../lua/utils/refactor.lua)、[refactor_command.lua](../lua/utils/refactor_command.lua)、[workspace_edit.lua](../lua/utils/workspace_edit.lua)、[workspace_edit_input.lua](../lua/utils/workspace_edit_input.lua) |
| 工作恢复与命名运行配置 | [edit_recovery.lua](../lua/utils/edit_recovery.lua)、[session_restore.lua](../lua/utils/session_restore.lua)、[restart.lua](../lua/utils/restart.lua)、[run_profiles.lua](../lua/ue/run_profiles.lua)、[project_state.lua](../lua/ue/project_state.lua) |
| 发现能力、补全与 UE 工具 | [ue_hub.lua](../lua/utils/ue_hub.lua)、[blink.lua](../lua/plugins/blink.lua)、[片段规则](../snippets/AGENTS.md)、[ue_entities.lua](../lua/utils/ue_entities.lua)、[editor_tests.lua](../lua/ue/editor_tests.lua)、[Windows driver](../lua/utils/platform/windows.lua) |

简化包括删除 DAP 全局清窗与 `:only`、筛选日志时重启 reader、阶段发起即成功和未变快照重复写入；
复用现有 bottom host、原生 diff、语法 context、选择器与平台 driver，未新增依赖。

## 验证与证据

- 最终 required-native 全量 **2692/2692，0 failed，0 skipped，exit 0**。
  覆盖恢复发现预算补强的两条新增用例，日志为 `.tmp/ide-experience-full-qualified-20261003.log`。
- `ide_` 分层集成与独立复核、命令 **141/141**、host spawn 审计 **13/13** 已通过。
  修改/新增 **51 个 Lua 文件** AST bare-global lint 通过；新文件及 lane 修改范围格式检查通过。
  最终门禁后使用 StyLua `--verify` 完成三处排版，验证 AST 等价，未改变运行行为。
- 排版后的 `ide_` 定向 **190/190**、最终文档 `structure` **78/78**，均 required-native、零失败/跳过、exit 0。
  新增文件与 tracked 新增行的本地私有 denylist、通用 secret 扫描均 exit 0；原始私有证据和运行状态保持忽略。
- 收尾曾误用 `NVIM_TEST_FILTER` 启动补查，它不是入口支持的变量；两次自有补查均已中止。
  改用命令行 filter 后取得上面的定向结果。没有把中止日志作为通过证据；最终全量日志独立保留。
- 本地原始证据保存在忽略的 `.tmp/`：`ide-debug-mixed-integration.log`、
  `ide-refactor-independent-review.log`、`ide-workflow-independent-review.log`、
  `ide-recovery-current.log` 的早期 red 及随后 15/15 green、`ide-reading-audit/native-report.json`、
  `ide-native-audit/evidence.summary.json`、`ide-ue-tools/`。不把私有工程路径、包名、serial 或完整命令写入公开记录。
- 重构独立复核曾实际复现五个问题：取消后的旧确认、请求期间新加载的脏目标、确认期间撤错新批次、
  恢复记录落后、失效 client 阻断其他 client。新增 red/green 回归后独立 30/30 通过。
- 恢复日志重复事件曾只改变 timestamp、重写另一进程正在观察的相同快照；复用未变内容后保留
  raw bytes 与 mtime。保存后异步 unlink 与新输入并发、热重载 setup、正常退出旧/新 session marker 均有原生回归。
- 全量首轮 **2689/2690** 的唯一 red 是原有同秒测试用后一次 `os.time()` 代替 marker 时间。
  原生独立延迟实验：后取时间晚一秒会正确清掉旧 marker；使用持久化时间作为等号边界则保留。
  修正测试后 21/21 定向与 2690/2690 全量通过；没有修改 watcher 行为。
- 恢复发现实际复现旧两代各 64 条 closed 快照遮住最新 crash（15/16 red）。按项目直接寻址、
  预算前过滤 closed/live、异步优先最近 session 后 17/17 green；另证实外工程不占默认扫描预算。
  每轮最多 128 快照与每目录 256 项，达到上限明确显示扫描受限，快照保留；不把截断列表报为完整。
- 混合 synthetic/local frame 的 capture-first 顺序曾真实跳源后丢失原阅读点，18/19 red；
  扫描有效 path/正行号后 19/19 green，all-synthetic 不取得恢复 ownership。

## 性能与语义边界

早期只读语义审计使用磁盘启动默认选择，UE 4.26.2 / Android-Test；它不能代表所有 GUI 实例。
后续原生 IPC 已证明用户当前 GUI 有另一个 live project/engine、Win64-Test 选择；真机验收按此实时
上下文核对，不用前一个默认值覆盖。以下数字只对应早期隔离审计：

- Test exact CDB 16542 唯一路径（14414 cpp、26 cc、7 c、2095 shader），约 260 MB；单线程清点约 492ms。
  当前 Test modules/receipt 不能证明合格发布，测试的两个 exact Core 命令实际引用 Development PCH。
  只有 Development 有已发布 controlled artifacts；不得把该数据标为 Test 语义就绪或完整覆盖/压缩验收。
- clangd 22.1.5、单 worker、关闭 BackgroundIndex 的 Color.cpp/Color.h 首次解析约 1.24/1.23s，
  各进程 RSS 约 497/501 MiB，CPU 约 2.38/2.28s。OS 缓存未控制，不是全索引冷/热或物理 GUI 基线。
- 实际 UE extract-variable/function 能生成 edits；include removal 返回 WorkspaceEdit。
  FORCEINLINE outline 返回服务器错误；另一个普通函数 outline 指向不合适的头文件，未接受修改。
  未证明 Change Signature、生成声明/实现或所有缺失 include；实际编译器返回集和预览仍是支持边界。
- 单次合成预览实验：1k edits 准备约 16.8ms、应用 4.1ms、最大心跳间隔 15.7ms；
  10k edits 44.6/8.5/44.6ms。没有 UE 全工程/GPU/冷缓存或有效 CPU 计时，不能据此承诺统一延迟。
- 现有语法 context 热样例 parse/get 约 0.31ms（长 C++）与 0.18ms（宏夹具）；CPU 计时分辨率不足，
  不表示零 CPU。宏调用产生的不可见语法不提供 context；Tree-sitter 不成为 C++ 语义权威。
- fixture 合成修改 columns/lines 后重复 native heap crash；移除全局 resize、使用宿主实际尺寸后
  所有硬用例和集成通过。只证明触发条件，底层 heap 机制仍待验证，不包装成产品内存根因修复。
- 隔离 UObject UHT 成功约 1.49s；UHT 会把 `.tmp` 名称替换后提升生成文件，已核对真实产物并只迁回
  owned 文件。Actor/Component 模板审校不等于实际工程 UHT/C++ 编译通过。
- 实际 Editor 的 `-nothreading` 负控在 AppInit 的 FSingleThreadEvent 断言失败，生产 argv 不含此开关。
  常规 threaded argv 在 owned Job Object 10% CPU 上限、低优先级下 45s 仍初始化中，限时终止并回收，
  无 discovery/report。该受限实验不是生产 120s discovery 的完成时间或根因结论。

## 所选 Android 设备的真实调试与类型边界

采用 GUI 实时工程的实际 Android/Test ELF；宿主带 DWARF，GNU BuildId 与设备实际加载模块逐字一致。
当前包、PID、符号和 adapter 均实际核对，设备选择只用于本次 probe，不改 GUI 持久化选择。

- 冻结时原生协议停在 vAttach；符号索引约 11s 已完成，host 后续 CPU 为 0，不能归因仍在解析大库。
  ActivityManager 的 cached/empty/isFrozen、全部目标线程 do_freezer_trap、ptrace server do_wait
  共同指认 **L2 cached-app freezer 前置条件**，不是 Python 或 slide 问题。
- 正常解析 launcher Activity 后一次 `am start` 置前台，219ms WARM，同 PID、同 BuildId、isFrozen=false、
  主线程改为 do_epoll_wait。原工具/信号/slide 路线附加成功 **10.31s / 9.97s**；成功收到不杀游戏的 detach 回应。
  没有 force-stop、安装/部署、全局解冻策略变化；收尾游戏仍存活、TracerPid=0、无 owned 调试进程。
- 真实 Core FString 全局实际为空，raw pointer=NULL/ArrayNum=0/ArrayMax=0；生产 summary 输出
  `<no summary available>`，对应 Data TArray 的 `size=0 cap=0` 与 raw 字段一致。两个 source-proven
  静态 FName 的实际索引非零、Number=0，但没有可读名称；GEngine/GWorld 为 NULL。
- 规则来自现有 `lua/ue/dap/_android_engine.lua`，probe 没有添加 formatter。空指针 `%s` 导致整个
  FString summary 失效的解释还未独立闭环，保持推测。先前 `expression --no-run-target true` 返回
  unsupported option，未执行表达式；已显式留底，后续只用实际支持的 target/frame variable 命令。
- 该证据是 DAP 命令通道的原生 LLDB 文本；typed variables、GUI 展开、非空字符串/数组、实际 UObject
  名称、优化变量及值的独立内存对照仍缺验收，不能把成功 attach 当作 U12 完成。
- LLDB 峰值约 **21.7 个核、6.32 GiB RSS**，不证明宿主负载让路或 Neovide 响应门槛；U13 仍独立验收。
  原始协议、source 定位和修正记录保存在 `.tmp/ide-ue-types/type-sample-report.md`，公开记录不含私有上下文。

## 已完成与未完成

已完成可验证范围的 IDE 入口、修改/恢复和运行/调试体验，最终全量门禁通过。
仍未完成全工程 SuperUnity/重复 prepare 性能、UBT 安全跳过、UE 类型同构建真机显示、
实际 Editor discovery/run、Actor/Component 真实工程编译及 Blueprint 桥接。原生 UI/clangd/进程证据
不能替代这些验收，也不无限推迟已验证切片交付。

## 2026-10-04 公开镜像收尾

公开记录中的实机代称泛化为通用 Android 设备描述；原始协议、设备标识和私有工程上下文
继续保留在忽略目录。独立只读审查覆盖本批 67 个文件，未发现脱敏阻断项。

四份已修改主 spec 严格校验、51 个 Lua 文件 AST、新文件格式检查通过；当前无活跃 OpenSpec
change，沿用直接同步主规格和版本记录的既有流程。提交前重新执行 required-native 全量
**2692/2692，0 failed，0 skipped，exit 0**，日志为 `.tmp/ide-publish-full-20261004.log`。
工作区、提交说明及作者元数据的本地私有 denylist 和通用 secret 预检均 exit 0；提交/ref/推送
原生隐私 hooks 保持启用，版本 tag 仍待明确请求。
