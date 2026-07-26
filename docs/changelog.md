# Neovim Config Changelog

Working log for every change inside `~/AppData/Local/nvim/`. Every commit
should add an entry here even if it's tiny — the goal is total recall across
sessions, not curated release notes. When entries pile up, slice off a
versioned `RELEASE_vX.Y.Z.md` (see `release_1.0.0.md` for the format) and
keep this file rolling forward as the unreleased section.

## Entry template

```
### YYYY-MM-DD — Short title

**Task** (one line — why you touched the config)

**Implemented**
- bullet list of concrete changes (file paths + function names)

**Pitfalls / Gotchas**
- traps hit during the change, with the fix

**Validation**
- how you proved it works (headless probe, live nvim test, etc.)

**Follow-ups**
- links to `.hermes/plans/*.md` or TODO bullets
```

## How to use

1. Before touching anything under `~/AppData/Local/nvim/`, skim the latest
   N entries here. Fresh sessions don't carry context — this is where you
   recover it.
2. After landing a change (even a one-line patch), append an entry. The
   **Validation** field MUST state which regression scope you ran (a filter
   like `dap`/`commands`, or full `nvim --headless -l tests/run.lua`) and the
   result — see `docs/testing-regression.md` for the change→filter map.
3. When 8–12 entries have piled up OR a coherent multi-change effort wraps,
   cut a **milestone**: bump the version by semver (BREAKING→major, new
   capability→minor, fix→patch), move entries into `docs/release_vX.Y.Z.md`,
   run the **full** regression as a gate, tag the commit (`vX.Y.Z`,
   confirm with the user first), and leave a one-line cross-link under
   "Released" below. If the milestone touched architecture, also update
   `memory/` and `docs/architecture/overview.md`. (Authoritative: root
   `CLAUDE.md` Definition of Done; `docs/CONSTRAINTS.md §三 C7/C8`.)

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`

## Unreleased

### 2026-07-26 — refactor(ue): F1 phase-1 —— INDEX 子系统切出 lua/ue/index/（ue.lua 10472→9225 行）

**Task** — health-check F1 的第一刀：把 ue.lua 里内聚度最高的 clangd 离线索引块
（原 2005–3302，~1300 行，INDEX_FN/INDEX_RT 家族）切成独立模块。硬约束：行为零
变化、~60 个 `INDEX_FN.*` 调用点零改动。

**Implemented**
- `lua/ue/index/`（新）：`init.lua`（wiring + RT + setup(deps)）、
  `_state.lua`（模块记录/tier/index state 持久化 + core.h 共享 helpers）、
  `_clangd.lua`（restart / promote / .clangd 双写同步）、
  `_build.lua`（subset CDB / partition / phase build / 调度）。
  子模块 loader 风格 `return function(M, core)` 共享内部命名空间，无全局。
- `lua/ue.lua`：`local INDEX_FN = require("ue.index")`；
  `local INDEX_RT = INDEX_FN._rt`（**同一张表**——:UESetProject 清理与 status
  cache 继续改活状态）；原块位置换成 `INDEX_FN.setup{...}` 注入 7 个 late-bound
  闭包（status_root_key / clear+mark_index_dirty / invalidate_status_cache /
  refresh_statusline / read_all / write_all）+ core_rt 引用；
  ensure_index_state 等 4 个原文件局部经模块 re-export 重绑。
- 机械重命名：`INDEX_FN.→M.`、`INDEX_RT→RT`、`CORE_RT.→core.deps.core_rt.`、
  裸 `norm/trim/join(` → `fs.*(`（ue.core.fs 同名导出）。
- 知识库同步（维护契约 §六.4）：`lua/ue/index/AGENTS.md`（wiring 契约 + 禁反向
  require）+ `CLAUDE.md` stub；`structure_spec` MAJOR_DIRS 收编 `lua/ue/index`；
  `memory/project_overview.md` 子系统表加行。
- 新文件全部低于 800 行上限（601/502/236/50），stability_spec 行数守护天然通过。

**Pitfalls / Gotchas**
- deps 必须是 **late-bound 闭包**而非直接函数引用：status_root_key 等在 ue.lua
  里是 forward-declare、块位置之后才赋值——直接引用会捕获 nil，闭包在调用时
  才解 upvalue。
- `INDEX_RT` 不能拷贝：ue.lua 的 UESetProject 清理（timers/module_state/contexts）
  和 status cache 直接改这张表，模块外拷贝会分裂状态。`M._rt` 暴露同表。
- 切割边界内有一段 `M._sync_*_for_test` 测试 seam（前一轮 K41 加的）夹在
  INDEX_FN 定义中间——bridge 里原样保留，不能落在模块里（M 不同）。

**Validation**
- `require("ue.index")` / `require("ue")` headless 冒烟 OK。
- 全量 `nvim --headless -l tests/run.lua` → **exit 0**（含 structure 新目录守护、
  stability 行数守护、ue_api 的 .clangd seam 用例——seam 走 bridge 转发）。

**Follow-ups**
- phase-2 候选：prepare 家族（~2.5k 行）或 picker 集成（~1.5k 行）；等本刀
  真机浸泡数日无回归后再动。

### 2026-07-26 — fix/perf: 健康审计 finding 批量落地（F2–F7 + K40 lint 固化）

**Task** — 用户「go on all」：把 health-check-2026-07 报告的可落地项全部实施
（F1 拆 ue.lua 除外——大工程单独排期）。

**Implemented**
- **F2 dirty-set-flood-guard**（`lua/utils/ue_watch.lua`）：cap=1000 裁剪时
  `log_warn` 一次（含 DROPPED 数量与恢复指引）+ `status().capped` 标志暴露
  lossy 状态；`clear_persistent_dirty` 复位两个标志；新 test seam
  `_save_persistent_dirty_for_test`。`ue_watch_csearch_spec` 新增 3 例
  （打满 capped=true / clear 复位 / 未满保持 false）。
- **F5 err-sink-lifecycle**（`lua/ue.lua` UEGrepTraceToggle）：timer 句柄挂
  `CORE_RT.err_sink_timer`；OFF 时 stop+close，不再永久轮询 `:messages`。
- **F6 remove-lazy-float-workaround**：`git rm` workaround 文件 + init.lua
  注释替代 apply + CONSTRAINTS K21 标记退役 + cheatsheet/lessons 同步 +
  §二标题计数 9→8。依据：上游 lazy.nvim float.lua VimResized 回调已带
  win+buf validity guard（失败 return true 自删）。
- **F7 exit_with_gui timer 泄漏**：poll timer 句柄挂 `M._poll_timer`，
  `M.disable()` 停并关（原来只删 augroup）。
- **F3 pipeline-async-copy**（`lua/ue/cdb/pipeline.lua`）：`copy_file` 改
  `uv.fs_copyfile`（threadpool，回调制）；新 `mirror_targets_then` 等**全部**
  镜像落定后才 restart_clangd + on_done——防 partition 在 copy 读取中途改写
  源文件产出撕裂镜像（同 2026-06-25 撕裂类）。
- **F4 android async pid poll**（`lua/ue/dap/android.lua`）：新 `pidof_async`
  （uv timer 200ms + `vim.system` + in_flight + deadline，K40 同款模式）；
  launch 与 reattach 的 `vim.wait(200)×50` 半阻塞轮询全部改异步回调链。
- **K40 lint 固化**（`tests/cases/stability_spec.lua`）：新增「timer 回调内
  禁同步 spawn」全仓静态扫描（0 容忍 + ALLOW 白名单机制）与「不再新增
  >800 行文件」（存量 5 文件白名单）两组守护。
- **snacks byteindex workaround 复验**：上游 `resolve_loc` 仍不传
  `strict_indexing=false`（`util/init.lua:360` wrapper 只是版本适配），
  removal_condition 未满足 → **保留**。报告维度三表已更新。
- `docs/health-check-2026-07.md` 落地状态回写。

**Pitfalls / Gotchas**
- F2 测试首版把 `dirty_json_path=nil` 当「不落盘」用——`save_persistent_dirty`
  无路径时 early-return，裁剪根本不跑；必须用真实临时 dirty.json 驱动完整路径。
- F3 的镜像拷贝**不能** fire-and-forget：on_done 链下一站 partition 会原地改写
  同一源文件，必须等全部 copy 落定（pending 计数收敛）再放行。
- F4 的 `pidof_async` deadline 判定放 timer 回调（fast-event 安全，只算术），
  finish 全部经 vim.schedule 且幂等（finished 标志），防 stale spawn 回调复活。

**Validation**
- `ue_watch` / `stability` / `dap` / `ue_cdb` / `workarounds` / `structure`
  filter 全绿；**全量 `nvim --headless -l tests/run.lua` → exit 0**。
- F4/F3 的真机/真 prepare 行为待下次日常使用观察（逻辑等价改造，回归绿）。

**Follow-ups**
- F1 `split-ue-lua-phase-1`（切 INDEX_FN 首刀）单独排期。
- 下次 Android launch 实测 pidof_async 路径（输入不冻结 + 10s 超时语义不变）。

### 2026-07-26 — docs(audit): 一次性代码健康审计（openspec change codebase-health-check）

**Task** — 用户要求系统性 health check：捋现有代码，找问题 / workaround 失效 /
设计缺陷 / 潜在 issue。三个月来 K40/K42 等都是事后追查，这次主动体检。

**Implemented**
- `tools/health_scan.lua`（新，headless 一次性扫描器）：P6 阻塞调用候选（含
  上下文提示）、超 800 行文件、timer/job/fs_event 生命周期配对表。
- `docs/health-check-2026-07.md`（新，审计报告快照 @ ae85f59）：11 条 finding
  （2 HIGH / 6 MED / 3 LOW），五维度全覆盖。要点：
  - **F1 HIGH** ue.lua 10472 行超约束 13 倍，附切分大纲（首刀 INDEX_FN）。
  - **F2 HIGH** persistent_dirty cap=1000 打满静默丢增量，现场 1000 条全为
    2026-07-10 批量落盘的 ThirdParty 测试文件；WARN 只 INFO 一次、打满无告警。
  - **F6 MED** `lazy.float_vimresized_invalid_buf` workaround 的
    removal_condition 已满足（上游 float.lua 已带双 validity guard）→ 建议移除。
  - **F5 MED** UEGrepTraceToggle err-sink timer 只装不卸（OFF 后仍 500ms 轮询）。
  - P1–P17 禁止项复核**全部合规**；K40/K42 修复后全仓无 timer 内同步 spawn。
  - 后续 change 建议清单 6 项（优先 dirty-set-flood-guard、split-ue-lua-phase-1）。
- `.gitignore` + `tools/health_scan_output.txt`（工作产物不入库）。
- openspec change `codebase-health-check` 四工件 + tasks 全勾。

**Pitfalls / Gotchas**
- 扫描器的 jobstop 配对计数漏 `pcall(vim.fn.jobstop, id)` 引用形——ue_logs/dap.lua
  实际有 stop 路径，靠人工判读纠正（报告 F11 自记）。机器扫描只产候选，判读定级
  必须人工。
- 「vim.fn.system 出现」≠ 违例：16 候选中 12 个在合法上下文（用户命令 / vim.system
  回落分支 / 启动引导）。

**Validation**
- 审计只读：`lua/` `tests/` 零改动（新增仅 tools 脚本 + docs 报告）。
- 全量回归 `nvim --headless -l tests/run.lua` → exit 0 全绿。

**Follow-ups**
- 按报告清单立后续 change：`dirty-set-flood-guard`（HIGH）→
  `remove-lazy-float-workaround` → `err-sink-lifecycle` → `pipeline-async-copy`
  → `split-ue-lua-phase-1`（大工程单排）。

### 2026-07-24 — perf(gitsigns): watch_gitdir × git fsmonitor 自激 spawn 循环 → C-f/C-b 与 picker 全程卡顿（K42）

**Task** — 用户报「Ctrl+F/Ctrl+B 卡卡的，space space 搜文件也卡」。K40（liveness poller）
已修，但 stall train 仍在（18:20–18:33 每分钟 ~40 条，无 DAP 会话）。

**Root cause** — 用 `jit.profile` 对运行中实例采样 8s：gitsigns 的 async git spawn +
`git/repo/watcher.lua` 占主循环 ~1600/4300 样本，是绝对大头。机制：本机 UE 仓开了
**git fsmonitor**（`core.fsmonitor=true`，engine 检出为 git worktree 形态，gitdir
指向主仓 `.git/worktrees/<name>`）。每个 git 子进程运行都在 `.git/` 落 fsmonitor
cookie → gitsigns gitdir watcher 观察到「变化」→ refresh → spawn git → 又落 cookie →
再触发——**自激振荡永不收敛**。Windows spawn 主循环开销数十 ms/次；再叠加
current_line_blame delay=200ms（每次光标停留 200ms 就 spawn 一个 `git blame -L`），
翻页节奏正好接近 200ms → 几乎每页都补一刀。

**Implemented**
- `lua/plugins/gitsigns.lua`：`watch_gitdir.enable = false`（K42 注释含完整机制与代价
  说明：外部 git 操作改由 BufWritePost/FocusGained 刷新）；`current_line_blame_opts.delay`
  200 → 500ms。
- 对运行中实例**live 应用**（remote-expr 注入：改 `gitsigns.config` + detach_all +
  re-attach），复采样验证：gitsigns 相关栈从 ~1600 样本降到 **0**（top 只剩 idle poll +
  notifier timer + stall_probe 自身）。
- `docs/CONSTRAINTS.md` 新增 **K42**（含诊断法：jit.profile 采样脚本 + 排除法）。

**Pitfalls / Gotchas**
- stall 的 keys 字段记录的是「解冻瞬间的按键史」——`<C-F>/<C-B>` 出现在里面不代表
  翻页函数慢，而是翻页期间主循环被别人钉住。真正定位靠 **jit.profile 采样**，一次
  8s 采样直接指名 gitsigns，比任何猜测快。
- fsmonitor cookie 是 git 官方机制（`.git/fsmonitor--daemon/cookies`），任何「watch
  .git 目录」的插件在 fsmonitor 仓上都会自激——同类插件（neogit/fugitive 的 watcher）
  如引入需先查此项。
- `nvim --server` 远程注入排查时 pipe 路径必须正斜杠 `//./pipe/nvim.<pid>.0`（K9）。

**Validation**
- live 复采样：gitsigns 栈样本 1600+ → 0；stall train 停止需用户继续操作确认。
- 配置层修复待下次重启 nvim 生效（live 注入已让当前会话即时生效）。
- 全量回归 `nvim --headless -l tests/run.lua` → exit 0。

**Follow-ups**
- 用户实操确认 `<C-f>/<C-b>` 与 `<space><space>` 恢复流畅；若 picker 输入仍卡，
  下一个嫌疑人是 snacks notifier timer（采样第二位，~570 样本）。

### 2026-07-24 — fix(ue): 跨 checkout buffer 满屏 diagnostics —— 一次性告警替代静默 fallback

**Task** — 用户报「UEPrepare 都执行了，Neovide 里打开某文件还是很多 diag」。

**Root cause（配置无 bug，是 UX 缺口）** — 当前 pin 的 project 是 checkout A，
用户打开的是 checkout B 里的同名文件（同一工程的另一份检出）。项目选择是
manual-only（2026-07-14 设计决定），buffer 不会自动切 project——正确；但后果是
CDB 里只有 A 侧路径（B 侧 0 条），clangd 对 B 的文件报
`Failed to find compilation database ... fallback flags`（lsp.log 实证），
无 UE defines/includes → 满屏 diagnostics，被误读为「UEPrepare 坏了」。

**Implemented**
- `lua/ue.lua`：新增 `CORE_RT.foreign_buffer_key(path, project_root, engine_root)`
  纯分类器（大小写/分隔符归一、防前缀误判 projA vs projA_debug、外部目录 3 级
  dedup key）+ `CORE_RT.notify_foreign_buffer`（每外部根每会话一次 WARN，指明
  file vs pinned project 并提示 :UESetProject）。挂在 BufEnter 的
  set_active_module 之前。
- `tests/cases/ue_project_context_spec.lua`：新增 5 例（内/外/engine 内/前缀
  相似不误判/归一化）。

**Pitfalls / Gotchas**
- 「很多 diag」的第一诊断动作：lsp.log 搜 `Failed to find compilation database`
  + 对照 CDB 里该路径前缀的条目数——0 条 = 上下文不匹配，不是索引坏。
- 路径 inside 判定必须 `root .. "/"` 前缀而非裸 `find`——否则 `projA_debug`
  被误判为 `projA` 内部。

**Validation**
- `ue_project_context` filter → exit 0（新增 5 例全绿）；全量 → exit 0。

**Follow-ups**
- 用户确认：如果确实要在 android_3.6_debug 工作，`:UESetProject
  E:/sample/android_3.6_debug` + `:UEPrepare` 后 diag 应消失。

