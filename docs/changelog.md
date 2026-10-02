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

## Unreleased

### 2026-10-02 — 删文件不再整体重建 csearch；修复增量 add 静默丢同名前缀文件

**Task**
- 用户：切引擎分支 / p4 sync 触发 prepare 没关系，但要复用、避免无效操作；另扫探针查漏补缺。

**Evidence（本机实测）**
- 最近一次 prepare 记录：总 88 s，其中 csearch 71.9 s（state-fields `prepare_timings`）。
- 探针 `csearch-smart-build`：reset 8 次 / add 2 次——任何删除都强制 reset。
- 「cindex 无删除能力」被证伪：codesearch v1.2.0 `Merge` 以 delta root 前缀区间遮蔽旧名字。
- 同一机制的既有缺陷：旧二进制增量 add 在真实 18.2 万文件清单上，对 37 个被前缀遮蔽的未改动文件丢了 36 个（`Foo.h` 改动 → `Foo.hpp` 消失）。
- 真实清单基准：300 删除 + 237 改动（含 37 个遮蔽样例）增量 2.4 s；全量 reset 87.4 s。增量结果与对剩余集合的全量 reset 名字表（181615）与全部 502253 个 trigram 倒排逐项相等。

**Implemented**
- `tools/cindex-uefilter`：`-delete-from FILE`（同一次 merge 删除）；增量时对遮蔽区间做闭包，重新入索引未改动兄弟文件；`rawindex.go` 从测试移出供运行时读名字数。新增 Go 用例：前缀兄弟不丢、只删列出文件。已 `go install`，旧二进制备份为 `cindex-uefilter.exe.bak-20261002`。
- `lua/ue.lua` `csearch_build_mode`：删除不再强制 reset，计入 30% 阈值；`csearch_smart_build` 把删除清单交给 `build_index`（`delete_list`）。旧二进制不认参数 → add 失败 → 既有回退 reset。
- 探针：`csearch-smart-build` 决策改记 `state=ok`（非失败），新 revision `delete-from-2026-10-02`；新增 `prepare-path`（fast/cold）、`android-iterate`（完成/停在哪）、`android-device-gone`（真实掉线是否走到该路径）。
- 处置既有探针：`csearch-smart-build` reset/add 记 resolved；`dirty-set-flood` cap-hit 记 deferred（下一项改动）。
- spec `ue-code-search`、`docs/architecture/grep-cache-invalidation.md` D11 修订旧结论。

**Validation**
- `go test ./...` 通过；全量回归 2391/2391 通过；`csearch_build_guard` 29/29（删除 → add + `-delete-from`、删除计入阈值）、`dirty_overflow`、`grep_cache`、`stability`（ue.lua 10559 ≤ 10562）。
- 未做：在 nvim 内对真实工程跑一次带删除的 `:UEPrepare` 端到端（本次在同一真实清单上直接驱动二进制验证）。

### 2026-10-02 — 设备被拔掉后只会报错了事，没有一键重选

**Task**
- 用户：从实用角度继续找可改善点（承接上一条 iterate 挂起修复）。

**Evidence**
- 按 `global-android-device-selection` spec 的刻意设计，已选 serial 掉线时不自动改投；但四下都只留 adb 原文：install 的 `failure_hint` 只认 `device offline/no devices`（真机 1.0.41 的原文是 `adb.exe: device 'X' not found`，匹配不上）、launch/deploy/DAP staging 同样只发裸文本，用户还得自己想起 `<leader>uA`。

**Implemented**
- `lua/utils/android_device.lua`：`is_gone_output`（纯函数，四种 adb 原文）、`report_if_gone`（提示 + 登记 `:UESetAndroidDevice` 为一次性修复，仍不改写 serial）、`check_async`（异步 `get-state`，仅给 UI 用）。
- install / launch / deploy / DAP attach staging 失败路径接入 `report_if_gone`；DAP 侧按 C10 拆成独立上报点（owner 由 `dap.android (staging transport)` 改为 `utils.android_device`，headline/remedy/fix 一并改），仍在 `report_failure` 内。
- `:UEDoctor` 新增异步设备存活行：target 字段可用 `check` 提供异步判定，通用 hub 渲染后原地重写该行（无 check 的行行为不变）。
- `docs/USER_GUIDE.md` 排障表补一行；spec 增加「已选设备不可用时必须提示重选」requirement 与场景。

**Validation**
- 全量回归 2390/2390 通过；`android_device` 17/17、`android_ide` 27/27、`ue_workflows` 25/25、`dap` 237/237、`host_resource_discipline` 13/13（新 spawn 站点已登记）、`structure` 78/78。

### 2026-10-02 — `UEAndroidIterate` 在步骤未启动时静默挂起

**Task**
- 用户：从实用角度继续找可改善点。

**Evidence**
- 复现：构建已在运行、未配置项目、平台选择取消、计划失败、终端未启动、设备选择取消、deploy 计划失败等路径都 `return` 而不调用 `on_exit`；循环既不报错也不更新状态栏（headless 复现：build 早退后 `ue_build_status` 仍为 nil）。

**Implemented**
- `lua/ue.lua` `build_target`：所有未启动路径调用 `on_exit(-1)`（仅链式调用方传 `on_exit`，直接命令行为不变）。
- `lua/ue/workflows/android/deploy.lua`：同样在未启动/设备选择取消/终端未启动时回报 `-1`。
- `lua/ue/workflows/android/iterate.lua`：`-1` 显示为「did not start」并标 `LOOP✗`。

**Validation**
- 全量回归 2385/2385 通过；`android_ide`、`ue_workflows`（新增取消选择与计划失败回报用例）、`stability`（ue.lua 10544 ≤ 10562）、`ue_api`、`ue_target_integration` 全绿。

### 2026-09-30 — 找回历史记录：按「用过」排序的搜索历史 + 统一历史入口

**Task**
- 用户：搜索历史很难找，要求举一反三。

**Evidence（本机实测）**
- 主搜索（csearch）picker 历史 249 条中 44 条是另一条的前缀（打字停顿被记下）；文件 picker 349 条中 179 条是前缀。历史没有「是否用过」「多久以前」「属于哪个项目」，各类历史分散在不同按键后面。

**Implemented**
- `lua/utils/history_hub.lua`（新）：只在**打开了结果**时记录查询（次数、最近时间、按项目分文件存于 `stdpath('state')/ue_search_history/`，上限 300，写入时才落盘，无定时器）；旧历史展示时去掉前缀与大小写重复。
- `lua/ue.lua` 主搜索 picker 的 confirm 先记录再跳转；`:UESearchHistory` 与 hub 类命令改由 `utils.ue_hub.setup_commands` 注册，`UEAndroidIterate` 移到 `lua/ue/workflows/android/iterate.lua`（经 `ue.workflows.bootstrap` 接入），使 `ue.lua` 回到行数 ratchet 之下（10538 ≤ 10562）。
- `lua/plugins/snacks.lua`：`<leader>sH` 改为「用过的在前（带 `3h ×2`）+ 清理后的旧记录」；新增 `<leader>fh` 历史中枢（搜索、上次结果、任意 picker、最近文件、跳转、命令行、通知、撤销树、旧 quickfix 列表、本文件 git 提交）。
- `docs/USER_GUIDE.md` 增加「找回以前做过的事」一节。

**Validation**
- 全量回归 2383/2383 通过。
- `android_ide` 21/21（前缀清理、计数与大小写合并、合并排序、按项目持久化、历史入口完整）；真实历史上清理 249 → 161 条；真实配置中 `<leader>sH`、`<leader>fh`、`:UESearchHistory` 已生效。

### 2026-09-30 — 键盘优先的 UE 工作流入口：命令中枢、目标切换、F5、状态栏、一键修复

**Task**
- 用户：使用体验距 IDE 差距大，按产品路线图全部推进；并纠正方向——尽量不用鼠标、不必对标 IDE UI，用快捷键呼出面板与状态栏提示。

**Implemented**
- `lua/utils/ue_hub.lua`（新）：`command_hub`（`<leader>P` / `:UEHub`，按组列出当前 target 的全部动作并显示快捷键）、`target_switcher`（`<leader>uu` / `:UETarget`）、`run_or_debug`（`<F5>`）、`offer_fix`/`run_fix`（`<leader>uk`）、`doctor`（`:UEDoctor`，✗ 行 `<CR>` 执行修复）、`debug_indicator`。
- target 专属数据归 owner：`ue.targets.android.hub(state)` 声明 Android 的动作、字段与循环命令；通用 hub 无 target 字面量。
- `lua/config/keymaps.lua`：`<F5>` 无会话时运行 target 循环、会话中 continue；新增 `<S-F5>` 停止（四模式）。
- `lua/plugins/statusline.lua`：mini.statusline 现在真正显示 `g:ueindex_status`（此前该状态只接在已禁用的 lualine 与启动前的原生 statusline 上，mini 接管后不可见）以及调试会话指示 `⏸/▶ DBG`。只读缓存值，无新定时器。
- `lua/utils/android_logcat.lua`（新）并接入 DAP logcat 面板：`<CR>` 跳到行内源码位置、`gl` 循环最低级别（由 adb 过滤）、`gx` 符号化最近崩溃、E/W 行高亮（buffer-local syntax）。
- 新增面向使用者的长期文档 `docs/USER_GUIDE.md`（日常流程、按键、状态栏读法、排障），README 中英文与 `docs/AGENTS.md` 已登记并写明维护约定。
- 失败带修复：Android DAP 的 `report_failure` 支持 `fix`，设备未选/进程未运行/lldb-server 失败会登记修复命令。
- `:UESetAndroidPackage` 无参数时打开设备包名选择器；`UEAndroidIterate` 把结果与耗时写入状态栏（`LOOP✓ 42s` / `LOOP✗`）。

**Validation**
- `android_ide` 16/16（hub 动作/分组/命令存在性、目标行、修复一次性消费、doctor、logcat 解析与 buffer-local 键）；`keymaps` 59/59、`commands` 121/121、`cheatsheet` 148/148、`ue_platform_boundary` 17/17。
- 真实配置启动冒烟：`<leader>P`/`uu`/`uk`/`<F5>`/`<S-F5>` 均已绑定，三个命令已注册，状态栏渲染含 UE 段，doctor 面板正常打开。
- 未做：真机上的 F5 循环与 logcat 交互未实测；布局预设、面包屑评估、Java/Kotlin LSP、性能分析入口未实现。

### 2026-09-30 — Android IDE 体验：异步调试路径、设备/包可见、崩溃符号化、一键迭代

**Task**
- 用户：以 Android 为主打造自己的 nvim IDE，按扫描出的改进计划全部推进。

**Implemented**
- 不卡界面：`lua/ue/dap/android.lua` 新增 `adb_async`/`adb_sequence`；attach 查 pid（`pidof_async`）、ASLR maps 读取（`read_so_base_hex_async`，attach 配置构建拆为 `M._finalize_attach_config`）、wait-for-debugger 的 force-stop/set-debug-app/start/clear、JDWP forward 全部改为异步。
- 设备/包可见：`utils.android_device.set(serial, device)` 记录机型标签并刷新状态栏；`ue.targets.android.status_token` 由 target owner 输出 `A:<机型>/<包短名>`，`ue.lua` 状态栏经 target driver 调用（无 target 字面量）。
- 包名选择：新增 `lua/utils/android_package.lua`（设备 `pm list packages -3` + 项目候选 + 手输兜底）；launch、logcat、DAP 在没有已知包名时用它代替空白 `vim.fn.input`，选择结果持久化到 `android_package`。
- 崩溃符号化：新增 `lua/ue/dap/_android_crash.lua` 与 `:UEAndroidCrash`（`<leader>uX`）：读 `logcat -b crash -d`，取最近一次崩溃，UE 模块帧用 `llvm-symbolizer`（经平台 `resolve_tool`，与 clangd 同目录）按 DAP 同一符号库选择链符号化，其余帧原样保留，进 quickfix。`ue.dap.resolve_android_dap_context`、`ue.dap.android.symbol_lib` 转为公开 API。
- 一键迭代：`:UEAndroidIterate`（`<leader>ux`）串联 SO 构建 → 快速部署 → wait-for-debugger 启动（`nodebug` 参数改为普通启动），任一步失败立即停止；步骤仍是各自 owner（K46）。部署工作流新增 `on_exit` 透传。
- 探针：`android-attach` 主题记录 attach 成功（是否有符号/rebase）与按层失败。
- 致命信号断点的「待验证」注释按引擎源码 `AndroidSignals.h` 核对后更正（见 spec 踩坑）。

**Validation**
- 新增 `tests/cases/android_ide_spec.lua` 8/8（崩溃帧解析用真机 `logcat -b crash` 格式、包选择、状态栏标签、target token）；`dap_spec` 新增异步 adb 用例 115/115。
- 真实工具验证：真机（ANDROID-SERIAL-B）崩溃缓冲解析出 7 帧；用 clang 生成的 aarch64 DWARF ELF 端到端跑 `llvm-symbolizer`，quickfix 得到 `sym.c:1 crash_here`。
- `commands` 118/118、`keymaps` 58/58、`cheatsheet` 145/145、`host_resource_discipline` 13/13、`ue_platform_boundary` 17/17、`structure` 78/78；并行全量 required-native 126/126 文件通过（152.3 s）。
- 未做：attach/launch/`UEAndroidIterate` 的真机端到端调试会话（本轮未连接调试会话验证）。

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
