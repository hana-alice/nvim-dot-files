# hana-alice/nvim 2.12.0 — clangd 用完归还内存与临时文件

> 版本：2.12.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-26
> 类型：Minor；后台索引完成后回收重启 clangd、preamble 落盘并按会话隔离 TEMP、测试不再污染用户 %TEMP%；另含 headless CI 修复。
> 发布流程：按用户授权同步、脱敏归档、提交并推送；tag 待明确请求。

## 1. 本次交付范围

- **索引后归还内存**：`ue.clangd_memory_reclaim` 在大规模后台索引结束并静默后重启 clangd 一次。Windows 版 clangd
  没有 malloc_trim，索引期分配的堆不会自行归还。实测 16 个 TU 时 3.32→1.85 GB，生产 shard 库约降到 4.3 GB（其中约 3 GB 为必要的内存索引）。
- **preamble 落盘**：`--pch-storage=disk`，3 个 TU 时 1291→223 MB；批次 server profile 白名单同步放行。
- **不留垃圾**：每个会话的 clangd 使用独立 TEMP（`ue.clangd_temp`），只清理所属进程已退出的目录；回归测试把子进程 TEMP
  收进运行根，修复 inventory fixture 残留目录。
- **Segment Heap 已证伪**，未采用，详见下方归档条目。
- headless CI 在 ubuntu / macOS / Windows 上的修复（2026-10-23 两条）。

## 2. 验证与剩余范围

提交前串行全量 `nvim --headless -l tests/run.lua`：**4396/4396 通过、0 失败、2 SKIP**。两项跳过：未提供私有 GTAGS native
工程输入；当前宿主具备 PCH 能力而不适用的不支持场景。

未实测：回收重启在真实编辑器中的触发时机与重启后约 1–2 分钟的 gd/gr 退化窗口。稳态里约 3 GB 的内存索引未处理，需另立 change。

公开文档只保留通用结构与测量数值；工程路径、工作站身份与原始实验产物保留于本地。

## 3. 本次工作归档

### 2026-10-26 — clangd 用完归还内存与临时文件（索引后回收重启、preamble 落盘且按会话隔离）

**Task**
- 用户报告 clangd 的 commit 长期在十几 GB，其中一个进程空闲 10 天仍占 11.7 GB。要求：必要的工作完成后把资源归还，不在机器上留垃圾。

**Implemented**
- `lua/ue.lua` 的 clangd_cmd 改为 `--pch-storage=disk`。`lua/ue/index/batch_runtime.lua` 的 server profile 白名单同步放行 `disk`（只是存储位置，不影响语义）。
- 新增 `lua/ue/clangd_memory_reclaim.lua`：一次后台索引的队列达到 32 个任务以上并结束后，再等 60 秒静默；满足以下条件时，通过现有的 `maybe_restart_clangd_for_index` 重启这个 clangd 一次：普通模式、无未保存 buffer、没有再次开始索引、prepare 没在跑。
  - 重启后加载已有 shard 时，队列只有 `0/1`，不会再次触发，所以不会循环重启。
  - 同一会话内两次回收至少间隔 30 分钟。
  - 条件不满足时最多重试 20 次，放弃时记录探针，写明原因。
- 新增 `lua/ue/clangd_temp.lua`：每个 nvim 会话的 clangd 使用独立临时目录 `stdpath('state')/clangd-tmp/<nvim pid>`。启动时只清理"所属进程已确认退出"的会话目录；判断不了是否存活的一律保留。
- 测试也不再往用户 %TEMP% 留文件：`tests/run.lua` 把子进程的 TEMP/TMP 指向运行根目录，运行根在退出时删除；`index_source_refresh` 用例单独把 TEMP 收进自己的 fixture。`index_batch_work_inventory` 的 Python fixture 用 atexit 删除自己的 mkdtemp 目录（此前每次运行留 10 个，用户 %TEMP% 已积压 587 个，已一并清理）。
- 一次性清理了 %TEMP% 里历史遗留的 1404 个 `preamble-*.pch`（1.09 GB，2026-08 至今，主要是回归测试的 clangd 留下的）。

**Pitfalls / Gotchas**
- 内存构成（clangd 22.1.5，复制生产 shard 库到私有目录，-j=2，读 `$/memoryUsage` 和 PagefileUsage）：
  - 内存索引（Dex）固定约 2989 MB，常驻。
  - 打开 3 个渲染器 TU 的 preamble：memory 模式 1291 MB，disk 模式 223 MB。didClose 后归 0。
  - clangd 统计不到的堆有 2.5–3 GB。原因是 Windows 构建没有 malloc_trim（ClangdMain.cpp 中该代码只在 `__GLIBC__` 下编译），释放的堆不还给系统。
- 回收重启的实测效果：16 个 TU 冷索引完成后 private 3.32 GB；在同一 shard 库上重启，15 秒加载完，降到 1.85 GB。生产 shard 库重启加载（34108 个 shard）用 102 秒，降到 4.28 GB。
- **证伪：Segment Heap 无效。** 最初看到的"3.39 GB → 1.51 GB"是实验混杂：测试用的 manifest 版 clangd 放在缺少 `lib/clang` 资源目录的位置，找不到 builtin 头文件，解析内容变少（shard 2109 对 2133）。
  - 原位替换的 Segment Heap 版（读 PEB 确认堆类型）实测 3.32 GB；IFEO `FrontEndHeapDebugOptions=0x8` 实测 3.11/3.38 GB；NT 堆为 3.39 GB。三者没有差别。
  - IFEO 注册表项已删除，原版 clangd 已还原（哈希、大小与 mtime 均与原文件一致）。
  - 教训：对照实验要先比对产物（shard 数、stderr），再比内存。
- 发现：Windows 会按路径加 mtime 缓存 exe 的 manifest 解析结果。原位替换 exe 但保留原 mtime 时，新 manifest 不生效。
- disk 模式下 clangd 只在 didClose 或正常退出时删除 preamble 文件，被 kill 时会遗留。clangd 还在用的 preamble 文件可以被删掉，所以只能在确认所属进程已退出后才清理。

**Validation**
- 新增 `clangd_memory_reclaim` 8/8、`clangd_temp` 4/4。
- 相关回归：`index_batch_runtime` 86/86、`cpp_semantic_index` 1/1、`ue_api` 66/66、`smoke` 19/19、`ue_platform_boundary` 20/20、`host_resource_discipline` 13/13、`structure` 85/85、`clangd_resource` 10/10、`autocmds` 7/7、`index_delivery_phase_barrier` 27/27、`index_delivery_progress_race` 7/7、`ue_config` 11/11、`clangd_commands` 23/23、`index_batch_activation_state` 7/7、`index_batch_recovery` 20/20、`index_source_refresh` 17/17。
- 依赖 TEMP 或真实 clangd 的用例：`index_tier1_cohort` 28/28、`cpp_semantic_client*` 6/6+24/24+70/70、`cpp_semantic_pipeline` 1/1、`ide_refactor` 30/30、`index_batch_*`（activation 9、background_noclass 21、bindings 11、migration 1、prepare 4、publication 136、residual 38、store 2）全部通过；`index_compiler_identity` 1/1、`index_verified_batch_prefix` 8/8 通过；`index_query_profile` 0/0、1 skipped（宿主能力守卫跳过，不算通过）。跑完这一批后，%TEMP% 里新遗留的 preamble 为 0。
- `smoke` 有 1 条断言因为 spawn env 的约定变化而失败。已把断言改成新约定：保留调用方的 env，另外加上会话 TEMP，且不修改调用方传入的表。改后 19/19 通过。
- 第一次全量 4395/4396：`ue_cdb_prepare_cache` 的 VFS 用例失败，原因是测试进程 TEMP 改到运行根之后，collector 扫到了 `index_batch_work_inventory` 留在同一 TEMP 下、目标已移走的 junction（`unresolvable watch link`）。单独跑该用例 21/21。修复 inventory fixture 的残留后，全量 **4396/4396 通过、0 失败、2 SKIP**（未提供私有 GTAGS native 输入；当前宿主有 PCH 能力，不适用不支持场景）。跑完后用户 %TEMP% 里新增的 `preamble-*.pch` 与 `batch_work_inventory_*` 均为 0。

**Follow-ups**
- 回收重启在真实编辑器里的行为（触发时机、gd/gr 退化窗口约 1–2 分钟）还没有在 neovide 中实测。
- 重启后稳态约 4.3 GB，其中 3 GB 是内存索引，属于必要成本。要再降，只能改索引的组织方式，另立 change。

### 2026-10-23 — Headless CI follow-up (Linux /proc links, macOS wraps, nvim 0.12 Windows)

**Task**
- The second CI run (889687c) still failed on all three platforms; fix the remaining real causes.

**Implemented**
- `prepare_inputs.scan`: a non-input tool link whose target lies outside every covered root (Linux
  `/proc/<pid>/fd` style links under the tool tree) is not followed; EACCES tolerance stays.
- `ue.lua diagnostic_entries_from_output`: a bare `error:`/`warning:` location line whose message the
  terminal wrapped onto the next line keeps that message (macOS clang output); new regression case.
- `ui_responsiveness`: LSP log level goes through `vim.lsp.log.set_level` when available (0.12).
- `review_goto`: `attached_buffers[buf] ~= nil` (0.12 stores non-boolean values).
- Specs: `review_goto_native` resolves clangd/clang++ from `UE_CLANGD`/PATH and skips without a
  sibling compiler; prepare-cache read-only-tool guard; `ide_buffer_close` matches a wrapped prompt;
  `ide_workspace` waits for the resize before stopping a re-shown terminal (0.12.6 Windows segfault);
  `ide_replace_entry` starts the substitute from Normal mode with a closed undo block;
  `search_precision_ui` accepts a superseded stream that finished natively before the stop on a fast
  host; `ide_workspace_reuse` waits for the default action's editor split (macOS CI saw 2 normal
  windows right after close); `ide_replace_entry` loads its source from disk (no setup undo history)
  and resets the cursor after GrugFar; `ide_document_find_ui` handoff settles between kinds and
  reports window/cursor evidence (one macOS CI run cancelled the jump with a stale owner; cause unverified).
- Third CI run (c4c2c50, macOS only): `ui_responsiveness` argv check compares `-j` with
  `clangd_jobs.resolve()` and applies the UI-reserve bound only when `cpus - UI_RESERVED_CORES >=
  MIN_JOBS` (5-core runner gets the documented floor -j=4); `multi_instance_state` dirty union starts
  all eight writers behind a file barrier with a 40ms stagger, so slow child startup can no longer
  exhaust the first writer's bounded retries (cause 推测 from the CI stderr); `ide_workspace_reuse`
  default Enter waits for the third normal window and dumps the full window layout on failure.
- Fourth/fifth CI runs (macOS only): `ide_workspace_reuse` default Enter now waits inside the child
  (`vim.wait` 5s) instead of parent RPC polling, and on failure dumps window events, picker close
  callers, every `vim.schedule` callback (origin / started / finished) and the `W.activate` result.

**Pitfalls / Gotchas**
- nvim 0.12.6 Windows: stopping a terminal job in the same tick its buffer is shown at a new size
  crashes nvim (jobstop/chanclose/kill alike; minimal repro: termopen → enew → split → set_buf → jobstop).
- macOS CI known flake (open, cause unverified): at 0d54706 the push run was green on all three
  hosts while a concurrent dispatch run failed on macOS. Evidence from the dump: after the picker
  closed, the Snacks close cleanup (`picker.lua:664`) and the Workspace confirm (`workspace.lua:565`)
  were queued by `vim.schedule` but had not started 5s later, even inside the child's own `vim.wait`.
  Not reproduced on Windows nvim 0.11.5/0.12.6 or WSL, including with `<CR>` fed from inside the RPC
  request.
- `ide_document_find_ui` (macOS CI, 2 runs): Enter was rejected with "查找结果已失效" at generation 2
  and the picker stayed open. 推测: the finder had settled but the list still showed the previous
  generation's row. `settle()` now waits until the list holds exactly `status.count` rows, all from the
  current generation (the first fix only checked the current row and still failed once on macOS).
- Windows CI (c7efc22): the Chocolatey feed answered 503 for `fd` while `choco install` still exited 0,
  so five native fd cases failed. The workflow step now retries and requires `rg` and `fd` on PATH.
- `ide_workspace_reuse` / `ide_workspace` RPC waits: a Lua `nil` returned over RPC arrives as `vim.NIL`,
  which is truthy, so `picker.closed and mutation and ...` counted as ready while `mutation` was still nil
  (macOS CI then indexed it). Verified locally (`return nil and 1` → `vim.NIL`); the waits now treat
  `nil`/`vim.NIL`/`false` as not ready.

**Validation**
- Windows nvim 0.11.5 and 0.12.6, WSL Ubuntu 24.04: affected filters green (see full-regression line
  in the commit); Windows nvim 0.11.5 full regression 4383/4383 passed, 2 skipped.
- Third-run fixes: `ui_responsiveness` `multi_instance_state` (3 consecutive runs) `ide_workspace_reuse`
  green on Windows nvim 0.11.5 and 0.12.6 and WSL Ubuntu 24.04.
- GitHub Actions push run 39974324072 (0d54706): ubuntu-24.04, macos-latest, windows-latest all
  green; dispatch run 39974328498 (same commit): macOS 4292/4295 (flake above), others green.
- GitHub Actions push run 39990582029 (0be7e83, after the Find settle, Windows fd retry and `vim.NIL`
  wait fixes): ubuntu-24.04, macos-latest, windows-latest all green.

### 2026-10-23 — Repair headless CI on ubuntu / macOS / windows (nvim 0.12.6)

**Task**
- CI failed on all three platforms; fix the real causes instead of fake hosts.

**Implemented**
- `document_find_process`: ripgrep < 15 reports `searches = 0, bytes_searched = 0` for a no-match
  search; accept that only when our own confirmed stdin write proves delivery.
- `prepare_inputs`: tolerate system toolchain layouts — dangling links inside read-only tool roots
  (distro LLVM lldb modules) and cross-target `*.cfg` beside the driver (macOS CommandLineTools).
  Configs clang would load for this driver/target (`<driver>.cfg`, `clang.cfg`, `<triple>-clang.cfg`,
  unknown triple) still fail closed.
- `tests/run.lua`: the physical-temp relaunch now also covers macOS `TMPDIR=/var/...` → `/private/var/...`.
- nvim 0.12 compatibility in specs (`version = 0` text edits, exited terminal channels, a ConPTY
  resize/jobstop race wait); capability guards for missing csearch tools / libclang.
- Workflow installs the cindex-uefilter fork + pinned csearch; job timeout 60 min.

**Pitfalls / Gotchas**
- nvim 0.12 on Windows segfaults when a ConPTY job is stopped within ~20 ms of a resize (upstream).
- A stale `refs/heads/<branch>.lock` left by an interrupted rebase blocks the ref update.

**Validation**
- Windows nvim 0.11.5 and 0.12.6: `ue_cdb` 208/208 (+1 skip), `ue_cdb_prepare_cache` 21/21 (new system
  toolchain fixture), `ide_refactor` 30/30, `ide_task_inspection` 7/7, `search_interaction` 16/16,
  `cpp_semantic_sidecar_freshness` 10/10, `workarounds_uri` 15/15, `ide_document_find` 28/28.
- WSL Ubuntu 24.04 (rg 14.1.0): `ide_document_find` 28/28, `search_interaction` 15 + 1 skip.
- macOS lane validated only through CI.

**Follow-ups**
- Remaining macOS-only failures (dap_persist_failure, ide_buffer_close, clipboard, ide_recovery,
  ide_workbench, ide_workspace_reuse) to be re-triaged from the next CI run.
