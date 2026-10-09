# hana-alice/nvim 2.1.0 — iOS 真机调试与会话日志

> 日期：2026-10-09
> 类型：Minor；新增 iOS 会话日志入口并收尾真机启动调试。
> 状态：实现和真机证明已完成；本次发布验证结果见下文。
> 发布流程：已授权 sync、archive、commit、push；tag 仍待明确授权。

## 当前交付

- CoreDevice 启动 attach 保留有限远端等待、严格 UUID/源码证明与冻结 owner 清理。
- 第四页统一 `UEDAPTab log`，iOS Logs 使用本次设备/PID，旧 logcat 命令兼容。
- 会话关闭、reader 取消、日志 wipe 重开与晚到 callback 互相隔离，不改变 debuggee 的运行状态。
- 公开探针产物只保留 identity/source digest 与已验证结果，原始设备、项目、签名与真机日志留在本地。
- 操作手册覆盖构建、符号、安装、启动/attach、求值、日志与清理；架构与知识库导航同步日志归属。
- OpenSpec 交付记录：`openspec/changes/archive/2026-10-09-finish-ios-device-debug-iteration/`。

## 最终发布验证

- 最终全量 `nvim --headless -l tests/run.lua`：2340/2340 passed，0 failed，38 capability skipped。
- 严格主 spec 校验 41/41；两份 delta 的 4 个 requirement 与主 spec 完全一致；change 严格校验通过。
- Python probe self-test/语法检查、11 个独立 Lua 文件 StyLua、9 个运行时模块 AST lint、diff whitespace 检查通过。
- 发布历史和暂存树通过私有 denylist 与通用凭据扫描；原始诊断与历史恢复 ref 只留本地。
- `lua/ue/targets/ios.lua` 继承了已有 StyLua 格式差异，本轮保留无关行；行为回归与 AST lint 通过。
- 本次仅发布 `feat/macos-ios-nvim`；其他三个远端分支仍可达旧私有词历史，未作远端历史改写，不能视为整个镜像完成脱敏。
- 普通 `UELogToggle` 的 IOS 主日志策略未实现；本次支持 DAP 会话的第四页。
- 使用宿主已有日志工具，不自动安装；真实签名、Developer Mode 与设备连接仍须满足门禁。

## 改动记录

以下保留本次及自上一里程碑以来的已记录变更。排查阶段的限制以「当前交付」和最终验证为准。

### 2026-10-09 — Publish reproducible iOS evidence without private identities

**Task**

同步、归档、提交并推送已验收的 iOS 调试交付，同时核对公开文件和整个待发布历史的脱敏。

**Implemented**

- 两个探针生成器只发布路径 digest 和源码行号；诊断消息也清除捕获身份与路径名称。
- 三份真实 passed evidence 只变更脱敏字段，保留原 proof、结果与已有 digest，不重新编造真机结果。
- 将测试夹具私有名称替换成中性示例，并清理待发布历史；保留原提交、merge 关系和 metadata，目标 feature 可快进推送。
- 同步两个主 spec、归档完成 change，并将本轮及前一里程碑后的既有记录汇入 2.1.0；本地其他工作记录保留。

**Pitfalls / Gotchas**

- 路径 basename 仍可暴露项目身份；只删绝对路径前缀不足以脱敏。只扫描最新 diff 也会遗漏历史 blob。
- 本地恢复 ref 使用私有命名空间；公开扫描只针对本次目标分支，不表示其他已发布分支的旧泄漏已清除。

**Validation**

- 最终全量 2340/2340 passed、0 failed、38 capability skipped；probe/redaction 6/6、DAP 257/257。
- 48 个重写提交的 parent/merge 与 metadata 一致；完整历史 3,285 个 blob、422 个提交 metadata 扫描无命中。
- 暂存树及发布提交消息经过私有 denylist 与通用凭据扫描；严格主 spec 41/41 与 change 校验通过。
- spec 一致性：两 capability 的 4 个 delta requirement 已同步并逐块复核，无待同步漂移。

**Follow-ups**

- v2.1.0 tag 待明确授权；其他远端分支的旧历史需要独立清理范围，不在本次 feature 推送中改写。

### 2026-10-09 — Show the active iOS application's device logs during debugging

**Task**

iOS 调试第四页使用对应的设备日志，并补齐真机操作手册。

**Implemented**

- 第四页统一入口为 `:UEDAPTab log` / `<leader>d4`，按冻结 session owner 选择日志；
  IOS 显示 `iOS Logs`，Android 保持 `Logcat`，旧 `logcat` 命令兼容同一页。
- iOS owner 用已有 `idevicesyslog` 按冻结设备/PID 过滤；CoreDevice 经限时结构化 details
  查询校验 identifier 并映射 hardware UDID。initialized 后自动收集，缺工具或连接失败明确显示证据。
- 保留最近 12,000 行、分块输出与用户滚动位置；关闭 buffer 可重开。reader/查询可由 Tasks
  单独取消，关闭会话时清理其 reader，旧查询/输出/关闭回调不影响重新打开或其他会话。
- 操作手册补齐 iOS Build/Symbols/Install、Launch/Attach、断点与求值、REPL/Console/日志、
  packet timeout、dSYM 排错与 Stop 归属；运行时速查同步第四页名称。

**Pitfalls / Gotchas**

- CoreDevice UUID 不是 MobileDevice hardware UDID；不能直接传给日志 relay 或读取 Android 历史设备。
- dapui Console 是 runInTerminal 终端；Apple attach 不保证创建它，adapter output 与求值交互在 REPL。
- 日志是旁路读取，不发送 continue/detach/terminate；普通 `:UELogToggle` 的 IOS 策略仍未支持。

**Validation**

- DAP 范围 257/257 passed（含 iOS 日志 11 项与日志页路由/兼容/历史 2 项）。
- 最终全量 `nvim --headless -l tests/run.lua`：2340/2340 passed，0 failed，38 skipped；
  文档结构 78/78、操作速查 143/143。
- 用户 nvim 的 fresh production CoreDevice launch：loaded UUID 与 source breakpoint 验证通过，
  首次继续命中 `LaunchIOS.cpp:555`；第四页实际收到本次 PID 的 `[UE4]` 与设备日志。
  REPL → `logcat` 返回同一 buffer 并保留历史，查看日志前后暂停线程不变；当前会话保留在 main。
- 新/修改独立 Lua 模块与用例 StyLua 检查、六个修改运行时文件 AST bare-global lint、
  `git diff --check` 均通过；严格 spec 校验 41/41。
- spec 一致性：同步 iOS debug 的日志归属/过滤/清理契约，并更正 build/run spec 中已陈旧的
  “原生 iOS DAP 尚未实现”描述；普通启动与调试入口保持分离。

**Follow-ups**

- 日志 relay 是可选宿主能力；缺工具或设备连接失败保持明确错误，不自动安装或切换设备。
### 2026-10-09 — Preserve the initial CoreDevice connection during debug launch

**Task**

继续真机启动时 attach，恢复在应用入口执行前验证身份并设置源码断点的工作流。

**Implemented**

- CoreDevice DAP 在连接前设置有限的 60 秒 gdb-remote packet timeout；保留输入 init commands、
  frozen device/PID、start-stopped 启动、首次 continue 前 loaded UUID 验证与 owner cleanup。
- 独立 Apple LLDB CLI/raw-DAP probe 使用同一 packet timeout；沿用现有流程，不增加 resume、
  信号处理、adapter fallback 或绕过身份验证的路径。
- 强化原 launch/attach 回归，锁定 packet timeout 时序、输入不变与严格 UUID gate；同步 iOS debug spec。

**Pitfalls / Gotchas**

- 真机启动停止点的 `qProcessInfo` 约 20.27 秒才返回，随后初始 loaded-images 请求约 20.01 秒返回。
  默认 5 秒 packet timeout 会使通道在这些合法回复到达前断开；DAP `timeout=240` 不控制内部 packet timeout。
- 提高 packet timeout 后，在初始 SIGSTOP、未提前 continue 或 resume 时已取得真实主镜像 UUID 与可读内存。
  先前空模块与内存失败不能据此归因于设备拒绝读取或应用镜像错误。

**Validation**

- 生产 CoreDevice debug launch smoke（`NVIM_IOS_DAP_SMOKE_TIMEOUT_MS=600000`）：passed；start-stopped 后 loaded UUID 验证、source breakpoint
  resolved、首次继续命中 `LaunchIOS.cpp:555` 的 `main` frame、`1 + 2` 求值与 launch-owned cleanup 全部通过。
- 独立 CLI/raw-DAP probe（`--timeout 240`）对 fresh start-stopped PID：passed；初始 thread count 1，
  UUID、入口断点、精确 frame、disconnect ACK、非终止 detach 与 Apple CLI attach/detach 全部通过。
  随后核对同一进程身份并清理本次测试进程；三份 CoreDevice evidence 由真实探针结果更新。
- iOS CoreDevice 19/19；全量 `nvim --headless -l tests/run.lua`：2327/2327 passed，0 failed，38 skipped。
- 独立 probe self-test 与 Python 编译检查通过；修改 Lua 文件通过 StyLua，`git diff --check` 通过。
- spec 一致性：同步初始慢查询的有限超时与严格放行契约；严格 spec 校验 41/41。
- 活跃用户 nvim 实际 `UEDAPLaunch ios`：passed；session operation 为 launch，当前 source/cursor
  为 `LaunchIOS.cpp:555`，loaded UUID、verified breakpoint、精确 frame 与 `(int) $0 = 3` 均确认。
  保存同一 project 的已验证 device/backend/bundle，保持当前 session 暂停供继续调试。
- 更新 evidence 后 probe/redaction 回归 6/6、文档结构 78/78。

**Follow-ups**

- 当前构建的启动时 attach 阻塞已解决；60 秒 packet timeout 仍是有限边界，超时或 identity 失败保持原 cleanup。
### 2026-10-09 — Recover current iOS device debug and close failed adapters safely

**Task**

继续用户在 nvim 完成的 IOS Development 编译，自主处置签名与符号阻塞，并执行当前构建的真机启动、
production attach、断点、求值和 cleanup 验证。

**Implemented**

- 捕获活跃 nvim 的当前 project/build receipt，生成并验证匹配当前 Mach-O 的完整 dSYM；
  真机验收通过后接回默认调试路径，旧无效 bundle 与 Apple parallel bundle 保留为本地备份。
- 在已有 Aqua GUI 会话执行真实签名探针与现有安装 helper；暂存当前 UBT `.app` 和签名输入，
  补齐同版本 QA cookeddata，写入非 iterative 启动配置，完成 container-preserving 真机安装。
- `_ios_session` 通过 nvim-dap 公开 `on_session` / `session.on_close` 接口捕获 adapter 退出；
  只对 owned iOS session 异步派发既有幂等 cleanup，不依赖协议结束事件或全局 active session。
- 真机 smoke 在求值前保存 UUID、断点与源码 frame 证据；adapter 意外关闭时及时报告失败并清理，
  不再等待完整测试超时。

**Pitfalls / Gotchas**

- Background 签名探针的 `errSecInternalComponent` 来自 audit session 的钥匙串访问；
  同一 identity 在 Aqua 会话真实签名通过，无需修改密码、钥匙串 ACL 或系统安全设置。
- Apple parallel dSYM 虽通过 DWARF verification，却令当前 C++ frame 的 `1 + 2` 求值触发
  Apple lldb-dap 类型递归栈溢出；显式 C 表达式也失败。机器已有 LLVM 23.1.3 生成的新 dSYM
  通过相同 UUID、Apple 类型解析及真实断点/求值验收，与 [LLVM #162954](https://github.com/llvm/llvm-project/issues/162954)
  报告的类型自引用问题相符。Apple classic 候选超过 4 GiB 且校验失败，未替换默认符号。
- 优化构建将 Tick 入口断点从声明行 4831 定位到执行行 4833；精确源码验收采用真实执行位置。
- CoreDevice `--start-stopped` debug launch 停在早期 dyld 时主镜像列表为空且栈内存不可读；
  同步 attach、显式 remote-ios、等待 stop 与单指令诊断均未恢复 loaded-image 证明。
  production gate 保持 fail-closed，并已清理本次 launch-owned PID；不能将普通启动通过等同于 debug launch 通过。

**Validation**

- 最新符号：既有 LLVM 23.1.3 `dsymutil --linker parallel --num-threads 2 --verify-dwarf=output` exit 0；
  Mach-O/dSYM UUID 一致；Apple LLDB `type lookup FEngineLoop` exit 0。
- 真机普通启动成功；production CoreDevice attach smoke：passed，loaded UUID、verified breakpoint、
  真实 breakpoint stop、精确 `LaunchEngineLoop.cpp:4833` frame、`1 + 2` 求值与进程保留 cleanup 全部通过。
- 独立 CLI/raw-DAP probe：passed；真实 PID/bundle 与 host UUID、DWARF 校验、Apple LLDB CLI
  attach/detach、DAP source breakpoint、精确源码 stop、disconnect ACK 和断开后进程存活全部通过。
- 活跃用户 nvim 接回 production attach；真实 session 的 loaded UUID 与断点均验证，当前帧
  停在 `LaunchEngineLoop.cpp:4833`，求值返回 `(int) $0 = 3`，保持暂停供继续调试。
- 两次 Apple adapter 崩溃后，均通过 production owner cleanup 复验原 attach 进程保留。
- iOS lifecycle 19/19、DAP 244/244、platform 51/51、failure layering 100/100、boundary 17/17。
- 全量 `nvim --headless -l tests/run.lua`：2327/2327 passed，0 failed，38 skipped。
- spec 一致性：同步 iOS debug spec 的无协议结束事件 cleanup 与部分证据失败场景；严格 spec 校验 41/41。
- 文档结构回归 78/78；修改的 iOS lifecycle、smoke 与回归文件通过 StyLua，`git diff --check` 通过。

**Follow-ups**

- 此条为符号恢复阶段的历史记录；后续启动停止点已通过有限 packet timeout 修复，并通过独立生产 launch 与协议验收（见本 release 的启动连接记录）。
- 当前 development profile 将于本地记录的到期日失效；后续编译应继续验证真实符号语义，不能仅检查 UUID。
### 2026-10-09 — Keep delayed iOS debugger cleanup with its original session

**Task**

修复旧 iOS debug 会话的延迟清理可能清空或停止新会话，以及连续 stop 重复安排 teardown 的竞态。

**Implemented**

- `lua/ue/dap/ios.lua` 为每次 bootstrap 冻结独立 owner token，并写入 CoreDevice/legacy DAP config；
  unexpected-end、显式 stop 和 cleanup fallback 都核对同一 owner，兼容 nvim-dap config 深拷贝。
- 重复 stop 共享一次 disconnect/cleanup 与完成结果；等待清理时拒绝新 bootstrap，旧 finalizer
  不得覆盖后来替换的 runtime。
- `tests/cases/ios_dap_coredevice_spec.lua` 增加旧 UUID fallback、退出事件、缓存 cleanup、stale stop、
  清理期间 launch 和重复 stop 的 5 个回归用例。

**Pitfalls / Gotchas**

- 平台/backend 相同不代表同一次 debug 会话；仅凭 `is_owned()` 处理全局 runtime 会串会话。

**Validation**

- 新增 owner 隔离与重复 stop 回归先红后绿；`ios_dap_coredevice`：15/15。
- rebase 前全量 `nvim --headless -l tests/run.lua`：1331/1331；StyLua check、AST bare-global lint、
  `git diff --check`、工作区 diff 隐私扫描均通过；对应 spec 的 OpenSpec strict validation 通过。
- 同步 `ios-device-debug-workflow` spec 的旧会话回调场景；不改变既有 CoreDevice/legacy route 或真机验收门禁。

**Follow-ups**

- 原 rebase 隐私门禁阻塞已按用户要求移除并完成 main 集成（见上条）；
  真机断点/cleanup 尚未在本次会话复验。
### 2026-08-27 — Prefer the connected CoreDevice route for modern iOS launch

**Task**

修复 `<Space>ul` 在同一台现代 iPhone 同时被 CoreDevice UUID 与 MobileDevice UDID 发现时仍选择
legacy `ios-deploy`，以及切到 Xcode 26 CoreDevice 后无法解析新版 launch JSON 的连续报错。

**Implemented**

- `lua/ue/targets/ios.lua` 的 `parse_device_list()` 保留 CoreDevice JSON 中的 hardware UDID 与 transport，
  让 workflow 能证明 CoreDevice/MobileDevice 候选属于同一台物理设备。
- `lua/ue/workflows/ios/device.lua` 以 CoreDevice ID 与 hardware UDID 双索引合并候选；保存的 MobileDevice
  UDID 命中同机已连接 CoreDevice 时升级到 `coredevice`，不把它误判为另一台设备，也不削弱离线设备
  禁止静默替换的契约。
- `lua/ue/targets/ios_launch.lua` 在 Xcode 26 的 result 不再回显 bundle 时，从同一结构化 JSON 的
  `devicectl.device.process.launch` argv 精确复验预期 bundle；缺少或不匹配仍 fail closed。
- `tests/cases/ue_target_drivers_spec.lua` 与 `tests/cases/ue_workflows_spec.lua` 覆盖 hardware UDID 关联、
  CoreDevice 优先和 Xcode 26 launch schema。

**Pitfalls / Gotchas**

- CoreDevice identifier 不是 MobileDevice UDID；只按展示名或单一 ID 合并会制造重复设备，按“保存 ID”
  直选又会把 iOS 17+ 设备锁回不兼容的 legacy DDI 路径。
- Xcode 26 launch result 仍提供 device 与 PID，但 bundle 只存在于结构化 command arguments；不能直接用
  调用方期望值补空，否则会把“执行了某命令”误当成“结果身份已验证”。

**Validation**

- 范围回归：`ue_target_drivers` 48/48、`ue_target_integration` 26/26、`ue_target_tasks` 9/9、
  `ue_workflows` 27/27、`ue_platform_boundary` 9/9、`platform` 39/39、`commands` 106/106、
  `stability` 10/10、`structure` 71/71、`keymaps` 56/56，全部通过。
- 全量 `nvim --headless -l tests/run.lua`：1326/1326；真机 `:UELaunch` 使用 CoreDevice 成功并回写正 PID，
  独立 `devicectl device info processes` 查询确认该 PID 对应目标 app 可执行文件。
- 现有 `ios-build-run-workflow` 与 `ue-target-workflow-boundary` spec 已要求合并设备 transport、固定同一设备、
  CoreDevice launch 与结构化身份校验；本次修复实现漂移，判定无 spec 文本变更。

**Follow-ups**

- 无。
### 2026-09-30 — 最近项目列表并发写入在 Windows 上丢记录

**Task**
- `5db84e9` 后 Ubuntu/macOS 全绿，Windows 仅剩 `multi_instance_state`「recent-project MRU keeps concurrent distinct roots」（8 个并发实例丢 1 条）。

**Implemented**
- `lua/utils/recent_projects.lua`：拿到锁后若读取/原子 rename 失败（Windows 上别的实例正打开该文件读取时 rename 会失败），改为走与抢锁失败相同的异步重试，而不是静默丢弃这次写入；重试上限 20 → 60（约 1.5 s）。这是生产代码的真实缺陷：多个 Neovim 同时启动时最近项目可能丢失。

**Validation**
- `multi_instance_state` 本机连续 5 次 27/27。
### 2026-09-30 — CI 引导只装了一半插件（git_review_runtime 三平台失败的根因）

**Root cause（CI 日志 + 本机全新数据目录复现）**
- `scripts/bootstrap_headless_ci.lua` 在 LazyVim 克隆前就解析 `import = "lazyvim.plugins"`，日志报 `No specs found for module "lazyvim.plugins"`，只安装了项目自身的 27 个插件（lockfile 共 44 个）。真实启动随后看到完整依赖图，报 `Plugin flash.nvim / nvim-ts-autotag … is not installed`（ERROR），`git_review_runtime` 因此失败。本机全新目录复现同样只得到 28 个目录（含 lazy.nvim）。

**Implemented**
- 引导脚本在首次解析后重新加载 spec，把缺失插件按冻结 lockfile 装齐（最多 5 轮）；原有「每个插件必须在锁定提交」断言现在覆盖完整依赖图，CI 自身即为验证。
- `tests/cases/ue_cdb_shader_receipt_spec.lua`：后续按条目查找改用产物中的路径拼写（Windows CI 8.3 短名）。

**Validation**
- `review_ci` 3/3、`ue_cdb_shader_receipt` 3/3 本机通过；引导修复待本轮 CI 验证。
### 2026-09-30 — git_review_runtime 的 Diffview 关闭竞态；macOS FSEvents 假设实验

**Task**
- `ae75b2f` 后 `git_review_runtime` 不再空转（证实上条根因），但 Linux/macOS 暴露下一处失败。

**Implemented**
- `tests/cases/git_review_runtime_spec.lua`：可视模式 Diffview 文件历史等到 `panel.cur_item` 已选中、主窗口已打开文件再按 `gV` 关闭。CI 证据：只等 `#entries > 0` 就关闭，锁定版本 Diffview 的 `update_entries` 回调在关闭后执行 `cur_file()`，`file_history_panel.lua:380 attempt to index field 'cur_item' (a nil value)`。属测试时序，Diffview 版本与生产映射未改。
- `tests/cases/index_batch_runtime_spec.lua`（仅 macOS）：在安装监听前等 1 s，检验「FSEvents 延迟投递监听开始前刚写入的 `compile_commands.json`（报为 `rename`）」这一**假设**。若 CI 仍失败则假设不成立，需另查。

**Validation**
- 本机 `git_review_runtime` 连续 2 次 1/1；`index_batch_runtime` 80/80。

**Follow-ups**
- CI 子进程的 `Plugin <name> is not installed` 为 WARN 级（lazy 对未进 lockfile 安装范围的插件的提示），不再造成空转；是否影响用例待本轮结果。
### 2026-09-30 — 定位并修复 git_review_runtime 在 CI 上的 CPU 空转

**Task**
- 三平台 CI 上 `git_review_runtime` 子进程在「等 Gitsigns 挂载」处卡死直至外层 60 s 超时。

**Root cause（CI 证据 + 本机独立复现）**
- `f60ce15` 的计数钩子调用栈：`runtime.lua:40 notify` ← `lazyvim/util/init.lua:165`（`lazy_notify` 的 replay 循环）← 测试的 `vim.wait`。
- LazyVim 启动时把 `vim.notify` 换成把消息追加到 `notifs` 队列的临时函数；测试随后捕获的正是这个临时函数，并让自己的包装函数转发给它。replay 时 `vim.notify` 已不等于临时函数，所以保留测试的包装函数，并对**正在遍历的** `notifs` 逐条调用 `vim.notify` → 包装函数转发回临时函数 → 又追加一条，`ipairs` 永远到不了末尾。只要启动期有一条排队通知（CI 上有 `vim.lsp.set_log_level() is deprecated` 警告），子进程就 100% CPU 空转；git 子进程也因此得不到回收（`ps` 中为僵尸）。
- 独立复现脚本按同样形状运行：500 ms 内调用 1001 次、队列长到 1001 条，确认不收敛。

**Implemented**
- `tests/cases/git_review_runtime_spec.lua`：测试的 `vim.notify` 替换不再转发给捕获的函数，只记录 ERROR 并写 stderr。仅为测试侧缺陷，生产代码未改。

**Validation**
- 本机 `git_review_runtime` 1/1。
### 2026-09-30 — Windows CI：导入期 UTF-8 输出、fixture 文本编码与 8.3 短路径

**Task**
- `9f08099` 的 Windows CI 仍有 10 项失败；逐项读日志处置。

**Implemented**
- 17 个 `tools/*.py` 的 UTF-8 stdout/stderr 重设从 `__main__` 挪到导入期。根因：`index_output_stability` 的驱动脚本 `import` 工具后直接调 `main()`，不经过 `__main__`，6 项仍报 `UnicodeEncodeError`（`←`）。
- `tests/cases/index_inventory_spec.lua`：fixture 的 `write_text` 显式 `encoding='utf-8'`（写入 `İ` 等目录名时按 cp1252 编码失败）。
- `tests/cases/ue_cdb_shader_receipt_spec.lua`：shader 路径按 realpath 比较（CI 临时目录期望值是 8.3 短名 `RUNNER~1`，产物是长名 `runneradmin`，同一文件）。

**Validation**
- 本机模拟 CI 编码（`PYTHONIOENCODING=cp1252`）并行全量 required-native：125/125 文件通过（127.1 s）。

**Follow-ups（根因未定）**
- `git_review_runtime`：Linux/macOS 子进程 CPU 空转（`ps` 为 `R`，git 子进程成僵尸未回收）；Windows 在 4 次运行中有 3 次报 `Plugin mini.ai/... is not installed`（VeryLazy 触发时 lazy 认为插件未安装），另 1 次未出现。两者是否同源待查。
- Windows `ordered Unity` 真实 clangd 索引在 4 次中失败 1 次（`indexing_complete` 为假、编译失败数 0），疑似偶发，待观察。
- macOS `index_batch_runtime` FSEvents 延迟 rename 事件（见前条）。
### 2026-09-30 — 按 CI 诊断修复 core_health 清理与 macOS 路径别名

**Task**
- `6656be3` 的诊断输出定位了两类 Linux/macOS 失败。

**Implemented**
- `lua/utils/core_health.lua`：临时审计目录递归删除失败时有界重试 5×100 ms（刚取消的子进程可能仍在写入），仍失败则保持 FAIL 并在 `next_step` 列出残留文件名。CI 证据：两次审计唯一差异是 `cleanup.temp=FAIL (temporary audit resources could not be removed)`，Ubuntu 与 macOS 都出现。
- `tests/fixtures/cpp_semantic_pipeline/run.lua`：目标 buffer 按 realpath 比较。CI 证据：macOS 上实际为 `/private/var/.../defs.hpp`，期望为 `/var/.../defs.hpp`（`/var` 是 `/private/var` 的符号链接）。
- `tests/cases/git_review_runtime_spec.lua`：加 15 s 周期 watchdog 输出编辑器 mode/blocking，用于区分挂起的输入提示与阻塞的事件循环。

**Validation**
- `core_health` 连续 2 次 28/28；`cpp_semantic_pipeline` 1/1；`git_review_runtime` 1/1（本机 Windows）。

**Follow-ups**
- `git_review_runtime`：Linux/macOS 在「等 Gitsigns 挂载」处被外层 60 s 超时杀掉（exit 124），12 s 的 `vim.wait` 未能返回，说明事件循环被同步阻塞；根因待 watchdog 输出确认。
- macOS `index_batch_runtime`「首次缓存写入」：FSEvents 报告 `compile_commands.json` rename 导致撤销激活；推测为 fixture 在监听启动前刚写入该文件、FSEvents 延迟投递的历史事件，**待验证**，未改代码。
### 2026-09-30 — 修复 PR #13 三平台 CI 暴露的 Windows 编码/前置与测试时序问题

**Task**
- `779c2b2` 的 CI：Windows 32 失败、macOS 5、Ubuntu 2。按根因分组处置。

**Implemented**
- 17 个会打印非 ASCII（`←`/`→`/中文）的 `tools/*.py` 在 `__main__` 入口把 stdout/stderr 重设为 UTF-8（`errors="backslashreplace"`）。根因：CI runner ANSI 代码页 cp1252，`print('← exit')` 抛 `UnicodeEncodeError`，连带 23 个 index/CDB 用例失败；本机 cp65001 不复现。
- `.github/workflows/headless.yml`：Windows 通过 choco 安装既有 `fd` 前置（4 个 required-native 用例报 `fd unavailable`）。
- `tests/cases/ue_unity_origin_spec.lua`：Python 端以 UTF-8 解码 stdin（原按 cp1252 解码中文路径，哈希不一致）。
- `tests/cases/index_inventory_spec.lua`：临时目录与 checkout 不在同一盘符时改为在父目录内用相对名验证（`relpath` 不能跨盘）。
- `tests/cases/multi_instance_state_spec.lua`：MRU 并发子进程等到自己的记录可见再退出（原固定 300 ms，在慢宿主上 `record()` 的异步锁重试尚未完成进程已退出）。
- 诊断增强（根因未定，不改断言）：`core_health` 两次审计不一致时列出非 PASS 项；CLI 失败打印 stdout；`git_review_runtime` 的 Gitsigns 等待超时打印 buffer/gitsigns 状态/`:messages`；`cpp_semantic_pipeline` 打印实际与期望目标路径。

**Pitfalls / Gotchas**
- 本机 Windows 为 UTF-8 代码页，CI 为 cp1252——Python 工具的 print 编码问题只在 CI 暴露。

**Validation**
- 并行全量 required-native：125/125 文件通过（135.4 s）；`multi_instance_state` 连续 3 次 27/27。

**Follow-ups**
- 仍未定位：三平台 `git_review_runtime` Gitsigns 未挂载（此前 CI 已存在）；Linux/macOS `core_health` 审计不稳定；macOS `cpp_semantic_pipeline` 目标 buffer、`index_batch_runtime` 首次缓存写入被 FSEvents 报为 `compile_commands.json` rename 而撤销激活（此前 CI 已存在）。待本次诊断输出后处置。
### 2026-09-30 — SDD 轻量化：spec 只规定大方向并记录选型与踩坑

**Task**
- 用户判定 SDD 过重、阻碍开发：41 份主 spec 近万行、逐字段/逐超时契约与实现同频漂移。要求整理为只规定大方向、记录选型踩坑等重要事项。

**Implemented**
- `openspec/specs/*/spec.md` 全部 41 份重写为统一结构：Purpose（边界与方向）+ 2–6 条方向性 Requirement（保留安全/隐私、SuperUnity 不静默退化、DAP 五层分层等底线）+「## 选型与踩坑」段。
- 政策降级：根 `AGENTS.md` SESSION START 第 4 步与 DoD 第 2/3 条、`docs/CONSTRAINTS.md` C7/C8/C9、`docs/testing-regression.md`、`memory/project_overview.md`、各目录 `AGENTS.md` 的「治理 spec」措辞——日常修复不需改 spec、不强制立 change，changelog 不再逐条声明 spec 一致性处置。
- `openspec/config.yaml` 增加轻量化说明；未实现的 `2026-09-28-restructure-super-unity-compression` 以 `--skip-specs` 归档（0/22 任务，已标注未实现），其调查结论与已选方向浓缩进 `cpp-semantic-index-coverage` 的「选型与踩坑」。

**Pitfalls / Gotchas**
- 瘦身只浓缩不编造；完整旧条款仍可在 git 历史与 `openspec/changes/archive/` 查到。
- SuperUnity 方向（Tier 1 发射序列分组）**尚未实现、无实测收益**，不得引用为已交付。

- 新增 `tests/run_parallel.lua`：每个 spec 文件独立 `nvim --headless -l tests/run.lua <file>` 子进程（run.lua 已隔离 state/log/probe），默认 min(8, CPU/2) 并发，实时逐文件进度，按上次耗时优先调度慢文件。串行 `tests/run.lua` 仍是 CI/提交门禁入口。
- `tests/cases/index_batch_runtime_spec.lua`：盘符根监听用例等待由 3 s 改为 12 s（与同文件 `await_watch_probe` 及生产 10 s 探测预算一致）；同文件其余 7 处等待真实 fs 事件到达的正向 `vim.wait(1000)` 统一放宽到 5 s（并行负载下父目录 rename 失效用例曾超时）。均为「等到条件成立即返回」的正向等待，未改生产时限或断言语义。

**Validation**
- 41/41 `openspec validate <cap> --type spec --strict` 通过；`structure` 78/78。
- `index_batch_runtime` 修复前单独串行 3 次中 1 次失败（盘符根 3 s 等待），修复后连续 4 次 80/80。
- 并行全量（`NVIM_TEST_REQUIRE_NATIVE=1`，Python 3.14，jobs=8）：首轮 124/125 文件（父目录 rename 用例 1 s 等待超时），放宽等待后 **125/125 文件、2344 用例全绿，140.6 s**（串行约 10+ 分钟）。
### 2026-09-30 — 修复跨平台原生回归前置与诊断

**Task**
- Tree-sitter 安装恢复后，继续处理 PR #13 全量回归实际暴露的跨平台失败。

**Implemented**
- `.github/workflows/headless.yml` 为 Linux 安装既有 `fd-find` 前置；用官方 LLVM 22.1.5 完整归档和固定 SHA256 配置编译器、clangd、libclang 与 builtin headers，避免 apt 的 22.1.8 漂移绕开或触发既有精确版本门禁。
- `tools/clangd_batch_bindings.py` 保留选定 libclang 的安装路径，再查真实链接目标，支持 Debian multiarch 布局；显式资源目录和版本约束保持。
- `grep_cache_spec` 在剪贴板输入边界提供 fixture，保留真实 picker 编辑行为；compiler fixture 保留 `clang++` 符号链接的调用名。
- 原生测试区分 Windows 专属场景和缺失工具；watcher 用真实探针验证能力及原命令回退，测试等待覆盖既有生产探针时限。
- `tests/run.lua` 与 harness 在 CI 立即刷新 spec/case 标记，避免提前退出后只能看到延迟通知、无法定位退出点。

**Pitfalls / Gotchas**
- 必需的原生证明仍保持启用，未放宽 LLVM 22.1.5 证明限制、伪造宿主能力或改变 SuperUnity 压缩/准入机制。
- Windows CI 使用 Neovim 0.12.5，本地原版本为 0.11.5；已在临时目录校验并运行官方同版程序，未替换用户安装。

**Validation**
- 剪贴板回归 36/36；libclang 布局新增用例先复现原错误，修复后 required-native bindings 11/11。
- Windows required-native runtime 80/80、activation 9/9、query 7/7、verified batch 27/27；真实 Linux Python 验证不支持的 query profile 拒绝路径。
- 同版 Neovim 0.12.5 的 Git review 73/73、transport 9/9；整合全量见上条（125/125 文件），远端三平台复验待 PR #13 CI。
- Spec 一致性：同步 `headless-test-harness` 的真实宿主适用性与 CI 进度证据契约、`config-regression-suite` 的一致工具链前置；资源查找与 fixture 修复恢复既有行为契约。

**Follow-ups**
- 以对应提交的三平台完整 CI 结果验收；Windows 提前退出的具体位置仍需带进度标记的运行记录确认。
### 2026-09-30 — 修复 CI Tree-sitter CLI 安装版本

**Task**
- 修复 PR #13 三个平台在依赖安装阶段共同失败的问题。

**Implemented**
- `.github/workflows/headless.yml` 将 npm 安装版本从未发布的 `tree-sitter-cli@0.26.1` 改为已发布的固定版本 `0.26.3`。

**Pitfalls / Gotchas**
- GitHub release 存在不代表对应 npm 版本存在；原版本在 runner 报 `ETARGET`，本地 npm registry 查询同样报版本不存在。

**Validation**
- Spec 一致性：无行为契约变更，恢复 `config-regression-suite` 已要求的隔离依赖安装和全量回归入口。
- 临时目录实际 npm 安装成功，CLI 返回 `tree-sitter 0.26.3`；225 个 Lua 文件通过 AST lint。
- 本地 required-native 全量 **2341/2341**，0 failed、0 skipped（测试进程使用已安装的 Python 3.14）；差异检查通过。

**Follow-ups**
- 跨平台验收以 PR #13 对应提交的 Linux、macOS、Windows 完整 CI 记录为准；依赖安装成功不能替代整个工作流通过。
### 2026-09-30 — 更正 shard 播种验收范围并复核发布脱敏

**Task**
- 接力已提交并推送的 shard 播种改动，复核 spec 同步、归档与公开内容。

**Implemented**
- 在 `docs/cpp-index-restart-investigation.md` 更正 42.3 s / 54.2 s 的实测范围，并同步主 spec、归档 delta、proposal 与 tasks。
- 保留归档任务 2.4 未完成；副本索引不再表述为成功的线上激活或完整端到端验收。

**Pitfalls / Gotchas**
- 前次提交的 Tested 摘要过宽；详细证据是 prepare 校验失败后另行启动 clangd 索引。本次追加更正，不改写已发布历史。

**Validation**
- 前次提交的元数据、路径和全部新增内容通过专属 denylist 与通用敏感信息扫描。
- Spec 一致性：主 spec 与已归档 delta 同步更正，15 个 scenario 保持一致；主 spec 严格校验与暂存差异检查通过，未改变运行时行为。
- 首次 required-native 全量为 2338/2341，失败涉及多实例缓存刷新、探针重试与 native watcher 就绪。独立复测分别通过 27/27、10/10、15/15；watcher 的原始断言和生产时限未改动。
- 同一原生 helper 的一次配对测量：默认 Python 3.12 启动到 ready 为 9044 ms，已安装 Python 3.14 为 125 ms；后续 Python 3.14 运行也曾超时，因此不能将波动全部归因于版本。测试进程使用现有 `UE_PYTHON` 显式选择真实 Python 3.14，未伪造工具或改变用户会话配置。
- 最终完整回归 **2341/2341 passed，0 failed、0 skipped**：设置进程内 `NVIM_TEST_REQUIRE_NATIVE=1` 与 `UE_PYTHON` 指向已安装的 Python 3.14 后运行 `nvim --headless -l tests/run.lua`。复测通过不代表上述时限波动已修复。

**Follow-ups**
- 有效 receipt 下的完整激活链路、header shard 差异归因及更大范围 SuperUnity 验收仍未完成。
- 本轮异步测试与 helper 就绪时限波动的根因尚未闭环；保留为既存验证稳定性问题，不宣称由文档更正修复。
### 2026-09-29 — 冻结 shard 缓存从原缓存 add-only 播种

**Task**
- 让 prepare 后首次冻结激活不再把约 33k 个保留 TU 冷重建进独立 shard 缓存。

**Implemented**
- 新增 `tools/clangd_shard_seed.py`：仅添加目标缺失的 `*.idx`（硬链接，跨卷回落 exclusive-create 复制；跳过 `.temp-stream-`；失败删除半截副本；拒绝同目录/缺失目标）。
- 新增 `lua/ue/index/batch_shard_seed.lua`，并在 `batch_runtime` 的本地缓存创建之后、watch probe 之前异步播种；结果不影响冻结权威，失败按冷缓存继续。
- spec `cpp-semantic-index-coverage` 新增场景 "A new frozen shard cache is seeded from the original cache"。
- 调查记录见 `docs/cpp-index-restart-investigation.md` 2026-09-29 节（含 priority A/B 假设被证伪的更正）。

**Pitfalls / Gotchas**
- clangd 22 shard 按源路径寻址、只按内容 digest 判过期、以 temp+rename 写回——这三点是播种安全且有效的前提（源码已核对）。
- header shard 在播种/冷建间存在 refs/relations 差异，归因于写入者非确定性，为推测、待闭环。

**Validation**
- 实测（Android target 隔离副本）：冻结 CDB 冷索引 1713.6 s / 12,937 CPU s → 播种后索引 42.3 s / 47.9 CPU s（重索引 4 个 TU，其中 2 个为 batch TU）。
- Headless prepare（真实 `batch_runtime.prepare`，隔离副本）：播种 linked 37,339、11.8 s；冻结校验因 receipt inventory（某插件 Win64 Editor Intermediate 目录 9/28 新增文件）返回 `receipt-input-or-asset-changed`，正确回落原 CDB。随后独立启动 clangd，在播种后的 verified 目录索引 54.2 s / 56.4 CPU s / 5.35 GB、4 TU、0 失败；该数字不是成功激活的端到端耗时。未验证 live 是否同样失效（推测是）。
- `NVIM_TEST_REQUIRE_NATIVE=1` filters：index_batch_runtime 80/80、index_batch 201/201、index_generation 35/35、cpp_semantic_index 1/1、clangd_commands 10/10、ue_api 65/65、index_graph 12/12、index_verified_batch 27/27、index_vfs_aliases 5/5、index_input_directory 4/4、index_inventory 18/18、cpp_semantic_client 33/33、host_resource_discipline 13/13、stability 26/26。
- 单独跑 `index_query_profile` filter 时报 native coverage unavailable（skip 条件 clangd/python 未解析被触发），全量套件中同一用例通过；推测全量里其他用例设置了 `UE_CLANGD`，未验证；本改动未触及该路径。
- 全量 `NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`：2341/2341 passed。
- spec 一致性：以 change `2026-09-29-seed-frozen-shard-cache` 承载并已归档，同步 `openspec/specs/cpp-semantic-index-coverage/spec.md`；知识库同步 architecture overview / project_overview / `lua/ue/index/AGENTS.md` / tests 映射（新增 `index_batch_runtime`）。

**Follow-ups**
- wrapper 命令变更导致新 TU 路径全量重索引；冻结失效源（仓库 `.omx` receipts）迁出；更多真实 L1 二次合并。
### 2026-09-29 — 归档统一 Git 审阅 change

**Task**
- 按用户指令完成 CodeDiff 工作的 spec 同步核对、归档与提交推送流程。

**Implemented**
- 将完整 change 移至 `openspec/changes/archive/2026-09-29-unify-git-review-with-codediff/`，保留 21 项任务及交付证据。
- 更新 `docs/release_2.0.0.md` 的归档路径和授权状态。

**Pitfalls / Gotchas**
- 其他 SuperUnity change 保留原状；tag 未包含在本次授权中。

**Validation**
- Spec 一致性：三个主规格与 delta 的 10 个 requirement 块逐段一致；change 与三个主规格严格校验通过。
- 归档后提交前 required-native 全量复验 **2338/2338**，0 failed、0 skipped；命令为 `NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`。
- 21 个相关 Lua 文件通过 AST lint；暂存差异通过 `git diff --cached --check`。

**Follow-ups**
- 跨平台和 GUI 验证边界沿用 [v2.0.0 交付记录](release_2.0.0.md)。

Original-reader retention and its acceptance limits are
archived in [v1.12.11](release_1.12.11.md). Broader compression, whole-engine index
performance and search responsiveness remain open.
