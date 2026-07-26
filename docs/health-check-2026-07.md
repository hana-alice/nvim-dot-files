# Codebase Health Check — 2026-07

> 快照日期: 2026-07-26 · HEAD: `ae85f59`（v1.1.0 merge）
> 性质: 一次性审计快照（openspec change `codebase-health-check`），不承诺持续更新。
> 证据标准: 每条 finding 必须带 `文件:行号` 或可复现命令；无证据观察进附录。
> 只读: 本审计未修改任何运行时代码；修复建议各自立 change。

扫描器: `tools/health_scan.lua`（headless），原始输出 `tools/health_scan_output.txt`
（gitignore，工作产物）。99 个 lua 文件全量扫描 + 人工判读。

---

## Finding 总表（按严重级）

| # | 级 | 维度 | 一句话 | 证据 | 建议动作 |
|---|----|------|--------|------|----------|
| F1 | HIGH | 约束自违反 | `lua/ue.lua` 10472 行，超 800 行约束 13 倍，五大子系统混居 | `wc -l` = 10472 | 立 change `split-ue-lua-phase-1`（见 §2.1 切分大纲） |
| F2 | HIGH | 并发/生命周期 | persistent_dirty 打满 cap=1000 **静默丢增量**，overlay 背 1000 个 ThirdParty 噪声文件跑每次 `<leader>/` | `ue_watch.lua:468-476`（cap 裁剪无告警）；现场 `dirty.json` 1000/1000 全为 openexr/zlib 测试文件（mtime 2026-07-10 批量落盘） | 立 change `dirty-set-flood-guard`（cap 打满 WARN + blocklist 评估 + overlay 降级） |
| F3 | MED | P6 阻塞面 | `cdb/pipeline.lua` 在 jobstart 回调里同步 `vim.fn.system` 拷贝多 MB 的 compile_commands.json（×N targets） | `pipeline.lua:84-90` copy_file ← `:194`（on_exit 回调内循环调用） | 并入 change `pipeline-async-copy`（改 uv.fs_copyfile） |
| F4 | MED | P6 阻塞面 | Android launch/reattach 用 `vim.wait(200)`×50 轮询 pid，最长 10s 半阻塞（fast-event 可跑，用户输入冻结） | `android.lua:1814`、`android.lua:1890` | 并入后续 android 维护 change：改 uv timer 异步轮询（同 K40 模式） |
| F5 | MED | 并发/生命周期 | UEGrepTraceToggle 的 err-sink 500ms 轮询 timer **只装不卸**：toggle OFF 后仍每 500ms 跑 `nvim_exec2("messages")`+清屏，跨 toggle 泄漏且违反 P5 精神 | `ue.lua:9532-9549`（`_ue_err_sink_installed` 永 true，无 stop 路径） | 立 change `err-sink-lifecycle`（OFF 时 stop+close，或改 autocmd 方案） |
| F6 | MED | workaround | `lazy.float_vimresized_invalid_buf` **removal_condition 已满足**：上游 float.lua VimResized 回调已带 win+buf 双重 validity guard（校验失败 return true 自删） | 上游 `lazy/view/float.lua:190-194`（本机 stable 版）vs frontmatter removal_condition | 立 change `remove-lazy-float-workaround`（禁用验证 + 删除 + K21 行随删） |
| F7 | MED | 并发/生命周期 | `neovide/exit_with_gui` 的 2s 轮询 timer 在 `M.disable()` 中不 stop（只删 augroup），disable 后 timer 永活 | `exit_with_gui.lua:137-150`（timer 无句柄保存）vs `:155-157`（disable 只删 augroup） | 小修并入 workaround 维护 change |
| F8 | MED | 测试盲区 | 零覆盖子系统：`ue.dap._progress`、`utils/ue_logs`、`utils/restart`、statusline timer 排程、`ue_watch` flush/debounce 排程（现 spec 只测 csearch 契约 2 组） | `ls tests/cases` 27 spec 对照子系统清单；`ue_watch_csearch_spec.lua` describe=2 | F2/F5 修复 change 各自带 spec；_progress/ue_logs 记 backlog |
| F9 | LOW | P6 阻塞面 | `start_lldb_server_platform` 内 `vim.wait(150)`/`vim.wait(800)` 固定睡眠（attach 一次付 ~1s） | `android.lua:708`、`:722` | 接受（一次性、有注释理由）；如做 F4 顺手改 |
| F10 | LOW | 约束自违反 | 超 800 行文件另有 4 个：dap.lua 2361 / android.lua 2088 / symbol.lua 958 / cheatsheet.lua 954 | scan §B | dap/android 已高内聚可接受；F1 change 时一并评估 |
| F11 | LOW | 工具缺陷 | health_scan 的 jobstop 配对计数漏掉 `pcall(vim.fn.jobstop, id)` 引用形（ue_logs/dap.lua 实际有 stop 路径，扫描误报 0） | `ue_logs.lua:102`、`dap.lua:1815` vs scan §C jobstop=0 | 已在报告中人工纠正；脚本下轮改进 |

## 维度详情

### 1. P6 阻塞面（16 候选 → 4 finding + 12 合法）

合法项（同步调用但在允许上下文）：`config/lazy.lua:4`（启动引导）、
`ue_sidebar.lua:159` + `ue.lua:770`（均为 `vim.system` 不可用时的回落分支，
nvim 0.10+ 恒走异步主路）、`dap.lua:1137/1186`（`:UEDAPDiag` 用户命令内）、
`pipeline.lua:72`（`M.slim` 同步 API，用户命令路径）、`restart.lua:136`
（`vim.wait` 语义即「泵事件等子进程活性」，有注释论证）、
`ue.lua:8597`（`vim.wait(180000)` 在 UEPrepareSync——显式标注 debug-only 阻塞）。

违例/灰色：F3（回调内同步拷贝大文件）、F4（launch 半阻塞轮询）、F9（固定睡眠）。
**K40/K42 修复后全仓已无「timer 回调内同步 spawn」实例** ✅。

### 2. 约束自违反

- **2.1 F1 切分大纲**（ue.lua 10472 行的顶层职责块）：state/context 解析（~1.2k）、
  prepare 家族 sync+async（~2.5k）、csearch/grep picker 集成（~1.5k）、
  index/INDEX_FN 家族（~1.8k）、user commands 注册（~2k）、statusline/杂项（~1.4k）。
  建议第一刀切 INDEX_FN（内聚度最高、已有 `INDEX_FN.` 前缀命名空间）。
- **2.2 P1–P17 复核结论：全部合规**。P7（`string.format("%x"`）仅存在于注释；
  P3 无全局 handlers 覆盖；P1 telescope 仅注释提及（advanced_git_search 用的是
  snacks 后端）；P2 的 `ensure_installed` 是 treesitter parser 列表（合法，非
  mason 工具链）；P15 init.lua 无双 require；P16/P17 gdbserver-attach/localhost
  URL 仅存在于警示注释。
- **2.3 C4 抽查**：「未变更时跳过写入」✅（pipeline mtime 比对 `pipeline.lua:185-191`、
  sync_one_dot_clangd unchanged 短路）；「不做周期 ticker」⚠️ F5 的 err-sink
  是唯一越线者（opt-in 但 OFF 不卸载）。

### 3. workaround 存活复审（9 个）

| workaround | 结论 | 依据 |
|---|---|---|
| lazy/float_vimresized_invalid_buf | **可移除**（F6）→ **已移除 2026-07-26** | 上游 float.lua VimResized 已带双 validity guard + 自删 |
| snacks/picker_str_byteindex_oob | **保留**（复验完成 2026-07-26） | 上游虽重写为多级回落 wrapper（`util/init.lua:360`），但 `resolve_loc` 调用点（`:388 附近`）仍**不传 `strict_indexing=false`**——OOB 时 `vim.str_byteindex` 仍抛错，removal_condition 未满足。我们的 wrapper 强制 strict=false + pcall 钳制，继续必要 |
| blink_cmp/auto_wrap_undo_preview | 保留 | 锁定 v1.10.2 < 条件要求的 v1.10.3+ |
| clangd/non_file_uri_detach | 保留 | nvim core 无 per-client URI scheme filter |
| lazyvim/close_with_q_invalid_buf | 保留 | 上游 autocmds.lua 仍在 `vim.schedule` 里无 validity 检查地 `keymap.set`（`:76-82`，pcall 只包了 buf_delete） |
| neovide/exit_with_gui | 保留（附 F7 小修） | 上游 issue 未关 |
| snacks/picker_first_open_freeze | 保留 | 无上游 partial early-load |
| snacks/projects_picker_freeze | 保留 | 无上游 async projects source |
| snacks/smart_picker_dead_buffer | 保留 | 无上游 dead-buffer 过滤 |

### 4. 并发/生命周期

- timer/job/fs_event 配对审查：`ue.lua`（5 timer/13 stop/31 close）、`ue_watch`
  （4 stop/6 close）、`_progress`、`async_launcher`、`stall_probe`、goto cache
  均有完整 stop 路径 ✅。例外：F5（err-sink 无卸载）、F7（exit_with_gui disable
  不停 timer）。fire-and-forget jobstart（windows.lua explorer、platform probe、
  restart spawn）为设计如此，合法。
- F2 取证：dirty.json 1000 条全部 mtime 2026-07-10（git 批量操作一次性洪水），
  blocklist 无 `/thirdparty/` 条目（`ue_paths.lua:20-36`）故不拦；cap 裁剪
  （`ue_watch.lua:468`）静默丢最旧；WARN 阈值 500 只 INFO 一次
  （`ue_watch.lua:491`），cap 打满无任何升级告警。三个缺口叠加 = freshness
  语义退化不可见。（注意：ThirdParty 在 grep 索引范围内是**有意的**，修复方向
  是「打满可见 + 洪水清理策略」，不能简单 blocklist 掉。）

### 5. 测试盲区

见 F8。另：`workarounds_spec` 只验 frontmatter 契约，不验各 workaround 行为
（可接受——行为归上游，我们只管补丁形状）；`dap_spec` 25+ 用例为最厚，与风险
分布匹配 ✅。

## 后续 change 建议清单（优先级序）

> 落地状态 2026-07-26：除 F1 外全部完成（见 changelog 同日条目）。

1. `dirty-set-flood-guard`（F2，HIGH）— **已落地**：cap 打满 WARN（每会话一次）+
   `status().capped` 标志 + clear 复位；spec 3 例。洪水源（ThirdParty 批量 mtime）
   属有意索引范围，未加 blocklist。
2. `split-ue-lua-phase-1`（F1，HIGH，大工程）— **已落地 phase-1（2026-07-26）**：
   INDEX 块（原 2005–3302，~1300 行）切出 `lua/ue/index/`
   （init 50 / _state 601 / _clangd 236 / _build 502 行，全部低于 800 上限）。
   ue.lua 10472 → 9225 行。机械抽取 + deps 闭包注入（`INDEX_FN.setup`），
   `INDEX_RT` 与 `M._rt` 同表保持活引用，全部 ~60 个 `INDEX_FN.*` 调用点零改动。
   后续 phase-2 候选：prepare 家族（~2.5k）、picker 集成（~1.5k）。
3. `remove-lazy-float-workaround`（F6，MED）— **已落地**：文件删除、init.lua 注释、
   K21 标记退役、cheatsheet/lessons 同步。
4. `err-sink-lifecycle`（F5，MED）— **已落地**：toggle OFF stop+close，句柄挂
   CORE_RT 复用。
5. `pipeline-async-copy` + android 轮询异步化（F3+F4+F9 打包，MED）— **已落地**：
   copy_file → uv.fs_copyfile（mirror 全部落定后才 restart+on_done，防 torn 镜像）；
   launch/reattach pid 轮询 → `pidof_async`（uv timer + vim.system + in_flight）。
   F9 的 vim.wait(150/800) 保留（一次性，有注释理由）。
6. `verify-snacks-byteindex-workaround`（LOW）— **已复验**：上游 resolve_loc 仍不传
   strict_indexing=false，workaround 保留（见维度三表）。

另（task 7.2 固化项，已落地）：`stability_spec` 新增「timer 回调禁同步 spawn
（K40 0 容忍扫描 + ALLOW 白名单）」与「不再新增 >800 行文件（存量 5 个白名单）」。
F7（exit_with_gui disable 不停 timer）已修：M._poll_timer 持句柄，disable 停并关。

## 可固化 lint 建议（task 7.2）

- **timer 回调禁同步 spawn**：`health_scan.lua` §A 的 near-timer-start 检测可
  收进 `stability_spec`（0 容忍断言）——K40 模式的永久防复发。
- **文件行数上限**：不建议硬断言（ue.lua 存量巨大会常红）；建议 spec 只锁
  「不再新增 >800 行文件」（白名单现有 5 个）。

## 未覆盖区声明

- ue.lua 逐行语义审读未做（10k 行超时间盒）；只做了模式扫描 + 职责块粗分。
- python tools/（cdb pipeline 脚本）与 tests/harness 未入审计范围。
- workaround「需复验」项未做禁用实测（归后续 change）。

## 附录：未证实观察

- snacks notifier timer 在 jit.profile 采样中位列第二（~570 样本，K42 修复前
  数据）——未复采样确认修复后占比，暂不立 finding。
- `<space><space>` picker 首开偶发慢与 `picker_first_open_freeze` workaround
  的预热窗口可能相关——无复现命令，待观察。
