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

## Unreleased

### 2026-08-14 — 将 macOS/iOS 开发链路安全整合到最新主线

**Task**

把当前 macOS/iOS 开发分支 rebase 到最新 `main`，保留主线的 project-bucket、多实例 writer
与 target matrix 契约，并确保公开 PR 不携带用户名、项目名、设备、签名或本机绝对路径。

**Implemented**

- 合并主线的 project-scoped state/lease 与本分支的 iOS target、AOT 复用、build monitor 和
  Neovide 适配；冲突按当前架构边界解决，没有恢复已退役的全局状态写法。
- iOS 增量脚本改为在项目内容目录下唯一发现 `ScriptAssemblies`，不再硬编码私有项目目录名；
  缺失或存在多个候选时 fail closed。
- 修复 POSIX wrapper CDB 从 staging 迁移到稳定目录时的路径重写、真实路径 canonicalization、
  macOS `xcrun` 编译 cursor shim 与测试侧 `python3` 发现。
- 修复多 Neovim 并发创建嵌套缓存目录的 `E739` 竞争，并强化 recent-project 异步重试与
  definition-cache 并发测试 flush，避免短命子进程退出前丢写。
- 测试夹具、发布记录和脚本说明统一改为合成示例；不记录私有项目、用户、设备、签名、SDK
  小版本、精确包体数量或耗时。

**Pitfalls / Gotchas**

- `mkdir(..., "p")` 在多个进程同时创建不同深度的同一目录树时，可能因中间父目录被抢先创建而
  抛出 `E739`，此时最终目标目录尚未出现，不能只检查一次 `isdirectory()`。
- Windows 风格反斜杠替换无法命中 macOS/Linux 生成的 wrapper CDB；稳定目录发布必须同时识别
  POSIX 与 Windows 两种路径拼写。
- rebase 后远端 feature branch 历史已变化，推送必须使用带 lease 保护的 force push。

**Validation**

- 定向：`index_generation` 16/16 passed；`multi_instance_state` 双路并发压力复跑均 11/11 passed；
  Python CDB 工具 `py_compile` passed。
- 全量：`nvim --headless -l tests/run.lua` 936/936 passed。
- 静态/规格：`lint_no_bare_globals` 135 files OK；三个新增 OpenSpec main specs 在官方 CLI 1.9.0
  下 strict validation 均 valid；`git diff --check` passed。
- 脱敏：公开 PR 新增行通过仓库 secret hook；私有用户名、项目名、域名、bundle、设备/签名、包号
  与本机绝对路径扩展扫描均为零命中，保留项仅为明确的合成测试 identity。

**Follow-ups**

- 物理 iOS 设备上的签名、安装、启动与增量动态库替换仍需在私有环境验证；公开记录不包含其输出。

### 2026-08-14 — 保留 project-bucket 升级前的 UE 索引与 CDB

**Task**

修复升级到 canonical project bucket 后，已有 checkout 的 `<Space>/` 因新 bucket 无 csearch index
而失效，并同时处置探针记录的 `active-compile-command-missing`。

**Implemented**

- `lua/ue.lua` 新增显式 pre-v4 engine-wide cache path model；迁移不再经当前 project-aware
  `cache_paths()` 错把新 bucket 当作 legacy source。
- `migrate_legacy_csearch_if_needed()` 先比较旧 state 与当前 bucket 的 canonical project key，
  只导入同一项目的 csearch snapshot、active-platform GTAGS、engine-root active CDB 与 controlled CDB state。
- 大型索引/CDB 通过同文件系统 hard link + 唯一临时名 + atomic rename 发布；保留旧路径供已运行的
  旧 Neovim 使用，并让并发 canonical writer 优先，避免 UI 主线程复制数百 MB/GB 文件。
- `tests/cases/grep_cache_spec.lua` 新增同项目导入、旧路径保留和异项目拒绝回归；
  `multi-instance-state-isolation` 主规格补齐旧工件迁移与身份隔离契约。

**Pitfalls / Gotchas**

- v4 的旧迁移函数仍调用 project-aware `cache_paths()`；项目被捕获后 legacy/active 实际指向同一路径，
  现有平台迁移测试未建立 project selection，因而没有覆盖这个确定回归。
- 当前实例位于另一个已有 engine checkout；先前 checkout 重建成功不能证明迁移正确，每个未导入的
  checkout 都会再次表现为 `<Space>/` 无 picker。
- `multi_instance_state` 与其他测试进程并行时会争用全局 probe 测试文件并出现 8→7；串行复跑
  11/11 通过，提交门禁继续使用仓库规定的串行全量入口。

**Validation**

- TDD：新增 legacy project-bucket 场景先稳定复现 `28/29`（迁移返回 false），实现后
  `grep_cache` 29/29 passed。
- 定向：`multi_instance_state` 11/11、`ue_project_context` 7/7、`ue_api` 54/54、`smoke` 18/18 passed。
- 真实实例：后台 `:UEPrepare` 生成 331,301,737-byte csearch index，`indexed=true`；
  `<Space>/` 等价搜索 `SubmitActiveCmdBuffer` 返回 34 个真实 csearch hits，preview window/buffer 均存在。
- 全量：`nvim --headless -l tests/run.lua` 808/808 passed。

**Follow-ups**

- 无。

### 2026-08-13 — 隔离多 Neovim 实例的 UE 状态与共享 writer

**Task**

审计当前配置中 process-global / project-scoped / user-global 状态，修复两个 Neovim 同时使用
同一 engine 时可能发生的项目/平台串扰、共享 JSON 丢更新与 cache writer 竞争。

**Implemented**

- 新增 `lua/ue/project_state.lua`：live project 与 target 捕获在当前 Neovim 进程；
  `selection.json` 只作为未来进程的启动默认；持久状态按 canonical uproject path 分 bucket，
  target platform/configuration 作为原子 pair，旧顶层 state 只读迁移。
- 新增 `lua/ue/file_lock.lua`：PID/token owner 的 filesystem lease、live-owner 拒绝、stale-owner
  回收与 token-checked release；UEPrepare、CDB pipeline、csearch、controlled semantic-index phase
  均增加跨进程 single-writer 门禁。
- `lua/ue.lua` / `ue.cdb.*` 将 active CDB、index scheduler/controlled CDB、clangd index/PCH
  放入 canonical project + platform 路径；CDB shard catalog 仅在同 project 内跨平台共享；
  project switch 只切换 live bucket，保留旧缓存。
- Android device 明确为当前 Neovim 进程内 `vim.g`；新增独立 child-process 回归，证明一个实例
  的 `:UESetAndroidDevice` 不会修改另一个实例。
- breakpoint persistence 改为 canonical project bucket，并在 lease 内合并当前打开 buffer 的改动；
  definition cache 改为 per-key atomic JSON，避免 shared monolithic JSON RMW 丢 key。
- probe、recent projects、watch dirty overlay 改为 lease 下重读+merge+atomic replace；csearch 成功后
  只退役 build-start captured dirty，保留其他实例新增或 build 期间再次修改的路径；
  `:UEPrepare!` 不再在 rebuild 成功前预清 dirty evidence。
- debug/grep/DAP protocol 日志改为 PID 路径；UE job log 增加 PID+hrtime；AI context 双文件导出
  由 lease 保护；content-addressed libclang cursor shim 先编译到 PID 临时文件再原子发布。
- 复扫发现 nvim-dap 上游 logger 仍以 `w+` 打开固定 `dap*.log`；新增
  `workarounds.dap.pid_scoped_logs` 在 dap 加载前统一插入 PID，`:UEDAPDiag` 改读当前
  PID 的 nvim-dap / protocol / breakpoint 诊断日志。
- 新增 `openspec/specs/multi-instance-state-isolation/spec.md`，同步约束、架构、测试映射、Android
  device/UE search 主规格与中英文使用文档。
- OpenSpec main specs 已直接同步当前实现。两个旧 active change 未污染主规格：
  `android-dap-platform-walkthrough` 保留已被证伪路线的未完成任务，
  `add-architecture-boundary-regression` 保留未拍板的 DRAFT；两者脱敏后归档到
  `openspec/changes/archive/2026-08-13-*`，均明确记录为 archive-without-sync。

**Pitfalls / Gotchas**

- `vim.g` 只在一个 Neovim OS process 内“全局”，不会跨实例；真正的串扰来自旧的 engine 顶层
  `state.json` 和共享 cache 文件，而不是 `vim.g.ue_android_device_serial`。
- 单次并发测试曾复现偶发丢 key，复跑变绿不能证明修复；definition cache 最终改为一 key 一文件，
  5 轮连续 8-writer 压测才稳定全绿。
- 只给最终 JSON 做 atomic rename 不能阻止 stale read-modify-write；共享集合必须在 lease 内重读并
  merge，独立字段/key 则应从结构上拆文件。
- csearch 增量路径旧实现先写固定 `csearch_incremental.txt` 再拿 writer slot，失败实例可能删除
  正在被另一实例读取的清单；现在顺序固定为先拿跨进程 lease，再生成唯一临时清单。
- 只扫自己写的日志不够；nvim-dap 的固定路径由上游 logger 内部生成，需在
  `require('dap')` 之前改写 logger filename，否则首次 `w+` 已经造成截断。

**Validation**

- 并发：`multi_instance_state` 11/11 passed；其中 definition-cache 8 writers 连跑 5 轮均通过，
  project/target/probe/recent/dirty/lease child-process 用例全绿。
- 定向：`grep_cache` 27/27、`ue_watch_csearch` 13/13、`csearch_build_guard` 21/21、
  `ue_cdb` 17/17、`index_generation` 16/16、`android_device` 14/14、`dap` 56/56、
  `ue_project_context` 7/7、`ue_context` 3/3、`ue_api` 54/54、`smoke` 18/18、
  `utils` 46/46、`probe` 19/19、`theme` 11/11、`cpp_semantic_sidecar` 15/15、`structure` 38/38。
- 静态/规格：`lint_no_bare_globals` 119 files OK；5 个受影响 OpenSpec main specs strict validation
  均 valid；`git diff --check` passed。
- nvim-dap 真实加载实验：`dap.log.create_logger('dap.log'):get_path()` 返回
  `.../dap.<pid>.log`；`workarounds` 15/15、`dap` 56/56、`smoke` 18/18 passed。
- OpenSpec：当前五个受影响 main specs strict validation 均 valid；归档前
  `android-dap-platform-walkthrough` strict valid；`add-architecture-boundary-regression` 按其
  DRAFT 状态保留“无 delta section”验证失败，未伪造完成状态。
- 全量：`nvim --headless -l tests/run.lua` 806/806 passed。

**Follow-ups**

- 无。

### 2026-08-13 — 为当前 Neovim 窗口设置会话名称

**Task**

为并行工作的 Neovim/Neovide 窗口提供可辨识的系统标题，并保留一键恢复自动标题的路径。

**Implemented**

- 新增 `lua/utils/window_title.lua`，提供 `set` / `reset` / `prompt` / `setup`，名称只作用于当前会话；`%` 按字面转义，C0/DEL 控制字符被清理，长度限制为 80 个 Unicode 字符。
- 新增 `:WindowTitle [name]`、`:WindowTitle!`、`:WindowTitleReset`；无参数打开输入框，确认空值恢复自动标题，取消不改变已有标题。
- `lua/config/keymaps.lua` 新增 `<leader>uW` 输入入口；浮动 cheatsheet、Markdown 速查和 keymap/command 主规格同步该行为。
- 新增 `tests/cases/window_title_spec.lua`，并将新模块加入测试范围映射；现有 keymap/command 冻结回归同步更新。

**Pitfalls / Gotchas**

- `'titlestring'` 使用 statusline 语法，原样写入 `%{...}` 会被求值；实现必须双写 `%`，不能只做终端控制字符过滤。
- `titlestring=""` 且 `title=true` 才是 Neovim 的自动标题；reset 不应关闭 `'title'`。

**Validation**

- TDD 红灯：新增 `window_title` spec 后因 `utils.window_title` 尚不存在而按预期失败；实现后 `window_title` 7/7 passed。
- 定向：`keymaps` 54/54、`commands` 92/92、`cheatsheet` 126/126、`structure` 38/38 passed。
- 静态/规格：`lint_no_bare_globals` 116 files OK；`openspec validate keymap-command-regression --type spec --strict` valid；`git diff --check` passed。
- 全量：`nvim --headless -l tests/run.lua` passed。

**Follow-ups**

- 无。
### 2026-08-12 — Restore complete IOS/Metal clangd compilation evidence

**Task**

- Fix the incomplete IOS semantic parse after a successful MetalRHI build and `:UEPrepare`, without changing project or engine source/configuration.

**Implemented**

- Stopped recursively discovering arbitrary nested `compile_commands.json` files; the previously published three-entry database was an LLVM Python test fixture under `Engine/Source/ThirdParty`.
- Added root-ownership and IOS compiler-evidence validation before any existing CDB can replace the canonical database.
- Added an IOS target-driver `semantic_cdb` plan. After `:UECompileForNvim` builds successfully, it runs UBT `GenerateClangDatabase` with `-NoExecCodeGenActions` in the existing build terminal, validates the full tuple, atomically publishes it under `.cache/nvim-ue/cdb/sources/<tuple>/`, and then invokes the existing prepare-only pipeline.
- Prioritized that tuple-owned source over derived canonical mirrors, required every IOS entry to match the active target/configuration, and carried source-publication state into the pipeline so an unchanged post-process still restarts clangd. This fixes `gd` on macros such as `CompiledMetalFx` remaining attached to the previous three-entry database.
- Kept `:UEPrepare` read/transform-only: it can consume response files or a validated tuple-scoped source but never invokes UBT, Cook, Package, Deploy, or Run.

**Pitfalls / Gotchas**

- `MetalRHI` belongs to the IOS game/client target and is covered. `MetalShaderFormat` is a host-side developer/editor module and is intentionally not mixed into the device-target database.
- The host-provided Apple clangd remains below the repository's pinned LLVM clangd 22.1.x contract; accurate CDB coverage and clangd compatibility are separate gates.

**Validation**

- A sanitized local `SampleGame / IOS / Development` probe produced a tuple-complete database covering the target's MetalRHI sources without Cook, Package, or compile actions.
- The final canonical CDB retained complete IOS compiler evidence and rejected all foreign fixture entries; project-specific entry counts and timings are intentionally omitted.
- Focused headless regressions: `ue_cdb` 24/24, `ue_target_drivers` 31/31, `ue_target_integration` 10/10, plus real init startup passed.
- Full headless regression: `nvim --headless -l tests/run.lua` — 855/855 passed.

### 2026-08-11 — Shorten local iOS C++ iteration without touching the project

**Task**

- Apply the iOS build-time improvements that can live entirely in Nvim/scripts, with local packaging explicitly reusing cooked data and never cooking.

**Implemented**

- Wrapped native IOS `Build.sh` in a macOS zsh helper that fingerprints AOT DLLs, runtime inputs, AOT tools, postprocessing code, SDK/toolchain identity, and the adapter build file.
- Injected `bSkipAOTProcess=true` only after a prior successful build published a matching manifest and every recorded framework path and content hash still match; cache misses clear inherited AOT skip/disable variables and run the full process.
- Added stable command-line INI overrides that suppress automatic dSYM generation/bundling during daily C++ builds.
- Changed `:UEPackageIOS` to `-skipbuild -skipcook -stage -nocleanstage -package -nodebuginfo`, removing local build/cook/archive/deploy/run stages.
- Added `:UEIOSSymbols` to run `dsymutil` only when needed, print binary/dSYM UUID evidence, and reject mismatches without producing a ZIP.

**Pitfalls / Gotchas**

- The first build, any input/toolchain change, or any missing recorded framework intentionally pays the full AOT cost; the cache fails closed rather than guessing freshness.
- `-nocleanstage` is a local C++ iteration optimization. A release/distribution pipeline remains responsible for a clean content build outside this command.
- These changes write only engine `.cache/nvim-ue` state and normal build outputs; no project or engine source/config file is modified.

**Validation**

- Focused: `ue_target_drivers` 28/28, `ue_target_integration` 9/9, `ue_target_tasks` 4/4, `platform` 22/22, `commands` 95/95, `ue_api` 55/55, `smoke` 18/18, `structure` 39/39, and `ue_ios_cpp_iteration` 3/3 passed.
- Full: `nvim --headless -l tests/run.lua` — 843/843 passed.

### 2026-08-11 — Show silent UE build activity in the existing terminal

**Task**

- Keep `<leader>ub` build diagnostics inside its existing terminal window instead of opening a separate monitor view.

**Implemented**

- Added a macOS-owned process snapshot capability using native `/bin/ps`; Windows and Linux drivers do not pretend to support it.
- Added an asynchronous, build-scoped process-tree monitor that identifies the active child tool/file, CPU use, elapsed time, process count, and the two preceding stage observations.
- Rendered the heartbeat as terminal-buffer virtual lines, preserving the real UBT output, terminal stdin, exit code, and quickfix behavior.
- Bound monitor startup/cleanup to the existing `termopen` job, including job exit and terminal-buffer wipeout.

**Pitfalls / Gotchas**

- This exposes activity while a child process buffers its own output; it cannot recover log lines that the project process has not emitted.
- The process snapshot capability is intentionally macOS-only until another host receives its own native driver implementation.

**Validation**

- Added parser, descendant filtering, active-stage selection, lifecycle, same-buffer virtual-line, platform ownership, and UE terminal integration regressions.
- Real macOS terminal probe observed `[UE heartbeat] ... sleep ...` from a live child process and cleaned it up without touching terminal output.
- Focused: `ue_build_monitor` 7/7, `platform` 22/22, `commands` 94/94, `ue_api` 55/55, and `smoke` 18/18 passed.
- Full: `nvim --headless -l tests/run.lua` — 836/836 passed.

### 2026-08-11 — Clear LazyHealth package-provider warnings

**Task**

- Resolve all current `:checkhealth lazy` errors and warnings.

**Implemented**

- Disabled Lazy's unused LuaRocks/hererocks provider because no configured plugin requires LuaRocks.
- Removed the empty legacy `site/pack/core/opt` directory that Lazy reported as an existing package root.

**Pitfalls / Gotchas**

- Installing hererocks would add an unused second Lua runtime without helping any current plugin.
- The legacy package path was verified empty before removal.

**Validation**

- `:checkhealth lazy` — 0 errors, 0 warnings.
- Focused: `core_health` 28/28 passed.
- Full: `nvim --headless -l tests/run.lua` — 828/828 passed.

**Follow-ups**

- Re-enable `rocks` only if a future plugin explicitly requires LuaRocks.

### 2026-08-11 — Expose Neovide and restore native Open Folder

**Task**

- Make the installed Neovide app callable from zsh and add the missing `o` Open Folder action on the macOS Neovide dashboard.

**Implemented**

- Added the Neovide app-bundle CLI directory to the login zsh PATH.
- Added a macOS-owned native folder-picker plan and an async Neovide handoff that changes cwd before opening the Snacks file picker.
- Added one idempotent dashboard `o` entry, visible only in Neovide on macOS; native dialog cancellation is a silent no-op.

**Pitfalls / Gotchas**

- `/Applications/Neovide.app` was already installed; Homebrew did not expose its bundled executable on PATH.
- Native AppleScript selection remains in the macOS host driver rather than leaking into the dashboard/plugin layer.

**Validation**

- Focused: `neovide` 3/3, `platform` 21/21, and `smoke` 18/18 passed.
- Full: `nvim --headless -l tests/run.lua` — 828/828 passed.

**Follow-ups**

- None.

### 2026-08-11 — Make host, target, and shell compatibility explicit

**Task**

- Audit and correct platform adaptation across iOS/Android/Win64/Mac/Linux targets, macOS/Windows/Linux hosts, and PowerShell/cmd/POSIX shells.

**Implemented**

- Added a central host-target-operation matrix and filtered target selection, lifecycle planning, runtime launch/log routing, and DAP registration through it.
- Added target-owned runtime strategies so generic launch/log modules no longer dispatch on hard-coded target names; kept IOS, Mac, and Android implementations independent.
- Added a host-neutral shell argv/quoting layer; moved PowerShell launch/log/debug-output behavior into Windows or Android-Windows adapters and removed PowerShell/cmd assumptions from macOS paths.
- Made CDB phases sequential argv jobs, skipped the Windows-only PCH generator on non-Windows hosts, preserved UNC/POSIX URIs, and delegated PCH execution to the Windows host driver.

**Pitfalls / Gotchas**

- An importable target module is not evidence that its operation can execute on the current host. iOS DAP remains explicitly unavailable and never falls back to Mac attach.
- Windows argv conversion must distinguish host filesystem paths from Unreal object paths such as `/Game/Maps/Main`.

**Validation**

- Focused: `platform`, `ue_target_drivers`, `ue_target_integration`, `ue_cdb`, `dap`, `android_device`, `task_registry`, and `commands` passed.
- Full: `nvim --headless -l tests/run.lua` — 824/824 passed.

**Follow-ups**

- On-device iOS build/install/launch and native Windows/Android execution remain environment-dependent verification lanes.

### 2026-08-11 — 同步并归档已完成的任务管理与 Android F9 规格

**Task**

收尾两个长期处于 complete 状态的 OpenSpec change，使已落地行为进入主规格并清理 active change 列表。

**Implemented**

- 新建 `openspec/specs/task-management/spec.md`，同步 `ue-task-manager` 的 11 条任务注册、派生状态、取消、picker/命令、statusline 与竞态消除要求。
- 新建 `openspec/specs/android-f9-breakpoint-hit/spec.md`，同步 Android F9 单一 owner、端到端命中、LLDB 证据、address 等价与诊断要求。
- `android-dap-attach` 主规格已经完整覆盖 delta，且包含后来落地的全局 serial 与 live F9 更强合同；同步保持当前主规格，没有用旧 delta 降级。
- 将 38/38 tasks 完成的 `ue-task-manager` 归档至 `openspec/changes/archive/2026-08-11-ue-task-manager/`，将 31/31 tasks 完成的 `fix-android-f9-breakpoint-hit` 归档至 `openspec/changes/archive/2026-08-11-fix-android-f9-breakpoint-hit/`。

**Pitfalls / Gotchas**

- delta 是变更当时的意图，不是覆盖当前主规格的快照；Android attach 主规格已演进到“不重连即时生效”，因此只核对 requirement/scenario 覆盖，不反向恢复旧的“提示手动 reattach”终态。
- 本次搜索/cheatsheet 改动没有对应 active change；不得为了执行 archive 指令而擅自归到两个无关历史 change 中。

**Validation**

- tasks 审计：`ue-task-manager` 38/38、`fix-android-f9-breakpoint-hit` 31/31，均无未完成项；artifacts 均为 done。
- requirements 交叉检查：`task-management` 11/11、`android-f9-breakpoint-hit` 6/6、`android-dap-attach` 2/2，无缺失。
- `openspec validate ue-task-manager|fix-android-f9-breakpoint-hit --strict`：归档前均 valid；`task-management` 与 `android-f9-breakpoint-hit` 主规格 strict validation 均通过。
- `nvim --headless -l tests/run.lua`：776/776 passed；公开仓库已知 serial/package/user-profile/private-key/API-secret 扫描 0 命中，`git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-08-10 — 让快捷键帮助可以按键位实时搜索并保留分类

**Task**

回归 `<leader>?` 的快捷键入口与界面信息架构，让 `wW`、`aA` 这类成对大小写键位无需猜 tab，输入后立即找到对应操作和原始分类。

**Implemented**

- `lua/utils/cheatsheet.lua` 新增 `/` 实时搜索和 `<C-l>` 清除筛选；匹配覆盖键位、说明、tab 与 section，并按相关度排序。
- 搜索结果继续以 `Tab › Section` 分组；`wW` 顶部命中 `Basics › Motions` 的 `w / W`，`aA` 顶部命中 `Basics › Modes` 的 `a / A`。
- 将 word/WORD motions 与 insert-entry modes 改成逐动作的大小写成对展示，空格包围的展示分隔符不参与精确键位匹配，实际 `/` 键仍可搜索。
- `tests/cases/cheatsheet_spec.lua` 新增全表可发现性/分类审计及真实 `/wW<CR>`、`/aA<CR>` 浮窗交互；`tests/cases/keymaps_spec.lua` 锁定 `<leader>?` → `UECheatsheet`。
- `openspec/specs/keymap-command-regression/spec.md` 与 `docs/ue_lazyvim_cheatsheet.md` 同步搜索及分类合同。

**Pitfalls / Gotchas**

- Snacks 的 keymap picker 只看实际映射，无法覆盖 `w/W/a/A` 等 Vim built-in；因此入口必须基于 cheatsheet 的完整教学数据，而不是复用 `<leader>sk`。
- 普通 lowercase 搜索会把 `wW` 折叠成 `ww`；只有先把 `w / W` 这类展示分隔符归一化，才能既保持大小写不敏感又命中成对键位。

**Validation**

- TDD 红灯：`nvim --headless -l tests/run.lua cheatsheet` 初始 `119/124`，5 条搜索/分类合同按预期失败。
- 定向：`cheatsheet` `126/126`、`keymaps` `53/53`；真实按键输入后 extmark 可见内容包含预期 `Tab › Section` 与键位。
- 静态/规格：`lint_no_bare_globals` 115 files OK；`openspec validate keymap-command-regression --type spec --strict` PASS；`git diff --check` PASS。
- 全量：`nvim --headless -l tests/run.lua` `776/776` PASS。

**Follow-ups**

- 无。

### 2026-08-10 — 让 `<Space>/` 默认真正 literal，并让每条结果都可预览

**Task**

修复默认搜索单个 `.` / `/` 不启动、literal 命中在 preview 中仍像 regex 一样高亮，以及按文件插入
synthetic header 导致结果分类重复、首项和大量列表项没有真实源码预览的问题。

**Implemented**

- `lua/utils/code_search/init.lua` 的 literal quote 改为与 RE2 `regexp.QuoteMeta` 一致，只转义真正
  metacharacter；`/`、`-`、`%` 保持字面值。
- `lua/ue.lua` 允许默认 literal 模式下的单字符标点搜索，同时继续拦截单字符 identifier 和单字符
  regex；literal hit 写入精确 `end_pos`，Snacks preview 不再用 raw 输入二次执行 Vim regex。
- 删除可选中的 synthetic file-header item。csearch 按文件流式输出时仅缓冲当前文件，给真实命中标注
  Project / Engine / Workspace、相对路径、组内序号与命中数；首行承担分组标题但仍是实际命中，后续行
  保留缩进层级，因此任意结果都能 preview/confirm 到准确位置。
- picker 标题明确显示 `[scope: all]` 或当前模块/plugin scope；literal 与 regex 分别显示 `L` / `R`。
  `docs/ue_lazyvim_cheatsheet.md` 同步修正 visual toggles 与旧的 inline-rg-flags 误导。

**Pitfalls / Gotchas**

- backend 已按 literal 转义并不等于整个 UI 是 literal：Snacks 在没有 `end_pos` 时会把
  `filter.search` 再交给 `vim.regex`，所以 `.` 的结果集合正确但 preview 高亮仍像“任意字符”。
- synthetic header 看似能分组，但它也是 picker selection；初始项必落 header，单命中文件又让约一半
  列表项没有真实 match preview。分组信息必须附着在真实 hit 上。

**Validation**

- 真实 csearch 小索引证明 `/` 与 `\\/` 都只命中字面 slash，`\\.` 只命中字面 dot，`.` regex
  会扩展到任意字符；实现回归锁定 RE2 quote 集和 literal exact span。
- `grep_cache` 27/27、`utils` 46/46、`ue_api` 54/54、`smoke` 18/18、`commands` 90/90 passed。
- `openspec validate ue-code-search --type spec --strict` passed；
  `nvim -l scripts/lint_no_bare_globals.lua lua` 115 files OK；全量回归 768/768 passed。

**Follow-ups**

- 无；保留 `:UEGrepGroupingToggle` 作为 structured presentation 的诊断 A/B 开关。

### 2026-08-10 — Root 设备可显式选择可回滚的 app 私有 SO 注入

**Task**

在不修改已安装 APK/native library 的前提下，为 root 调试设备提供显式的 app 私有 SO 验证路径，
同时保留既有 root 原子替换作为默认行为。

**Implemented**

- `scripts/ue_android_so_deploy.ps1` 新增 `-PreferRunAs`；仅在显式传入时优先选择
  `run-as/startup-agent`，未传入时的 root/run-as 自动选择顺序不变。
- `tests/fixtures/android_so_deploy/run_as_transport_spec.ps1` 固定默认选择前提，并新增
  root-capable 场景的显式 run-as 选择合同，禁止该路径探测或使用 root transport。

**Pitfalls / Gotchas**

- app 私有 SO 能发布并被 `/proc/<pid>/maps` 证明已映射，不代表它与已安装 APK 的 Java/JNI
  基线兼容。实机运行在 `GameActivity.getDid()` 上得到 `NoSuchMethodError`，随后 ART 因 pending
  exception 中的 JNI 调用中止；该失败不能归因于 VRS 或锁屏。
- 作用域错误留底：用户已要求 SO-only 后，“编一下再试试”只能重编/部署 SO；本次错误地把 JNI
  mismatch 扩成 APK 打包并执行 `adb install -r -d`。今后版本不兼容只能 fail closed，禁止把它
  当成打包/装包授权；必须等用户明确说“打包/装包”。
- 设备 `versionCode=176314399`，本地 build metadata 已被中止的 package flow 改写为 `1`；
  warning-only 的 app 私有路径只证明 transport 可用，不能绕过版本/JNI 兼容性验证。

**Validation**

- fixture `run_as_transport_spec.ps1`：PASS；`nvim --headless -l tests/run.lua ue_api`：54/54 passed。
- 实机 `<PRIVATE_IP>:43581` preflight 证明选择 `run-as/startup-agent` 且不改变设备状态；实际发布后
  maps 证明只映射 app 私有 SO。失败后只删除本次 347 MB staging 目录，已安装 `libUE4.so`
  SHA-256 仍为 `e26864ba506d0bdeb46d3678b611917bb708fd4cb099fc8a4f606cc09e447dfe`；
  不带 agent 的 15 秒 control launch 保持前台存活。
- 新 SO 日志证明设备支持 `VK_KHR_fragment_shading_rate`（`pipeline=1, rates=7`）；因 JNI 中止发生在
  PSO 创建前，尚未证明 fixed-VRS PSO 的 `2x2` 执行路径。

**Follow-ups**

- 取得与 native build 同基线、包含 `GameActivity.getDid()` 且版本匹配的 APK 后，再验证
  `r.Mobile.OnePassShadowMask.ShadingRate=2` 与 `fragmentSize=2x2` PSO 日志。

### 2026-08-08 — 让 C++ `gd` 从 canonical entity 完整到达唯一函数体

**Task**

修复 overload、头文件 declaration 与 derived virtual call 已取得正确实体身份却仍停在声明处的问题；
建立不依赖名称/arity/path ranking 的完整语义链，并以真实 Android Vulkan 源码验证。

**Implemented**

- source/header 都先以 active CDB 或 compiler-emitted origin evidence 建立不可变 transaction，在
  proven TU 的 exact cursor 取得 libclang canonical USR；异步 provider 只能使用 snapshot 的
  URI/position/version，stale 响应没有 UI 副作用。
- `lookup-definition` 使用同 generation 的 controlled current→hot→full CDB，在 subject module 的
  compiler-authored UBT unity / exact fallback AST 中按相同 USR 找唯一 body。LuaJIT 无法可靠传递
  by-value `CXCursor` callback，因此按 LLVM toolchain + source hash 懒编译最小 C ABI shim；shim
  复用当前 libclang/TU，不加载第二份库、不重新 parse，超长路径/overflow/零或多个 body 均 fail closed。
- resolved cache 只绑定 canonical USR、CDB signatures、overlays 与 toolchain；同一实体换调用点/声明可
  复用，negative/ambiguous 结果不跨 subject 缓存。新增 `:UEDefExplain`、稳定 stage/reason 和失败/
  性能 probe，保留 150ms 可取消进度与 stale gate。
- current/hot/full 改为 generation manifest + coverage-superset selector；clangd 固定
  `--enable-config=false`，打开文件 exact argv/cwd 经官方 `compilationDatabaseChanges` 传输。
  不再写 `.clangd` 或把 `External.File`/`--index-file` 当 definition authority；受控 CDB 只接受
  active build 的真实 UBT unity membership，无法证明时保留 exact per-file TU。
- 为保持 800 行结构门禁，将 generation、C++ navigation coordinator、module definition lookup 分拆为
  `_generation.lua`、`semantic_navigation.lua`、`semantic_sidecar_definition.lua`；入口 API 与非 C++
  cache/LSP/csearch/GTAGS compatibility path 不变。

**Pitfalls / Gotchas**

- `clangd-indexer` YAML 记录 `.cpp` Definition 不代表 monolithic External index 的 LSP definition
  会返回 body；真实实验仍只到 declaration，故该路线已证伪。
- 人工跨 module/same-module argument union 会产生真实 Clang diagnostics；只有 UBT 自己写出的 unity
  wrapper + 匹配 `.o.rsp` 是可接受 membership evidence，不用 workaround 掩盖 parse error。
- 默认 `max_tus=1` 下真实 4-wrapper module lookup 的三个 cold USR 各约 29–31 秒，sidecar RSS
  1797–1818 MiB；这是已记录的冷路径成本。同一 canonical USR 的下一 subject 为 0ms，不通过并发
  多个大 TU 换速度。

**Validation**

- 真实 Android Vulkan 只读 smoke 6/6 PASS：二参数 `SubmitActiveCmdBuffer` call/declaration 都到
  `VulkanCommandBuffer.cpp:645`；无参 overload 都到 inline `VulkanCommandBuffer.h:421`；
  `FVulkanCommandListContext&` call 与 `final override` declaration 都到 `VulkanCommands.cpp:1098`。
  三组 canonical USR hash 互异、组内一致，shim ABI=1、`tu_count=1`；未写引擎/项目源码，未访问设备。
- 聚焦回归：`cpp_semantic_context` 11/11、`cpp_semantic_client` 15/15、
  `cpp_semantic_sidecar` 15/15、`cpp_semantic_transaction` 5/5、`ue_goto_behavior` 7/7、
  `index_generation` 15/15、`clangd_commands` 2/2、`cpp_semantic_index` 1/1、`ue_api` 54/54、
  `utils` 45/45、`stability` 9/9，全部通过；Python 生成器 syntax compile 通过。
- `openspec validate make-cpp-gd-semantically-complete --strict` passed；新增/修改行脱敏扫描 clean。
- 全量 `nvim --headless -l tests/run.lua`：765/765 passed。

**Follow-ups**

- cold module parse 的 29–31 秒与约 1.8 GiB RSS 是剩余性能边界；后续优化必须保持 canonical-USR
  authority、真实 compile context 与 fail-closed 合同，禁止回加 symbol/arity/path ranking。

### 2026-08-07 — 关闭 build terminal 不再终止 `<Space>us`

**Task**

修复 `<Space>us` 偶发以 exit code 143 结束的问题，并让 Android build preflight 只报告真实发生的 DAP 清理。

**Implemented**

- 运行中的 UE build terminal 使用 `bufhidden=hide`；关闭窗口只隐藏输出 buffer，不再 wipe buffer 并向
  PowerShell/UBT 发送终止信号。任务退出后恢复 `bufhidden=wipe`，保持既有的已完成 terminal 清理语义。
- Android DAP cleanup 仅在确有 active DAP session 时返回 `adapter_killed=true`，空闲状态的 `<Space>us`
  不再错误提示 “stopped lldb-dap adapter”。
- 增加 terminal 生命周期与 DAP cleanup 结果回归，防止重新引入关窗即取消和虚假清理提示。

**Validation**

- 历史 `nvim-debug.log` 记录 `<Space>us` exit 143；独立 terminal 实验复现 `bufhidden=wipe` 在 buffer
  删除时稳定返回 143。
- 使用当前真实 Android Development build state 完整执行两阶段 action graph：两阶段均 exit 0，
  `Target is up to date`，未进入 Gradle/APK/ADB。
- 真实 `:UEBuildAndroidSO` 启动后立即关闭 terminal：buffer 仍有效、job 仍运行，最终 `status=BOK`、exit 0；
  退出后 `bufhidden` 恢复为 `wipe`，且不再虚报停止 lldb-dap adapter。
- `ue_api` 56/56 passed；`dap` 56/56 passed。
- `openspec validate android-so-quick-deploy --type spec --strict` passed；全量
  `nvim --headless -l tests/run.lua` 729/729 passed。

### 2026-08-07 — 以实测能力而非 Android API 白名单选择 startup-agent transport

**Task**

修复 `<Space>uq` 在具备所需能力的 Android 15 / API 35 设备上被 `sdk == 34` 旧验证门禁提前拒绝的问题。

**Implemented**

- `ue_android_so_deploy.ps1` 与 `ue_android_so_launch.ps1` 不再把 Android API 精确版本当作 transport
  能力；继续 fail closed 检查 package `DEBUGGABLE`、`run-as` UID、ActivityManager
  `--attach-agent-bind`、设备/app ABI 以及发布 generation 的 identity/hash。
- startup agent 的 ClassLoader 错误与注释改为描述所需运行时契约，不再错误声称该契约只属于 API 34。
- 主 spec 将 app-private staging 前置条件改为可观测 capability；fixture 使用 API 35 锁定未来版本不会因版本号
  被拒绝，同时保留“缺少 attach-agent-bind 必须拒绝”的负例。

**Validation**

- PowerShell 5.1 `run_as_transport_spec.ps1`：API 35 capability-positive 与 capability-negative 用例通过。
- PowerShell 5.1 `startup_agent_spec.ps1`：deploy/launch/agent contract 通过，精确 API 34 门禁被列为禁止模式。
- `ue_api` 55/55 passed；`openspec validate android-so-quick-deploy --type spec --strict` passed。
- 全量 `nvim --headless -l tests/run.lua`：727/727 passed。
- 指定唯一设备的只读 preflight 未执行：验证时 ADB 返回 `device not found`；未切换到其他设备，
  未执行 staging、force-stop 或启动。

### 2026-08-06 — 在非 root 设备保留原签名并以 ClassLoader generation 替换 SO

**Task**

让已安装且自身 debuggable 的 APK 在 production user / 无 `su` 设备上复用原签名与安装数据，直接消费
app-private 新 SO；不修改引擎、项目源码、APK 或 `/data/app`。

**Implemented**

- `ue_android_so_deploy.ps1` 在 root 不可用时验证 package `DEBUGGABLE`、`run-as` app UID、
  `--attach-agent-bind`、API 34、设备 ABI 与 app `primaryCpuAbi=arm64-v8a`；源 SO 同时校验
  ELF64/AArch64 与 `DT_SONAME=libUE4.so`。
- `ue_android_so_agent.c` 以 startup JVMTI `ClassPrepare` 找到原本精确解析到 installed `libUE4.so` 的
  app ClassLoader，调用 `addNativePath` 并把新增 native path element 移到首位；原项目
  `System.loadLibrary("UE4")` 仍走 ART nativeLoad、原 linker namespace 与正常 `JNI_OnLoad` 路径。
- 非 root 发布改为唯一 generation：SO、agent 与 hash manifest 全部验证后才原子切换 `current` pointer；
  `ul` 会实际复算两个文件 hash。manifest 记录 installed versionCode 及 APK lastUpdateTime/path/stat 摘要，
  同 versionCode 重装或 APK 文件身份变化也会在启动前拒绝。
- `uq` 与 `ul` 对同一 serial/package 共用 Windows OS mutex；并发操作直接拒绝，异常进程退出后不留锁文件。
- `ue_android_so_launch.ps1` 只在工具目录完全不存在时走普通 APK 启动；partial generation、损坏 manifest
  或 baseline 漂移一律 fail closed。attach 后失败会 force-stop 并有界确认错误进程已退出。
- agent/host 都解析 `/proc/*/maps` pathname 后精确比较（允许 ` (deleted)`），不再用 substring；agent 在
  私有 SO 映射后继续监控 installed SO。状态改称 `mapped`，不冒充 `JNI_OnLoad` / 引擎初始化已返回。
- 删除了要求重签/重装的 wrapper baseline 路线和相关入口；运行时代码与 fixture 不保存现场包名、项目名或
  设备序列号，测试身份全部为虚构值。

**Pitfalls / Gotchas**

- 预先 `dlopen` 私有 SO 不能替代 Android 14 `Runtime.loadLibrary0` 的 ClassLoader 绝对路径解析，也不能
  代替 ART 的 native-library bookkeeping；晚注册 `NativeMethodBind` 又不会回放 zygote 期已有绑定。
- “data unchanged” 是不准确表述：该方案会更新工具自有 `code_cache/nvim-ue-so`；准确边界是 APK、签名、
  `/data/app` 与工具目录之外的既有业务数据不变。
- 修正上一条日志中“production user build 只能 root”的过度结论：设备全局不可调试不等于已安装 APK
  不可调试；现有 APK 自带 `DEBUGGABLE` 且具备 `run-as` / attach-agent-bind 时存在非 root 官方能力路径。

**Validation**

- PowerShell 5.1：startup-agent、root transport、run-as transport 三个 fixture 全部通过；额外独立实验
  证明同名 OS mutex 能跨两个 PowerShell 进程互斥。
- `ue_api` 55/55 passed；`openspec validate android-so-quick-deploy --type spec --strict` passed。
- agent 以 NDK clang `-std=c11 -Wall -Wextra -Werror` 成功交叉编译；`llvm-readelf` 证明产物为
  ELF64/AArch64、SONAME `libnvim_ue_so_agent.so`，依赖仅 `libdl` / `liblog` / `libc`。
- 唯一允许测试的已连接设备只执行显式 serial 的只读 preflight：确认 Android 14/API34、arm64、
  debuggable `run-as` 与 attach-agent-bind transport，输出 `no device state was changed`。
- 全量 `nvim --headless -l tests/run.lua`：727/727 passed。

**Follow-ups**

- 设备仍在使用，本轮没有执行真实 `uq` staging、force-stop 或 `ul` 启动；最终端到端 maps / 引擎存活证据
  留待设备可动时，只能在用户指定的唯一 serial 上执行。

### 2026-08-06 — 按设备能力选择 Android SO root transport

**Task**

修复 `<Space>uq` 把 root 执行写死为 `su 0`，导致无 `su` 设备在部署前抛出底层 shell 错误的问题。

**Implemented**

- `scripts/ue_android_so_deploy.ps1` 新增 `Resolve-RootTransport`：先验证 direct `adb shell id -u`，再验证 `su 0 id -u`，只接受明确返回 UID 0 的 transport。
- 新增 `Invoke-AdbRoot`，stat/test/mkdir/cp/chown/chmod/chcon/mv/sha256sum/rm 与回滚全部统一路由，不再各自写死 `su 0`。
- 两种 root transport 都不可用时，在 force-stop、strip、push、备份和替换前失败；错误包含 shell UID、build type、`ro.debuggable` 与 `:UESetAndroidDevice` 指引。
- `root_transport_spec.ps1` 覆盖 root adbd、verified `su 0`、production user build 无 root 三条路径，并验证无 root 路径只执行四条只读 probe。
- 同步 Android SO 主规格、架构边界与 K47 教训；没有修改引擎或项目源码。

**Pitfalls / Gotchas**

- “设备支持 root”不能等价成“设备存在 `su 0`”：engineering/root-adbd 设备不需要 `su`，production user build 则可能两者都没有。
- 当前所选设备实测为 shell UID 2000、`build_type=user`、`ro.debuggable=0` 且无 `su`；该设备不能执行原地 SO 替换，脚本修复只能准确拒绝，不能凭配置绕过 Android 权限模型。

**Validation**

- 回归先以 `ue_api` 52/53 失败复现缺少 root transport abstraction；实现后 53/53 passed。
- `structure` 38/38 passed；全量 `nvim --headless -l tests/run.lua` 725/725 passed。
- `openspec validate android-so-quick-deploy --type spec --strict` passed。
- 当前设备只读实测：`id -u=2000`、`build_type=user`、`ro.debuggable=0`、`command -v su` 失败。
- 以当前设备执行部署 preflight：在任何 installed SO 修改前返回新的 root-unavailable 证据错误。

**Follow-ups**

- 要在该设备使用 `<Space>uq`，必须先让设备本身提供 root adbd / `su 0`，或通过 `:UESetAndroidDevice` 选择 rooted test device；production user build 不能由本脚本提升权限。

### 2026-08-05 — 让头文件声明继续解析唯一的跨 TU 定义

**Task**

修复 C++ `gd` 到达 `SubmitActiveCmdBuffer` 头文件声明后原地终止的问题，同时保持 compiler identity 是唯一跳转依据。

**Implemented**

- `lua/utils/lsp_fallback.lua` 在 libclang 只能看到 declaration 时，以同一精确光标请求 clangd `symbolInfo`；只有 clangd USR 与 sidecar canonical USR 完全相等，才继续请求跨 TU definition。
- `lua/utils/ue_goto/provider.lua` 把返回该 USR 的 clangd client id 一并交给 definition 请求；未通过身份校验的其他 LSP client 不能贡献 location。
- definition location 先去重，再排除原 declaration 与当前位置；仅剩唯一 location 时才跳转。USR 缺失/不一致、零个或多个 definition 都保持当前位置，不按名称、arity 或返回顺序猜选。
- 从其他头文件调用点出发时，跨 TU 定义不可证明仍可退到 libclang 已证明同一 USR 的 declaration；已经位于该 declaration 时不制造自跳。
- `tests/fixtures/cpp_semantic/caller.cpp` 建立“origin TU 只含声明、body 位于另一 TU”的真实 libclang fixture；`ue_goto_behavior_spec.lua` 覆盖 USR 相等、USR 不一致、只回声明和多 definition 四条分支。
- 同步 C++ contextual navigation 主规格与符号解析架构文档；没有修改引擎或项目源码。

**Pitfalls / Gotchas**

- `clang_getCursorDefinition` 只在当前 origin TU AST 中找 definition；canonical USR 已解析成功不代表另一 `.cpp` TU 的 out-of-line body 会出现在该 AST。
- 直接信任 clangd 跨 TU index 会重新引入上下文漂移风险；libclang/clangd 的精确 USR 相等是跨 provider 交接的必要门禁。

**Validation**

- 两条回归均先失败：旧 header 路径完全没有发出 clangd USR/definition 请求，旧 provider 也会接收未校验 client 的 location；最终 `ue_goto_behavior` 4/4 passed。
- 真实 libclang fixture：`cpp_semantic_sidecar` 10/10 passed，并证明 declaration-only origin TU 返回非空 canonical USR、合法 declaration 与 `definition=nil`。
- `cpp_semantic_context` 10/10、`cpp_semantic_client` 10/10、`utils` 44/44、`structure` 38/38 passed。
- `nvim --headless -l tests/run.lua`：724/724 passed。
- `openspec validate cpp-contextual-definition-navigation --type spec --strict`：valid。

**Follow-ups**

- 当前已打开的 Neovim 会话需执行一次 `:UEDefReload`（revision `contextual-clang-v2`）或重启后再在 line 419 实测；实现不会触碰 Android 设备。

### 2026-08-05 — 分离 Android 安装、SO 替换与显式启动

**Task**

让 `<Space>ui` / `<Space>uq` 完成文件操作后保持应用停止，运行统一由用户显式 `<Space>ul` 触发，避免部署命令擅自占用设备前台。

**Implemented**

- `scripts/ue_android_so_deploy.ps1` 删除成功路径和回滚路径的 `monkey` 启动，以及与启动耦合的 PID/maps/稳定窗口验证。
- `<Space>uq` 现在只执行基线校验、force-stop、等待旧进程退出、strip/push、原子替换、metadata/hash 校验和必要回滚；成功后明确保持应用停止并提示使用 `<Space>ul`。
- `<Space>ui` 的既有实现经回归确认仍严格只有 `adb -s <serial> install -r <apk>`，不包含启动动作；`<Space>ul` / `:UELaunch` 是唯一显式启动入口。
- 同步 Android SO 主规格、架构数据流和 K46 教训；没有修改引擎或项目源码。

**Pitfalls / Gotchas**

- 文件部署命令若自动启动并要求运行时加载证据，就必然把部署结果与 Android 冷启动时序耦合；这与用户要求的显式启动边界冲突。
- 去掉自动启动后不能保留伪装成部署校验的 `/proc/<pid>/maps` 检查；静态完成判据是远端 metadata 与 SHA-256，实际运行由后续显式 `ul` 承担。

**Validation**

- PowerShell AST parser：通过。
- 无设备 mock：force-stop 延迟三轮后成功，永久不退出时在 1 秒内有界失败。
- `nvim --headless -l tests/run.lua ue_api`：52/52 passed。
- `nvim --headless -l tests/run.lua android_device`：13/13 passed。
- `nvim --headless -l tests/run.lua`：721/721 passed。
- `openspec validate android-so-quick-deploy --type spec --strict`：valid。
- 真机操作未执行：设备正在使用，按用户要求不触碰设备。

**Follow-ups**

- 无。

### 2026-08-05 — 让 C++ gd 服从当前 TU 的 Clang 实体身份

**Task**

修复 C++ 重载调用按裸 symbol cache 复用 sibling 落点的问题，并为非自包含 UE 头文件建立可证明的真实编译 TU 上下文；不修改引擎或项目源码，不加入 arity/ranking/text fallback workaround。

**Implemented**

- `lua/utils/lsp_fallback.lua` 将 C/C++ `gd` 从 legacy cache/csearch/GTAGS 链中隔离：source TU 只接受 active CDB 证明后的 clangd exact-position USR + 唯一 definition，header 只接受 contextual libclang 的 canonical USR 与同身份 definition/declaration。
- `lua/utils/ue_goto/semantic_{context,protocol,client,sidecar}*.lua` 与 `scripts/ue_clang_semanticd.lua` 实现 proven context、严格 NDJSON、异步 sidecar、unsaved overlays、stale request gate、live-TU LRU/idle eviction 和脱敏性能指标；source proof 要求明确 active shard 成员身份与 merged CDB freshness，并使用 clangd 消费的 post-processed merged command，模块按 context/client runtime/libclang/TU/catalog 边界拆分且均低于 800 行。
- `lua/ue/cdb/shards.lua` 修正 active shard 选择：匹配当前 platform/config/build class 时保留 `manifest.active`，显式 target 优先，并区分 Editor / non-Editor build class，避免较新的单文件 sibling shard 冒充当前构建。
- 头文件 context 只消费 active build 的真实 CDB 与 compiler-emitted `.cpp.json`、`.d`、rsp、unity membership；active-build 路径校验复用 `ue.cdb.shards.classify_rsp_path` 的 UBT grammar，不做 basename、目录距离、最近使用或路径子串猜测。
- 删除 C++ `gd` 已失效的 `syntax_filter`、arity、ranking、pair winner、自动 csearch/GTAGS 路径及对应脚本；保留非 C++ compatibility 与显式文本搜索入口。
- 新增真实 libclang fixtures、请求 stale/overlay/process 回归、只读 `scripts/ue_cpp_semantic_smoke.lua` 与脱敏证据；同步架构、约束、测试索引、cheatsheet、memory/decisions/lessons，将 OpenSpec delta 合并到主规格并归档 change。

**Pitfalls / Gotchas**

- standalone header clangd parse 在缺失真实 include/macro 前置上下文时会产生 recovery AST；只有被 build dependency evidence 证明的 origin TU 才有权决定 header 落点。
- 旧 LLVM/NDK 组合会在到达目标 AST 前触发诊断数量上限；sidecar 仅为语义 parse 添加 `-Wno-error -ferror-limit=0`，不改变原始 argv fingerprint 或实体选择。
- 光标移开再移回也必须永久 supersede 旧 token；只在回调时比较最终坐标会误放行 stale 跳转。
- source→header 的 origin context 必须直接来自已证明的 source CDB entry；用 `catalog(source.cpp)` 反推会在 cpp.json 只记录 includes 的正常形态下返回空。sidecar stop 也必须显式进入 stopping 状态，否则飞行中请求会被退出回调误当成可重试任务并重启进程。
- 初版 source proof 错误要求 raw active shard 与 merged CDB argv 完全相等。现场同一源文件分别为 189 / 622 个参数；回到 CDB pipeline 源码确认 merged CDB 会经过 slim/PCH/resolve/unify/prune 后处理，因此 exact equality 不是 provenance。现改为 active membership + merged freshness，并由 merged command 驱动查询。
- 单个 UE TU 的 libclang working set 很大。单点重复 warm 查询稳定不等于 reparse 内存已解决；最终完整 smoke 仍观察到 content-changing reparse 约 2.888 GB，因此只采用 max-TU=1、30 秒 idle eviction、版本不变内容复用与成功响应不携带 diagnostics 等有证据的边界控制。

**Validation**

- `ue_cdb` 15/15、`cpp_semantic_context` 10/10、`cpp_semantic_client` 10/10、`cpp_semantic_sidecar` 9/9、`ue_goto_behavior` 2/2、`utils` 44/44 passed；覆盖 active manifest/target/build-class 选择、同 arity 不同类型、默认参数、cv/ref、模板、ADL、继承、多 context、invalid AST、overlay、LRU、source→header origin、飞行中 stop、raw/merged command 分离、active membership 缺失拒绝、真实 sidecar 进程和 active-build 假前缀拒绝。
- 当前 live Nvim 在 `VulkanCommands.cpp:250` 的 source proof 返回 `resolved` 且携带 compile command；实际触发 `gd` 落到 `VulkanCommandBuffer.h:421`，没有 `active-compile-command-missing`。
- 已连接目标工作区的只读 smoke：两处嵌套双参数调用得到同一 canonical USR hash 并落到 `VulkanCommandBuffer.cpp:645`；无参调用得到不同 USR hash 并落到 `VulkanCommandBuffer.h:421`；exit 0，未写引擎/项目源码。
- 性能实测：cold parse 8,953 ms，warm query 复用同一 TU 且不按键 spawn compiler，content-changing reparse 15,437 ms；宽 evidence root 的精确预筛 + artifact 复核 1,998 ms。
- `nvim --headless -l tests/run.lua`：720/720 passed（包含保留的 `test_jumper_headless.lua`）；`openspec validate replace-cpp-goto-with-contextual-clang-resolution --strict`：valid。

**Follow-ups**

- high-water reparse working set 是已记录的剩余成本，不宣称已消除；若后续数据证明 max-TU/idle eviction 仍不足，另立 change 评估 clangd extension，禁止回加 symbol/arity/path ranking workaround。

### 2026-08-05 — 泛化 Android 项目标识并修复 SO receipt/APK 基线

**Task**

修复 `<Space>us` 已生成 SO、但 `<Space>uq` 错报 `Android SO not found`，并阻止新 JNI SO 被注入不兼容的旧 APK。

**Implemented**

- `lua/ue.lua` `android_so_from_receipt` 校验 UBT `<Target>.target` 的 TargetName/Platform/Configuration，并解析 receipt 声明的真实 SO build product；兼容 UE4 实际输出的 `<Target>-arm64.so`，不按 mtime 或通配符猜配置。
- receipt 含多个 `.so` 时，仅接受名称匹配当前动态 Target、类型为 Executable 的唯一主产物；插件 SO 或歧义候选不会被部署到 `libUE4.so`。
- nested `.uproject`、Android packageInfo 和 DAP symbol package 发现改为动态 `Source/<Project>` / `<Target>_Symbols_v*` / `<Target>-arm64`，不再把现场项目名当协议。
- `scripts/ue_android_so_deploy.ps1` 在 strip/push 前比较源 SO 同目录 `packageInfo.txt` 与设备安装包的 package/versionCode；不匹配时要求先通过 `<Space>ui` 安装一次基线 APK。
- `scripts/ue_android_so_deploy.ps1` 用 .NET `SHA256.ComputeHash(Stream)` 替代环境相关的 `Get-FileHash` cmdlet，保持大 SO 流式计算且不要求额外 PowerShell module。
- 回归 fixture 统一改用虚构的非 `Client` 项目，并覆盖 matching receipt、插件 SO 排除、错误配置、nested 项目与 DAP 符号发现；同步两个主规格、架构说明与 K44/K45 坑位。

**Pitfalls / Gotchas**

- 当前 UE4 的 Development 产物使用配置中性 `<Target>-arm64.so`；配置身份必须读 `<Target>.target`，不能从通用文件名推测。
- 首次真机替换虽然通过 ELF/hash/metadata/maps，但旧 APK 缺少新 SO 所需的 Java 方法，触发 `NoSuchMethodError` → SIGABRT；自动回滚后原应用恢复运行。
- 安装 matching versionCode APK 后同一 SO 成功部署并持续运行，证明失败是 Java/JNI 基线不匹配而非 strip 或文件替换问题。

**Validation**

- 回归测试先以 47/48 精确复现 receipt 文件名缺陷；最终 `ue_api` 51/51、`dap` 55/55、`ue_context` 3/3 passed，包含非 `Client` 项目、插件 SO 排除和多主产物歧义拒绝。
- 不匹配 APK 基线实测在 strip/push 前拒绝；匹配 APK 后实机部署 exit 0，hash/metadata/PID/maps 全部通过。
- 移除 `Get-FileHash` 后以同一真机路径复验：exit 0，.NET 流式 SHA-256 与设备端 `sha256sum` 一致，应用启动并映射替换后的 `libUE4.so`。
- `openspec validate android-so-quick-deploy|android-dap-attach|ue-code-search --type spec --strict`：全部 valid。
- `nvim --headless -l tests/run.lua`：688/688 passed；PowerShell AST、敏感信息扫描与 `git diff --check` 通过。

**Follow-ups**

- 纯 C++ 改动可持续使用 `<Space>us` → `<Space>uq`；Java/JNI/manifest/Gradle 输入变化后必须先重新安装一次匹配 APK 基线。

### 2026-08-04 — 过滤 Windows fs_event 元数据洪水

**Task**

处理持久化性能探针中反复出现的 `dirty-set-flood/cap-hit`，避免 1000 条伪 dirty 路径拖慢每次 picker 搜索。

**Implemented**

- `lua/utils/ue_watch.lua` 缓存当前 `csearch.idx` 内容时间锚；Windows/libuv 的已有文件 `change` 仅在文件 LAST_WRITE 晚于索引时进入 `persistent_dirty`。
- rename/create/delete、无索引和缺失 mtime 证据的场景继续保守记录，避免把带旧 timestamp 的新文件误过滤。
- 全量 csearch 成功清空 dirty 时同步推进 anchor，防止构建期间排队的旧元数据通知立刻重新污染集合。
- `tests/cases/ue_watch_csearch_spec.lua` 新增旧/equal/newer mtime、rename 与无索引行为回归；`ue-code-search` 主规格和 K43 坑位同步。

**Pitfalls / Gotchas**

- libuv Windows backend 同时订阅 LAST_ACCESS/ATTRIBUTES/SECURITY/LAST_WRITE，但只向 Lua 暴露统一 `change`；仅检查“文件仍存在”无法判定内容是否真的变化。
- 现场 1000 条 dirty 中 960 条已存在于刚生成的 csearch snapshot，只有 9 条内容 mtime 晚于索引；旧实现把元数据扫描放大成 overlay 洪水。
- `csearch-smart-build/reset: no snapshot` 的最新记录来自项目切换后的首次构建；当前 `csearch.idx.files` 已存在且与索引同时完成，属于预期冷启动，不另改逻辑。

**Validation**

- `nvim --headless -l tests/run.lua ue_watch_csearch`：11/11 passed。
- 现场 1000 条 dirty 回放：保留 9 条真实新写入，过滤 991 条索引前元数据事件，耗时 43.529 ms。
- `nvim --headless -l tests/run.lua`：682/682 passed。
- `openspec validate ue-code-search --type spec --strict`：valid。

**Follow-ups**

- 修复加载后重新观察 `dirty-set-flood`；若仍有 cap-hit，按新证据区分真实批量源码变更与其他事件源。
