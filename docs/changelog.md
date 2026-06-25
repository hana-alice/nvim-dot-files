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

## Unreleased

### 2026-06-25 — fix(cdb): UEPrepare 的 cdb_partition 与 pipeline 并发撕裂 compile_commands.json（JSONDecodeError 根治）

**Task** — `:UEPrepare` 稳定报错 `ue-pipeline failed (exit 1)` / `json.decoder.JSONDecodeError`（每次偏移不同：char 68551910 / 32430658 / 86744524）。用户只触发一次 UEPrepare，排除手动重入。

**根因（打 log 坐实，非推测）** — fast-path 在 `lua/ue.lua` 起 **async** pipeline（`run_compile_commands_pipeline` → jobstart 立即返回）后，**紧跟同步**跑 `INDEX_FN.partition_base_cdb`，两者并发改写同一个 `<engine_root>/compile_commands.json`（225MB）。带毫秒时间戳的探针实证：`partition START (260175301)` 落在 `pipeline START (260175285)` 与 `pipeline EXIT (260182943)` 之间，partition 全程 ~5.6s 与 pipeline 重叠 → pipeline 的 resolve 阶段读到被 partition 撕裂的中间态 → JSONDecodeError。失败 run 的 partition 备份 `compile_commands.json.bak-20260625-173955`（单行撕裂态）是另一铁证。

**Implemented**
- `run_compile_commands_pipeline(path, targets, on_done?)` 新增 `on_done` 形参，透传给 `ue.cdb.pipeline.run`（pipeline 本就支持 on_done，wrapper 之前没转发）。
- fast-path（`lua/ue.lua` ~8402）把 `partition_base_cdb` 从「pipeline 之后立即同步」改为「pipeline 的 `on_done` 回调内」——严格串行在 expand→pch→resolve→unify→prune 完成之后，消除并发写。
- `on_done` 在 pipeline 的 no-change 与 changed 两条路径都触发（pipeline.lua:189/199），且在 copy_file 到 sibling targets 之后，故 partition 必见最终 base CDB。

**Pitfalls / Gotchas**
- 误区排查链：先疑「非原子写被中断」→ 再疑「writer/reader 编码不一致（prebuild_pch_v2.py:467 缺 encoding=）」→ 都被证伪（失败时磁盘文件事后是干净 ASCII / 单行）。最终靠时间戳探针锁定是**单次 run 内部自起的两个并发写者**。原子写只是兜底，真因是并发，治本是串行化。
- 仅 fast-path 同时调 pipeline+partition；cold/full（`generate_compile_commands`）与平台切换（`fast_swap_active_platform`）不调 partition，无此 race；手动 `:UECDBPartition`/`:UECDBSwitch` 无并发 pipeline。
- 残留隐患（未本次处理）：`prebuild_pch_v2.py:467` / `prune_include_dirs.py:431` 的 CDB 写缺 `encoding='utf-8'`，UE 路径含非 ASCII 时是潜在 bug；各 pipeline 脚本 in-place 写非原子，中断仍可留半成品。可后续单开 cdb 加固 change。

**Validation**
- 修复后真实 `:UEPrepare`（一个 225MB CDB 的 UE 项目）：pipeline 的 resolve 阶段 **成功通过** `resolve_cdb_paths: resolved 3044 relative paths`（此前每次死在此处），不再有 JSONDecodeError。（测试窗口 2min timeout 截断了后续 unify/prune + clangd 索引，属测试窗口短，非 bug。）
- 全量回归 `nvim --headless -l tests/run.lua` = **551/551 passed, 0 failed**；分范围 `ue_cdb` 8/8、`smoke` 16/16。

**Follow-ups**
- cdb 脚本 encoding= + 原子写加固（潜在，未阻塞当前修复）。

### 2026-06-25 — search 系统小幅度重构：csearch 去平台化 + `<leader>/` 从不加 rg + 面板内 scope

**Task** — `<leader>/` 距 Rider 体验有差距；调研结论：csearch 是 Windows 内容搜索天花板（Everything 1.5 内容索引不适合源码树、zoekt P13 死路），真问题在 ①csearch 索引被无谓地按平台分片、②`<leader>/` 仍会静默降级到 rg、③UI 已实现但可发现性差。本次落实前两项 + 补面板内 scope。OpenSpec change：`refactor-search-system`。

**Implemented**
- **csearch 索引去平台化**（cache layout v3.2）：`ue.lua cache_paths` 的 `csearch_idx` 由 `csearch/<platform_key>/csearch.idx` 改为扁平 `csearch/csearch.idx`，全平台共用一份。依据：csearch 文件清单输入（`engine_root`+`project_root`+平台无关的 `ENGINE_PICKER_DIRS`/`SCAN_EXCLUDES`/`.ueprepare-scan-paths`）无平台维度；且 `csearch_input_hash` 本就 per-engine_root，去平台化使校验维度与索引维度对齐。gtags/cdb 仍 per-platform（编译相关）。
- **迁移（M2 标记 stale）**：`migrate_legacy_csearch_if_needed` 不再搬运 csearch（扁平后 legacy==active），只迁移 gtags lists/DB；旧 `csearch/<key>/` 不删，靠 `prepare_freshness` 判 stale → 下次 `:UEPrepare` 重建共用索引。更新 `fast_swap_active_platform` 注释（切平台不再动 csearch）。
- **`<leader>/` 从不加 rg**：移除 4 处 rg 暗门——`cached_grep` 内 ②rg-batched fallback、③`return nil`→snacks 目录遍历、rg fast-path（`source="ue_grep_rg"`，~240 行），以及 `snacks.lua ue_project_grep` 的 `snacks.picker.grep` 兜底（design 原稿漏列的第 4 处）。无索引时弹可见 ERROR 引导 `:UEPrepare`、不开任何 picker。`code_search.stream()` 内 rg 分支保留（gd/gr 兜底 P12）；`<leader>sG` 仍是显式 rg 入口。
- **面板内 scope 过滤**（`<a-s>`）：新增 `ue_grep_toggle_scope` action + `scoped` toggle（标题 "S" 图标）。复用 csearch 单一 `-f` 文件路径正则；新增纯函数 `code_search._compose_file_regex(opts)` 把 `code_only` 扩展名正则与 scope 路径正则折叠为一条 RE2（`<scope>.*<exts>$`，RE2 无 lookahead）。scope 取自当前 buffer 的 module/plugin（`current_scope_info_from_context`），开面板时捕获。

**Pitfalls / Gotchas**
- csearch 只接受**单个** `-f`（实测 `csearch --help`），RE2 无 lookahead → scope+code_only 必须折叠成一条线性正则，不能传两个 `-f`。
- 第 4 处 rg 暗门在 wrapper 层（`ue_project_grep`），不在 `cached_grep` 内——design 原稿只列了 3 处，实施时补正并回写 design.md。
- 去平台化后 `grep_cache_spec` 多条断言（per-platform 路径、csearch 迁移、rg 路径 case 接线、slow-fallback 标题）全部失效，按新契约重写。

**Validation**
- 全量回归 `nvim --headless -l tests/run.lua` = **551/551 passed, 0 failed**。
- 分范围：`grep_cache`（25/25，含新增去平台化路径断言 + scope `-f` 组合 + csearch-only 静态接线）、`csearch`（13/13）、`ue_goto_behavior`（6/6，确认 gd/gr 的 rg 兜底链未被砸穿）、`utils`（30/30）。
- `ue.lua` / `code_search/init.lua` headless `require` 加载无错。

**Follow-ups**
- 可发现性（Rider 风常驻 toggle 提示栏 / `footer_keys`）仍是候选子项，未在本次落地。
- 文档：cheatsheet/README/`code_search/CLAUDE.md` 同步（本条目同批）。

### 2026-06-18 — 通用后台任务管理（:Tasks / 派生状态注册表）

**Task** — 用户：「我 space ub 发起一个任务之后怎么把他停掉」。本仓后台 job（构建/prepare/launch/install/logcat/日志流）句柄散落、部分根本没保存，`async_launcher` 的 `q` 明确「不取消底层 job」，没有统一的「列出+停止」入口。需求是通用编辑器能力，不绑 UE。

**Implemented**
- `lua/utils/task_registry.lua`（新，零业务依赖）：**派生状态架构**——记录只存 `{id,name,group,kind,handle}`，**无 `state` 字段、无 `mark_done`、无状态机**；`M.status(id)` 每次实时查句柄（`job`→`vim.fn.jobwait({h},0)`、`system`→handle `is_closing`）派生状态。唯一写入入口 `M.register`（纯内存）；`M.cancel` 先复检再动句柄（`jobstop`/`:kill`）、不回写、幂等；`M.list` 查询+GC（终态裁剪到 `KEEP_DONE=16`，无 timer）；`M.running_count`（statusline 用）；探针可注入 `_set_probe_for_test`。架构上消除「副本 vs 真相」「回调写 vs 命令写」两类竞态（见 change `ue-task-manager` design.md）。
- `lua/utils/async_launcher.lua`：`launch` 加可选 `opts.cancel`；浮窗 `<C-c>` 真正取消（仅当有 `cancel`），`q` 维持「仅隐藏」旧语义（向后兼容，现有调用点零变化）；hint 文案据是否有 cancel 动态显示。
- `lua/ue.lua`：接入注册表（**只在 job 创建后加一行 `register`，on_exit 零改动**）——`open_terminal_command`（build，terminal/job）、prepare gtags（`CORE_RT.prepare_jobid`）、`async_generate_compile_commands` 的 ccjson `vim.system` handle（此前丢弃，现保存并登记 kind=system）、`install_android`（jobid 此前丢弃）。注册 `:Tasks`/`:TaskStop [id]`/`:TaskStopAll`（无 UE 前缀，通用功能）；`:UEPrepare` 传 `cancel` 给 launcher。`M.statusline_status` 加 `⏵N` 计数段（N>0 显示，N==0 不占位；复用既有 eval，不新增 timer）。
- `lua/utils/ue_launch.lua`：android launch job 登记（desktop detach job 故意不登记）。`lua/ue/dap.lua`：logcat job 登记（DAP 会话本身不登记，K5）。`lua/utils/ue_logs.lua`：日志流 job 登记。
- `lua/config/keymaps.lua`：`<leader>X` → `:Tasks`（通用层，不挂 `<leader>u*`）。
- `lua/utils/cheatsheet.lua`：新增「Tasks (background jobs)」段。`README.md`/`docs/README.zh-CN.md`：键位表补任务管理行。`lua/utils/CLAUDE.md`：新增「后台 job 接入 task_registry」维护契约（只追加 register、不回写 on_exit）。

**Pitfalls / Gotchas**
- 上一版方案曾用「先抢状态/禁 vim.*/generation 计数」一串规则去*管理* stored 状态机的竞态——本质是 workaround。改为**派生状态**从架构消除竞态：不存状态副本就没有可竞争对象。连带让等价性证明更强（接入点 on_exit 逐字节不变，无需证「末尾追加 mark_done 不改副作用」）。
- ccjson 的 `vim.system` handle 此前是局部变量用完即弃；登记需在 `M.async_generate_compile_commands` 末尾 `return handle` 前加 register——注意函数末尾的 `return M`（模块导出）一度被新插入块顶掉，导致 `require("ue")` 返回 boolean、`ue.setup()` 全挂（commands_spec 3 连失败）。补回 `return M`。

**Validation**
- 新增 `tests/cases/task_registry_spec.lua`（15 用例）：register/派生 status/两类 kind cancel/幂等/cancel_all/id 单调/AR-T1 状态即真相/AR-T2-T3 取消语义/AR-T4 源码守护（无 mark_done、register 体纯内存、接入点 on_exit 无 task_registry 写）/AR-T5 list GC 有界幂等/DAP 边界。
- `commands_spec.lua` 加 `Tasks`/`TaskStop`/`TaskStopAll` 冻结清单（3 命令）。
- 分范围回归全绿：`task_registry` 15/15、`commands` 81/81、`cheatsheet` 105/105。全量 `nvim --headless -l tests/run.lua` → **540/540**。

**Follow-ups**
- `:Tasks` 本期用 `vim.ui.select`；design Open Question 记录的「snacks.picker 自定义源双列预览 + `dd`/`<cr>`/`gl` 多动作键」作后续增强。
- 取消构建未杀 UBT 派生 cl.exe/link.exe 进程树（design Follow-up）。

### 2026-06-18 — 任务管理快捷键扩充 + cheatsheet 双 surface 同步

**Task** — 上一条只给了单键 `<leader>X`，且 cheatsheet 只更新了 float 版、markdown 版漏同步（违反本仓「双 surface 不漂移」回归）。补齐键位粒度与两个 surface。

**Implemented**
- `lua/config/keymaps.lua`：`<leader>X*` 扩成一组（与 DAP `<leader>d*` 同风格）——`<leader>X`→`:Tasks`（面板）、`<leader>Xs`→`:TaskStop`（停单个，唯一时直接停）、`<leader>XA`→`:TaskStopAll`（停全部，先确认）。
- `lua/utils/cheatsheet.lua`：float UE tab 的「Tasks」段改用三键 + `:TaskStop [id]` + statusline `⏵N`。
- `docs/ue_lazyvim_cheatsheet.md`（此前漏同步）：新增「⏵ Background Tasks」节（键表 + 派生状态/不确认/`<C-c>` 取消/DAP K5 边界说明）+ Contents 目录项。
- `tests/cases/keymaps_spec.lua`：加 `<leader>X`/`Xs`/`XA` → Tasks/TaskStop/TaskStopAll 绑定断言。
- `tests/cases/cheatsheet_spec.lua`：双 surface 防漂移锚点加入 `<leader>X`/`Xs`/`XA`（强制 markdown 必含）。

**Validation**
- `keymaps` 46/46、`cheatsheet` 109/109、`commands` 81/81；全量 `nvim --headless -l tests/run.lua` → **547/547**。





**Task** — 用户要求：cheatsheet 配色难看且快捷键太少（尤其 `<leader>/` 里全字/大小写/正则怎么切）；把当前 Warp 终端主题 Apprentice 同步成 nvim colorscheme。

**Implemented**
- `colors/apprentice.lua`（新）：把 Warp 的 `apprentice.yaml`（romainl/Apprentice）移植为完整 nvim colorscheme——editor chrome + 语法 + treesitter/LSP 语义 + 诊断 + diff + gitsigns + bufferline + 16 色终端色（终端 16 色逐字照搬 yaml）。**语法组（Constant/String/Identifier/Function/Statement/Type/PreProc/Special 等）逐色对齐上游官方 `colors/apprentice.vim`**，非自创映射。
- `lua/theme.lua`：LABELS 注册 `apprentice = "Apprentice"`，可 `:Theme apprentice` / ThemePicker 切换并持久化。
- `lua/ue.lua`：grep picker（cached_grep）加回 `<a-r>` 正则切换（NVIDIA Overlay 关闭后 Alt 可达），与既有 `<a-g>`(regex 别名)/`<a-w>`/`<a-x>`(whole-word)/`<a-c>`(case) 并列；切换实时重跑 rg + 标题 R/W/C 图标 + 提示。
- `lua/utils/cheatsheet.lua`：配色改为 Apprentice 调色板（cyan 单强调 + 灰阶，去 8 色彩虹）；扩充键位（Code/LSP actions、picker `<C-s>/<C-v>/<C-t>`、live-grep `-- -w/-s` 与 `<a-*>` 切换、UE Index/Diagnostics 等）。
- `docs/ue_lazyvim_cheatsheet.md`：新增「Refining a live grep」节，讲清 `pattern -- -w -s` inline flag + `<leader>sx/sX` 启动键 + `<a-r/w/c>` 切换三种方式；补 picker 内 split/tab 键。
- `tests/cases/cheatsheet_spec.lua`：防漂移锚点加入搜索精修键（sx/sX/sw/sy/`-- -w`/`-- -s`）。

**Pitfalls / Gotchas**
- 主题第一版语法配色是自创角色映射（类型→cyan 等），与作者意图不符，看起来「不像」。改为抓 romainl/Apprentice 官方 `.vim` 的八个核心组原值（Constant #ff8700 / Statement #87afd7 / Type #8787af …）逐色对齐，treesitter/LSP 组对齐到对应 legacy 组。
- `<a-r>` 历史上被 NVIDIA App 性能 Overlay 全局热键吞掉；用户关闭该 Overlay 后恢复，保留 `<a-g>` 作为兜底别名。

**Validation**
- `colorscheme apprentice` headless 加载，核心语法组色值与上游一致（Normal/Constant/String/Identifier/Function/Statement/Type/PreProc/Special 全部命中）。
- 全量 `nvim --headless -l tests/run.lua` → 521/521。



**Task** — 用户反馈 README 过期、条理混杂、缺 AI 适配说明；cheatsheet 命令过期（codelldb/UEAndroidDAP 旧路线）需更新扩充并纳入回归；样式更新。

**Implemented**
- `README.md` 重构为主流大项目骨架（features → platform → requirements → install → usage → docs），正式文风、Windows-only 显式声明、把「平台编译一次」列为 `:UEPrepare` 前的必需步骤；benchmark 用表+ASCII 图，头条改为 **super-unity 索引**（11,593 TU 折叠成 ~23，几小时→~3 分钟，NTFS）；新增「Built for long-term AI-assisted development」段（agent 启动流程图 + 硬数据表 19/39/9/21/14/12 + 四知识区 + DoD）。中文版拆到 `docs/README.zh-CN.md`（中英分文件、互相切换）。
- `docs/ue_lazyvim_cheatsheet.md`：DAP 段整段重写——删 codelldb 1.12.2 / `:UEAndroidDAP*` 旧路线，统一到 `:UEDAP*`；补全 `<leader>d1-d4`（DAP tab）、`d]`/`d[`、`dW`/`de`/`dh`/`dw`/`dt`/`dk`/`dj`/`dR`；补 `:UEPrepareIncremental`、`:UEDefCacheClear`；首跑流程改为 SetProject→SetPlatform→Build→Prepare；去 which-key 措辞；二级标题加 emoji + 顶部目录导航。
- `lua/utils/cheatsheet.lua`：UE/DAP 两个 float tab 内容与 markdown 对齐（Setup&Prepare / Run·Logs / First-run；Session / Breakpoints / Inspect / UI·Tabs）；**样式更新**——highlight 改为 Catppuccin Mocha 命名调色板、key↔desc 用点线连接、footer 文案更新。
- `tests/cases/cheatsheet_spec.lua`（新，粒度＝命令真实性 + 双 surface 一致）：扫 float `M.tabs` 与 markdown 的 `:UE*` 命令引用，比对 `commands_spec` 的 UE_COMMANDS 冻结清单（+UEDef* exists 校验）抓死链/过期；校验 float 关键 DAP/UE 键位在 markdown 必含（防漂移）；断言 markdown 不再以命令形式引用 `:UEAndroidDAP`。
- `tests/CLAUDE.md`：CHANGE-TO-FILTER MAP 新增 `cheatsheet` 行。

**Pitfalls / Gotchas**
- 命令真实性校验最初用 `vim.fn.exists(":Cmd")` 扫所有前缀（Theme/NvimLog/Markdown），但这些是 lazy-loaded，headless 下未加载 + 前缀歧义（`:UE` 返回 3=ambiguous）→ 大量误报。收敛为只校验 UE*（有 commands_spec 权威冻结清单，确定性强），并对正则加 `*` 边界排除 `:UEDAP*` 通配写法。

**Validation**
- `nvim --headless -l tests/run.lua cheatsheet` → 91/91。
- `nvim --headless -l tests/run.lua structure` → 36/36（README 内链）。
- 全量 `nvim --headless -l tests/run.lua` → 507/507。



**Task** — `:UEPrepare` 完成后（尤其重新编译后）`<space><space>` 仍反复弹 stale。OpenSpec change `csearch-freshness-content-fingerprint`（proposal+design 先行 validate）。

**Root cause** — `prepare_freshness` 一直用 **mtime 侧信道代理**猜「被索引文件集合是否变」，每个代理有自己的噪声：`.git/index` 被 fsmonitor/TortoiseGit 后台 touch（K30g）；`dir_mtime` 被**编译产物**落进引擎树 touch（重编即假 stale）。D8 把 git anchor 换成 commit-state 只是换噪声更小的代理，随后被 dir_mtime 击穿——换代理是无尽打地鼠。

**Implemented（D10）**
- `lua/ue.lua`：重写 `CORE_RT.prepare_freshness`——稳态判定改为 `list_fingerprint(workspace_all.files) == state.csearch_input_hash`，相等 fresh 否则 stale；保留 ① in_progress / ② never / ③ watcher dirty>0→stale。**删除整段 mtime anchor 块**及 `git_commit_state_mtime`/`git_index_mtime`/`dir_mtime` 三个辅助函数（167 行）。
- `lua/ue.lua`：新增 `CORE_RT.list_fingerprint(path)`——`vim.fn.sha256(内容)`，用文件自身 (mtime,size) 作 hash 缓存键（稳态只 stat，实测全量 46ms 仅 miss 付一次）。mtime 仅作缓存失效，判定永远是内容 hash。
- `lua/ue.lua`：新增 `CORE_RT.on_full_csearch_success(ctx, reason)`，把 D-3b 清 dirty + D10 记 `state.csearch_input_hash` 绑成一个钩子；三条全量成功路径（sync/fast-path/cold-full）统一调用，失败不调（指纹不前移于已建成索引）。
- 测试 seam：`M._list_fingerprint_for_test` / `M._reset_fingerprint_cache_for_test`。
- `tests/cases/freshness_fingerprint_spec.lua`（新，7 例）：指纹同/异/缺失/缓存 + 防回归（freshness 源不再引用任何 mtime anchor + 记录钩子存在）。
- 文档：`grep-cache-invalidation.md`（D8 退役存档 + 新增 D10 + §2/§4/§5/§6 同步）、`CONSTRAINTS.md`（K30g 收敛为「mtime 代理已退役→内容指纹」）。

**Pitfalls / Gotchas**
- 删 anchor 块时旧 `do...end` 内还残留 167 行孤儿代码（旧 git_commit_state_mtime/dir_mtime 注释体）；`loadfile` 仍 OK 是因为它们在块内但不可达——必须连同辅助函数整段删，否则误导后人。
- 内容编辑（已有文件改内容）**有意不检测**——clangd 实时感知；csearch 是文件级 trigram，集合不变不重建。这是用户定的边界，写进 spec。

**Why theoretically-perfect not patch** — 不再「换更好的代理」（无尽打地鼠），而是**直接测量被检测对象本身**（清单内容）。所有代理噪声（fsmonitor/编译/git 漏报）一次性消失：它们都不改 list 内容。被否决：换源码子目录 dir_mtime（仍代理）、per-file hash L4（UE 万级不可行）、保留 D8 兜底（冗余噪声源）——见 change design.md。

**Validation**
- `nvim --headless -l tests/run.lua freshness_fingerprint` → 7/7。
- 全量见下。

**Follow-ups**
- 升级首跑（旧 state 无 `csearch_input_hash`）会判一次 stale → 跑一次 `:UEPrepare` 即写入并转稳定。

### 2026-06-17 — csearch.idx 单写者：消除并发写损坏（corrupt index 死循环）

**Task** — `:UEPrepare` 卡在 ~85% 且刷屏 `cindex-uefilter exit=1 ... corrupt index: remove`。OpenSpec change `fix-csearch-index-single-writer`（proposal+design 已先行 validate）。

**Root cause** — cindex 原子写协议把 staged 文件硬编码为 `<idx>~`（非每进程独立临时文件）。2026-06-16 D7 把 `ue_watch` 改成 csearch.idx 的第二个写者，其 debounce 增量与用户 `:UEPrepare` 全量并发抢同一个 `idx~`，在 merge/rename 窗口互毁 → `corrupt index: remove` → 0 字节 idx 再被下一次 `mode="add"` 撞上 → 死循环。

**Implemented（三层，D9）**
- `lua/utils/ue_watch.lua`：`provider_csearch_add` 退回 **record-only no-op**——删除 `build_index` 调用 / `-files-from` 临时列表；csearch 写者收敛为 prepare 家族。新文件靠 `persistent_dirty` + rg-on-dirty overlay 到下次手动 prepare（用户已确认可接受）。更新模块 header + provider doc 声明 D9 单写者契约。
- `lua/ue.lua`：新增 `CORE_RT.csearch_build_running` + `CORE_RT.csearch_build_begin/done`（Policy A 串行守卫，挂 CORE_RT 避开 LuaJIT 200-local 上限）。三处构建入口（sync / cache fast-path / cold full）+ `:UEPrepareIncremental` 全部接入：占用中拒绝并可见提示（不排队），完成回调无条件清标志。
- `lua/utils/code_search/init.lua`：`build_index` 在 `mode="add"` spawn 前校验 `usable_index_stat(idx)`，不可用则 `cb(false, "...run :UEPrepare")` 不 spawn；`mode="reset"` 不受限。新增 `M._usable_index_for_test`。
- `tests/cases/ue_watch_csearch_spec.lua`：改写为 D9 契约——静态+行为守护「watcher 不写 csearch 索引」（防回归：重新接回写者即测红）。
- `tests/cases/csearch_build_guard_spec.lua`（新，8 例）：构建串行（begin/拒绝/done/失败也清）+ 增量遇 0 字节·缺失 idx 被拒不 spawn + `_usable_index_for_test` + 全量成功清 dirty（D-3b）。
- **D-3b（dirty 清理层，apply 中发现的 D9 缺口）**：`lua/ue.lua` 新增 `CORE_RT.clear_persistent_dirty_safe`（soft-require ue_watch）；三条全量成功路径（sync / cache fast-path / cold full）成功分支统一调用，**失败不清**。修复「UEPrepare 完仍弹 stale + `<space><space>` 变卡」——β 把 watcher 退出写者后，清 dirty 的责任转移给 prepare，但初版只有 cold-full 清，fast-path/sync 漏清 → dirty.json 残留（实测 110 KB）→ `prepare_freshness` 第一道闸恒判 stale + overlay 背巨大脏集合变卡。
- 文档：`grep-cache-invalidation.md`（D7 退役存档 + D9 含 D-3b 清理层 + §3/§4/§5/§6 同步）、`CONSTRAINTS.md`（K31g 含 D-3b 二次症状、K29 标注被取代）。spec 新增「全量成功后 dirty 归零」Requirement。

**Pitfalls / Gotchas**
- 把 `csearch_build_begin/done` 作 main-chunk `local function` 会顶破 LuaJIT 200-local 上限（`main function has more than 200 local variables`）→ 改挂 `CORE_RT.*`。
- `ue_watch_csearch_spec` 的静态护栏须用 `code_search%.build_index%s*%(`（带括号）匹配「调用」，否则 provider doc-comment 里「不得 re-add build_index」的文字会误判为违规。

**Why not workaround** — 这是修我们自己的设计缺陷（D7 把 watcher 变第二写者），按 C2 落主逻辑配普通注释 + spec `SHALL` + 防回归测，不进 `lua/workarounds/`。被否决方案（α 锁 / γ 双索引 / Policy B 排队）见 change design.md。

**Validation**
- `nvim --headless -l tests/run.lua ue_watch_csearch` → 5/5；`csearch_build_guard` → 6/6。
- 全量见下（提交前跑）。

**Follow-ups**
- 无。单写者已写成 `ue-code-search` spec 的 `SHALL` + 行为测护栏。

### 2026-06-16 — tests: activate dormant DAP seams + F9 persistence round-trip (K-pitfall → behavioral)

**Task** — Deepen debugger test coverage for long-term stability. Strategy (from explore session): migrate hard-won DAP knowledge from source-text grep assertions toward pure-function behavioral tests, prioritizing already-extracted-but-unexercised `_for_test` seams, and annotate each debugger case with the K-pitfall it guards.

**Implemented**
- `lua/ue/dap/android.lua` — added `M._attach_commands_for_test(session)` seam over the pure `attach_commands(session)` builder (no device/adb needed).
- `lua/ue/dap/_persist_bp.lua` — added pure test seams `M._norm_for_test`, `M._json_round_trip_for_test`, `M._project_name_for_test`, `M._save_with_state_for_test`, `M._reset_state_for_test` (JSON + path-normalization logic only; never a live nvim-dap session).
- `tests/cases/dap_spec.lua` — +21 behavioral cases driving the previously-dormant seams:
  - `pick_symbol_lib` (K35 + 3.4 false-lead): versionCode exact-match beats mtime-newest; ctx > config > auto-discover precedence.
  - `pick_package`: ctx > config > packageInfo.txt first-line.
  - `pick_lldb_server` (C1): preserves platform glob priority order (no resort); config override; nil on no hit.
  - `effective_project_root`: Android-marker'd candidate wins.
  - `attach_commands` (K30/K34/K37): `target create` symbol-rich FIRST and before connect/attach; serial-bracket `connect://[serial]:port` (never localhost); signal handling after attach; explicit slide present by default and skipped under `UE_DAP_NO_SLIDE=1`.
  - `_persist_bp` (K10): JSON round-trip shape preservation; backslash/forward-slash key normalization; project_name sanitize; **save merges pending_paths so unopened-file breakpoints are not erased** (the documented disaster scenario).
- Annotated existing debugger cases with their guarded K-numbers (K10/K33/K34/K36/K37).
- `docs/CONSTRAINTS.md` — K10/K30/K35/K37 entries now point at their backing behavioral tests.

**Pitfalls / Gotchas**
- The 8 existing INVARIANT cases that grep `dap.lua`/`android.lua` source text are kept (they guard "the misleading name must not return" structural facts that have no pure-logic form), but new coverage is behavioral wherever a seam exists. Source-grep that targets the third-party `nvim-dap/lua/dap/session.lua` remains the one acceptable exception (it documents an upstream contract we depend on).
- `cfg.reset_for_test()` is called before AND after each config-touching case so a setup() override can't leak across cases.

**Validation**
- `nvim --headless -l tests/run.lua dap` → 44/44 passed (was 20).
- `nvim --headless -l tests/run.lua platform` → 10/10 passed.
- Full suite below.

**Follow-ups**
- `module_rebase_command` / `read_so_base_hex` (ASLR base parsing from /proc/maps) still lack seams — they need adb stubbing; candidate for a future round.

### 2026-06-16 — ue_watch: incremental csearch via -files-from, not argv fan-out (fix ENAMETOOLONG)

**Task** — `ue_watch`'s debounce flush threw `vim/_system.lua:256: ENAMETOOLONG: name too long` after a `git checkout` / build. User required this be a permanent correct fix, not a workaround.

**Root cause** — `provider_csearch_add` built the indexer invocation as `cmd = {"cindex"}; for p in paths do table.insert(cmd, p) end` — one dirty path per argv element. A checkout/build batches hundreds of long UE paths (~80–120 chars each) into one flush; the assembled command line blows Windows' ~32 KiB argv limit. Two further defects rode along: it called bare `cindex` (not the repo-canonical `cindex-uefilter`, which alone supports `-files-from` and UE-path filtering) and `:wait()`-blocked the UI thread (violates P6 / C4 conv #2).

**Why this is the correct fix, not a workaround** — argv length is an OS contract, not an upstream bug that could be "fixed away"; feeding an arbitrary-length path list to a child process via a `-files-from` file is the permanently right design (the very reason `cindex-uefilter` exists). The change converges the watcher onto the already-vetted incremental path `:UEPrepareIncremental` uses. Nothing here is "patch around someone else's bug" → lives in main logic with plain comments, NOT `lua/workarounds/` (per C2: a fix that IS the right answer is not a workaround).

**Implemented**
- `lua/utils/ue_watch.lua` — rewrote `provider_csearch_add`: writes dirty paths to `<csearch_index>.incremental.txt`, calls `require("utils.code_search").build_index({ csearch_idx = <index> }, list, cb, { mode = "add" })`, removes the temp file in the callback. Probes `cindex_uefilter_exe()` and the `build_index` API up front, returning explicit failure (not silent) when unavailable. Async — no `:wait()`.
- `lua/utils/ue_watch.lua` — added the `-files-from`/argv-limit rule to the module's "Design constraints" header and a full provider-doc comment explaining the OS-contract rationale.
- `lua/utils/ue_watch.lua` — added test seams `M._provider_csearch_add_for_test` + `M._set_opts_for_test` (non-runtime API).
- `tests/cases/ue_watch_csearch_spec.lua` (new, 7 cases) — static guards that argv fan-out / bare `cindex` cannot return; behavioral test with a stubbed `code_search` backend asserting the provider routes through `build_index{mode="add"}` with the dirty paths written to the `-files-from` list and the temp file cleaned up; no-op on empty, explicit failure on missing index config / missing `cindex-uefilter`.

**Pitfalls / Gotchas**
- `cindex-uefilter` (not bare `cindex`) is the repo-wide canonical indexer; bare `cindex` lacks `-files-from` and UE-path filtering (code_search/CLAUDE.md). The old provider was a pre-2026-05-28 leftover that never adopted the `build_index{mode="add"}` path the rest of the system standardized on.
- Provider failures are logged, not propagated: the flush is fire-and-forget on the scheduler, and the cumulative `persistent_dirty` set + rg-on-dirty overlay already cover any path that misses a given flush.

**Validation**
- `nvim --headless -l tests/run.lua ue_watch_csearch` → 7/7 passed.
- `nvim --headless -l tests/run.lua utils` → 30/30 passed.
- Full suite `nvim --headless -l tests/run.lua` → 382/382 passed (covers both 2026-06-16 entries: ue_watch + freshness anchor).

**Follow-ups**
- None. Module design captured in `docs/architecture/grep-cache-invalidation.md` D7; pitfall in `docs/CONSTRAINTS.md` K29.

### 2026-06-16 — grep freshness: anchor on git commit-state, not .git/index (kill phantom "stale" after UEPrepare)

**Task** — On a UE git worktree, `<space><space>` / `<leader>/` kept warning `:UEPrepare is stale (worktree changed since last run)` immediately after a successful `:UEPrepare`, even though no source file had changed. User report: "我已经 UEPrepare! 了为什么 space space 找文件还会提示 stale".

**Root cause** — `prepare_freshness` anchored list freshness on `.git/index` mtime. On UE worktrees the engine `.git` is a `gitdir:` pointer into the main repo's `worktrees/<name>/` (here `D:/project/uetemp/.git` → `D:/project/UnrealEngine/.git/worktrees/uetemp`), and that per-worktree `index` is re-touched minutes after UEPrepare by git's always-on `fsmonitor--daemon` and TortoiseGit background refresh — without the working-tree file SET changing. So `index_mtime > list_mtime` → false "stale". (Observed: list 18:35:44, index re-touched 18:46:40 → 18:57:20 by background tooling.)

**Implemented**
- `lua/ue.lua`: replaced `git_index_mtime(repo_root)` with `git_commit_state_mtime(repo_root)` — same worktree-aware `.git` / `gitdir:` resolution, but anchors on the newest mtime of `HEAD` + `logs/HEAD` (commit-state) instead of `index` (staging area). `logs/HEAD` appends on every ref movement (commit / pull / merge / rebase / reset / checkout), so it captures fast-forwards that leave `HEAD`'s symref text unchanged.
- Updated the two anchor call sites in `CORE_RT.prepare_freshness` and the anchor-list doc comments (anchors #1/#2 now "git commit-state (HEAD + logs/HEAD)").
- Uncommitted/unstaged new-file detection is unchanged — still covered by the `ue_watch` dirty overlay and the `dir_mtime` anchors, which is why dropping `index` loses no real-change coverage.

**Pitfalls / Gotchas**
- `index` is NOT a proxy for "file population changed": fsmonitor / TortoiseGit / background `git add` / build artifact staging all bump it. It was redundant with the watcher+dir anchors for the add/remove case and actively harmful for the refresh case.
- A linked worktree has per-worktree `HEAD`/`logs/HEAD` under `worktrees/<name>/`, so a branch switch in THIS worktree still shows and sibling worktrees of the same main repo don't bleed in.

**Validation**
- `nvim --headless -l tests/run.lua grep_cache` → 21/21 passed.
- Full suite `nvim --headless -l tests/run.lua` → 375/375 passed.
- Live anchor recompute against the user's real cache: new anchors max = `dir_mtime` 18:02:50 < list 18:35:44 → `fresh` (was `stale` under the old `index` 18:57:20 anchor).

**Follow-ups**
- None. `index`-based detection intentionally retired; `UE_DAP_*`-style escape hatch not added (watcher overlay already covers the uncommitted-add edge).

### 2026-06-15 — docs/test: harden + preserve the live-breakpoint experience (ADR, behavioral tests, knowledge base)

**Task** — The session-time live-breakpoint work (previous entry) is load-bearing and hard-won; preserve it against regression and knowledge loss via behavioral tests, an ADR, and knowledge-base updates (user request: "保留这次的经验不被破坏").

**Implemented**
- **Refactored for testability** (`lua/ue/dap.lua`): extracted two pure helpers from `ue_android_live_plant_via_evaluate` — `ue_android_live_plant_command(source, line)` (builds the backtick `breakpoint set -f <basename> -l <N>` command, reusing the proven preseed basename form) and `scan_breakpoint_resolved(text)` (parses `resolved = N` from a `breakpoint list` dump — the honest-verified signal). Exposed as `D._live_plant_command_for_test` / `D._scan_breakpoint_resolved_for_test`. Behavior unchanged; the inline parser in the listener now calls the shared helper.
- **Behavioral tests** (`tests/cases/dap_spec.lua`): added 3 behavioral cases (live-plant command basename form; rejects invalid line/empty source; resolved-parser resolved>0 vs 0/nil vs multi-block) that lock the *behavior* not just source text, plus 3 INVARIANT guards: nvim-dap `before.setBreakpoints` runs in the response pipeline (no before-request hook — also asserts the misleading `*_source_rewrite` name stays gone), live plant never fakes success / never detach+reattach, and the ASLR slide stays load-bearing with the `UE_DAP_NO_SLIDE` reverify switch.
- **ADR** (`docs/plans/2026-06-15-android-dap-live-breakpoints.md`): full decision record — D1 gate methodology, D2 channel priority, D3 preseed downgrade, D4 honest verified, D5 (rejected slide removal), D-OQ5 synthetic-frame chokepoint, the invariants table mapping each to its test guard, the 4 hard-won pitfalls, rejected approaches, rollback point. Registered in `decisions/README.md` and `docs/plans/README.md` (new "Android DAP series (2026-06)" section).
- **Knowledge base**: `lessons/README.md` K30–K33 section expanded to K30–K37 (K34 not-reproducing, K36 live evaluate channel, K37 slide load-bearing); `K1–K33` → `K1–K37`; adapter arc updated to LLVM 22.1.6+ forward-only. `lua/ue/dap/CLAUDE.md` gained local rules for K36/K37, the no-before-request-hook gotcha, and the synthetic-frame chokepoint, plus ADR/evidence pointers in 先读.

**Pitfalls / Gotchas**
- The previous entry's tests were pure source-text greps — brittle and they don't prove the logic. Extracting pure helpers behind `_for_test` seams (mirroring `android.lua`'s existing `_*_for_test` pattern) lets the harness assert real behavior without a live adapter or device.
- `structure_spec` guards internal-link integrity across the knowledge base, so every new doc pointer (ADR path, evidence dir) must resolve — verified via full regression below.

**Validation**
- `nvim --headless -l tests/run.lua dap` → 23/23 passed (was 17; +6 behavioral/invariant cases).
- `nvim --headless -l tests/run.lua` → full regression (run below).

**Follow-ups**
- If nvim-dap ever adds a true before-request hook, the INVARIANT test for the response-pipeline assumption will flag it — revisit the setBreakpoints recovery then.

### 2026-06-15 — feat(dap/android): session-time live breakpoints + synthetic-frame convergence + cleanup

**Task** — Eliminate the "must `:UEDAPReattach`" work-around for session-time F9 breakpoints on UE Android attach (change `android-dap-live-breakpoints`). Prove on-device whether live planting is feasible, wire the proven channel, and do the unconditional cleanup (dead code, no-op push, stale comments, synthetic-frame guard convergence).

**Implemented**
- **Live breakpoint path (the proven fix, not a work-around):**
  - `lua/ue/dap.lua` `ue_android_live_plant_via_evaluate()`: new helper that plants session-time breakpoints via the lldb-dap evaluate backtick `breakpoint set -f "<basename>" -l <N>` channel (design D2-B), reusing the proven `ue_android_breakpoint_source` basename form. Reads back `breakpoint list resolved=N`; on `resolved=0` or command error it surfaces an honest `vim.notify` (throttled via `D._ue_android_bp_notice_until_ms`) — MUST NOT fake success, MUST NOT detach+reattach.
  - `dap.listeners.after.setBreakpoints["ue_android_bp_local_response"]`: after `configurationDone`, routes session-time changes through the live plant instead of the old reattach warning. Recovers the requested file:line from the `request` payload (with a `before.setBreakpoints` snapshot fallback). Initial (pre-gate) setBreakpoints stays owned by attachCommands preseed.
  - Renamed `before.setBreakpoints["ue_android_bp_source_rewrite"]` → `["ue_android_bp_record_request"]`; documented that nvim-dap's `before.setBreakpoints` fires in the RESPONSE pipeline (signature `session, err, response, request, seq`), so it records the outgoing shape rather than mutating it.
  - Removed the active-session "are not silently reattached / use :UEDAPReattach" warning block.
- **Synthetic-frame guard convergence:** added `ANCHOR(ue-synthetic-frame-guard)` doc-block on `frame_is_synthetic_or_invalid` naming the upstream nvim-dap `jump_to_frame` root cause; cross-referenced the three sites — `ANCHOR-USE:stackTrace` (the chokepoint), `ANCHOR-USE:_frame_set` (thin guard), `ANCHOR-USE:bp-response` (orthogonal path remap). No external behavior change. Recorded the D-OQ5 decision (stackTrace layer) in design.md.
- **Unconditional cleanup:** `_common.lua` removed the dead `if false and …` adapter short-circuit (now always re-wires, comment explains env refresh); `_persist_bp.lua` fixed the no-op `set_breakpoints({ [bufnr] = nil })` to push the real restored list; `dap.lua` corrected the stale `dap.terminate` comment (`request="launch"` → `request="attach"`).
- **ASLR slide D5 verification:** added `UE_DAP_NO_SLIDE` env switch in `lua/ue/dap/android.lua` to skip the explicit `target modules load --slide`. On-device verification showed the slide is **load-bearing** on this device (no-slide → attach timeout / `3221226505`), so the slide + plumbing were **kept**, not removed.
- **Tooling/evidence:** new `tools/nvim_android_dap_livebp_gate.lua` (D1 feasibility gate, `NVIM_DAP_LIVEBP_CHANNEL=evaluate|setbreakpoints`) and `tools/nvim_android_dap_livebp_e2e.lua` (production-path E2E). Evidence under `tools/evidence/android-f9/` with README index.
- **Tests:** `tests/cases/dap_spec.lua` — replaced the warning-gate assertion with "session-time setBreakpoints is gated and planted live (not warned)" (asserts the reattach warning is gone + live plant present); added "synthetic-frame guards converge on a single annotated chokepoint" (ANCHOR markers).
- **Docs/spec:** `docs/CONSTRAINTS.md` K34 marked not-reproducing on current route; added K36 (live evaluate channel is the proven fix) and K37 (slide load-bearing). `docs/TOOLING.md` session-time F9 section rewritten for the live channel. `openspec/specs/android-dap-attach/spec.md` gained the "会话中 F9 变更经 live 通道即时下发" requirement + scenarios.

**Pitfalls / Gotchas**
- nvim-dap has **no before-request hook**: `listeners.before.setBreakpoints` runs in `handle_body`'s response pipeline (session.lua L1104-1109), same args as the after-listener. You cannot mutate the outgoing `args.source` there. The original `ue_android_bp_source_rewrite` name was misleading; the real wire-side basename match is owned by attachCommands + DWARF. Recovering the requested lines must read the stored `request` payload (`message_requests[seq]`), which is handed to both before- and after-listeners.
- The D1 gate plants with its OWN channel code, so a passing gate does not prove the *wired* production listener works. The separate `livebp-e2e.lua` harness drives the real F9 flow (`dap.breakpoints.set` + `session:set_breakpoints`) and asserts `production_live_plant_diag=true` + `saw_reattach_warning=false`. First E2E run showed the production listener saw `line_count=0` (recovered from the wrong payload field) until the `request`-payload recovery was added.
- The `3221226505` adapter exit on session teardown is expected (lldb-dap exits when we disconnect); it is NOT the K34 crash — `adapter_alive=true` is captured *before* teardown and the breakpoint hit precedes it.
- Device residue (stray `lldb-server`, accumulated `adb forward`) caused false no-slide timeouts; `pkill -f lldb-server` + `adb forward --remove-all` between runs is required for clean D5 measurement.

**Validation**
- D1 gate (device `2e2df4cb`, target `MobileShadingRenderer.cpp:1367`, 3.5 matching symbols): channel B (evaluate) `resolved_after_plant=1`, `saw_breakpoint`, `stop.reason="breakpoint"`, `adapter_alive` → `livebp-gate.evaluate.result.json`; channel A (setBreakpoints) same hit → `livebp-gate.setbreakpoints.result.json`. **Conclusion: live feasible → 2A branch.**
- Production E2E (`livebp-e2e.result.json`): `production_live_plant_diag=true`, `saw_reattach_warning=false`, `breakpoint list resolved=1`, `stop.reason="breakpoint"` hits.
- D5 slide check: `UE_DAP_NO_SLIDE=1` → attach timeout / `3221226505` (`noslide-preseed.result.json`); slide-present baseline immediately hits (`slide-recheck.result.json`) → slide kept.
- `nvim --headless -l tests/run.lua dap` → 17/17 passed.
- `nvim --headless -l tests/run.lua` → 369/369 passed (full regression).
- `openspec validate android-dap-live-breakpoints` → (run below).

**Follow-ups**
- 2B branch (live-infeasible) is N/A — gate proved feasibility. Slide removal (5.2) deferred: re-verify `UE_DAP_NO_SLIDE` on other devices/Android versions before removing the plumbing.

### 2026-06-15 — fix(dap/android): drop hardcoded 3.4 symbol_lib fallback + archive smoke evidence

**Task** — Remove the hardcoded banned 3.4 symbol library fallback that could silently short-circuit symbol auto-discovery, and tidy the F9 smoke evidence trail.

**Implemented**
- `lua/ue/dap/android.lua` `bootstrap_session`: removed the literal `E:/aki/zeqiang_aki_3.4/.../Client_Symbols_v170300916/Client-arm64/libUE4.so` fallback from the `ctx.android_symbol_lib` assignment. A literal path makes `pick_symbol_lib()` step 0 return it verbatim and skip the `packageInfo.txt` versionCode exact-match, so a stale build-id (`ad3d4e7c…`, 3.4) would attach and resolve breakpoints against the wrong source revision. Now falls through to config → packageInfo versionCode → newest-by-mtime glob → prompt (mirrors the `pick_package` nil fallthrough from `361b9e7`).
- `tests/cases/dap_spec.lua`: added "bootstrap does not hardcode a symbol_lib fallback path" guarding against any `or "...libUE4.so"` fallback or string-literal `android_symbol_lib` assignment in `android.lua`.
- `tools/evidence/android-f9/`: moved the five `nvim_android_dap_smoketest.*.result.json` smoke captures out of `tools/` into a dedicated evidence dir with a `README.md` index; updated the reference in `openspec/changes/fix-android-f9-breakpoint-hit/code-behavior-audit.md`.

**Pitfalls / Gotchas**
- The dangerous shape is specifically `... or "<path>.so"`: it forces a concrete library regardless of the installed APK build-id. The fix relies on `pick_symbol_lib`'s existing discovery chain, which already cross-matches the device versionCode — the hardcoded default was actively defeating it.
- HEAD before this work still carried the `schedule_reattach` auto detach+reattach commits (`361b9e7`/`33fb69b`/`32c156f`); the working tree had already reverted them to the honest-warning design. This entry's edits sit on top of that honest-warning working tree, which `dap_spec` ("setBreakpoints must not silently detach and reattach") locks in.

**Validation**
- `nvim --headless -l tests/run.lua dap` → 16/16 passed (added the hardcode guard).
- `nvim --headless -l tests/run.lua structure` → 36/36 passed (evidence move did not break dir/structure guards).
- `nvim --headless -l tests/run.lua` → 368/368 passed (full regression).
- `openspec validate fix-android-f9-breakpoint-hit` → passed.
- Source grep confirms no remaining `zeqiang_aki_3.4` / `Client_Symbols_v170300916` literal outside an explanatory comment.

**Follow-ups**
- Optional: cross-check the picked symbol lib build-id against the device `libUE4.so` build-id at attach time and WARN on mismatch (honest-first), rather than trusting mtime alone.

### 2026-06-15 — fix(dap/android): make F9 breakpoint handling evidence-driven

**Task** — Rework the Android F9 breakpoint fix around the actual code path, removing false-success behavior and stale attach-route assumptions.

**Implemented**
- `lua/ue/dap/android.lua`: made Android attach-time breakpoint preseed the single owner, handling bufnr-keyed and path-keyed nvim-dap breakpoints, inserting quiet `breakpoint set` commands after signal disposition/ASLR rebase, and logging the final attach/post-run command set plus `breakpoint list` to `ue-dap-bp-diag.log`.
- `lua/ue/dap.lua`: removed the duplicate Android attachCommands injector, dead synthetic breakpoint response, and silent auto reattach; active-session F9 changes now log real `setBreakpoints` responses and warn that explicit `:UEDAPReattach` is required unless a safe live command path is proven.
- `tests/cases/dap_spec.lua`: added regressions for bufnr/path breakpoint collection, preseed insertion after ASLR rebase, immediate `breakpoint list`, and absence of the old duplicate preseed / auto-reattach paths.
- `tools/nvim_android_dap_smoketest.lua`: updated the smoke harness to load `nvim-dap` under `nvim --headless -l`, use the current `ue.dap.android.attach()` path, honor explicit project/device/symbol env vars, write result files relative to the startup cwd, and continue through attach `SIGSTOP` without invoking the interactive `dap.continue()` prompt.
- `tools/nvim_android_dap_smoketest.lua`: debounced the lldb-dap per-thread entry-stop burst before auto-continue, so the harness no longer races hundreds of `SIGSTOP` events and creates false `invalid thread` noise while proving breakpoint behavior.
- `tools/nvim_android_dap_smoketest.lua`: installs `ue.setup_dap()` in headless mode before attach, captures LLDB console output into the result JSON, and parses `breakpoint list`, target `image lookup`, and DAP `setBreakpoints` responses into machine-readable fields.
- `lua/ue/dap.lua`: skips custom source navigation for Android attach entry/SIGSTOP events while preserving breakpoint-stop navigation, keeping attach noise out of the F9 success path.
- `lua/ue/dap.lua`: rewrites Android synthetic stackTrace frames to non-jumpable `line=-1` placeholder sources, avoiding both cursor `E474` and `Source missing` notifications while preserving frame IDs for scopes.
- `lua/ue/dap.lua`: gates the Android active-session F9 warning behind `configurationDone`, so the initial DAP `setBreakpoints` sync for attach-before breakpoints is logged but no longer misreported as a user session-time change.
- `docs/CONSTRAINTS.md`, `docs/TOOLING.md`, and `openspec/specs/android-dap-attach/spec.md`: aligned the documented Android route with K30 serial-form platform mode and made F9 success require LLDB `resolved>0`, adapter liveness, breakpoint stop event, and source-frame mapping.
- `openspec/changes/fix-android-f9-breakpoint-hit/code-behavior-audit.md`: recorded the current F9 keymap, persistence, attach preseed, active-session `setBreakpoints`, and source-navigation design before applying runtime edits.

**Pitfalls / Gotchas**
- F9 only mutates nvim-dap's local breakpoint store; LLDB sees it only through attach-time preseed or the active-session DAP `setBreakpoints` path.
- Session-time F9 is not safely equivalent to an immediate Android LLDB breakpoint today. The old silent detach/reattach made that look instant while changing the user's session under the hood.
- Address breakpoint fallback and immediate LLDB command updates are intentionally not enabled without live proof that they map to the same source line and keep `lldb-dap` alive.
- Early attach-before smoke proved a narrower failure layer than the original symptom: with the old 3.4 symbol lib, LLDB resolved file:line breakpoints but to code that did not match the user's local source revision.
- The smoke harness must install the same `ue.setup_dap()` listeners used by real Neovim before attach; otherwise stackTrace/source guards are absent and line-0 attach frames create harness-only noise.
- nvim-dap's initial `setBreakpoints` sync happens during session configuration even for attach-before breakpoints that were already preseeded into LLDB. Treating every Android `setBreakpoints` response as a session-time F9 change creates a false warning on the successful path.
- Stripping `source` from all-synthetic Android frames avoids dap-src cursor errors but makes upstream nvim-dap emit `Source missing`; `line=-1` placeholder sources are the quieter non-jumpable shape.
- The current `MobileShadingRenderer.cpp` on disk does not match the line table embedded in `Client_Symbols_v170300916/Client-arm64/libUE4.so`: local line 1367 is `Scene->UpdateMobileShadowSpotlight(nullptr);`, but LLDB resolves both source lines 1367 and 1369 to the compiled block at `FMobileSceneRenderer::Render + 672`, whose surrounding disassembly is the sky-atmosphere path. This is a source/symbol revision mismatch, not app-output evidence.
- The matching symbol lib is the 3.5 `Client_Symbols_v171457238/Client-arm64/libUE4.so` build-id `648da3d17f2ac45ad0a6c5c1166cb248ae0baa1c`; with that symbol source, `MobileShadingRenderer.cpp:1367` resolves to the user's target line and hits.

**Validation**
- `nvim --headless -l tests/run.lua dap` -> 14/14 passed after the smoke parser and synthetic-frame guard updates.
- Live Android smoke on `2e2df4cb`, `<android-package>`, fresh pid `25401`: `LaunchEngineLoop.cpp:4803` preseeded after ASLR rebase, `breakpoint list` resolved to `FEngineLoop::Tick() + 88`, DAP `setBreakpoints` returned `verified=true`, continue succeeded, and no `3221226505`; no breakpoint stop within 180s.
- Live Android smoke on `2e2df4cb`, fresh pid `27308`: `MobileShadingRenderer.cpp:1361` preseeded after ASLR rebase, `breakpoint list` resolved to `FMobileSceneRenderer::Render(...) + 588`, DAP `setBreakpoints` returned `verified=true`, continue succeeded, and no `3221226505`; no breakpoint stop within 180s.
- Live Android smoke on `2e2df4cb`, fresh pid `27308`: after entry-stop debounce, `LaunchEngineLoop.cpp:4803` preseeded after ASLR rebase, `breakpoint list` resolved to `FEngineLoop::Tick() + 88`, continue succeeded after 174 entry stops, adapter stayed alive, and no `invalid thread` storm; no breakpoint stop within 120s while the device remained on the GM/login screen.
- Live Android smoke on `2e2df4cb`, active pid `27308`, target `MobileShadingRenderer.cpp:1369`: result JSON captured `breakpoint list` with `locations=1`, `resolved=1`, `hit count=0`, location `FMobileSceneRenderer::Render(...) + 672 at MobileShadingRenderer.cpp:1369:8`, address `0x0000007838794c4c`; target `image lookup` returned four line matches; DAP `setBreakpoints` returned adapter-native `verified=true` and local source mapping; no `reason="breakpoint"` stop within 120s.
- The same `1369` smoke emitted the active-session reattach warning, did not emit `Vim:E474` or `Source missing`, left `<android-package>` alive with `TracerPid=0`, and left no `lldb-server` process.
- Local LLDB symbol audit with `C:/tools/llvm-22.1.6/bin/lldb.exe`: `image lookup --file MobileShadingRenderer.cpp --line 1367` and `--line 1369` both resolve to `FMobileSceneRenderer::Render(...) + 672/+676/+712/+720 at MobileShadingRenderer.cpp:1369:8`; disassembly around `libUE4.so[0xef74c4c]` shows the resolved block is gated by `ShouldRenderSkyAtmosphere`, while the currently checked-out local source has `Scene->UpdateMobileShadowSpotlight(nullptr);` at line 1367.
- Build-id audit: device `libUE4.so` is `648da3d17f2ac45ad0a6c5c1166cb248ae0baa1c`; old 3.4 symbol lib is `ad3d4e7c5f83823edbea33d7a9d5b13cb9153afc`; 3.5 `Client_Symbols_v171457238/Client-arm64/libUE4.so` matches the device build-id.
- Local LLDB symbol audit with the matching 3.5 lib: `image lookup --file MobileShadingRenderer.cpp --line 1367` returns one match, `FMobileSceneRenderer::Render(...) + 616 at MobileShadingRenderer.cpp:1367:2`, address offset `libUE4.so[0x00000000166e9a80]`.
- Live Android smoke on `2e2df4cb`, active pid `27308`, target `D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp:1367`, matching 3.5 symbols: preseeded breakpoint resolved to `address=0x000000783ff09a80`, continue ran after 179 attach SIGSTOP entry stops, then DAP emitted `reason="breakpoint"` / `description="breakpoint 1.1 2.1"` with `hitBreakpointIds=[1,2]`.
- The same matching-symbol smoke captured stackTrace frame 0 as `FMobileSceneRenderer::Render(FRHICommandListImmediate&, bool)` at local source `D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp:1367`, proving the stop-frame local source mapping.
- Post-smoke system cleanup: `<android-package>` remained alive at pid `27308`, `/proc/27308/status` reported `State: S (sleeping)` and `TracerPid: 0`, `pidof lldb-server` returned none, and host `Get-Process lldb/lldb-dap` returned none.
- Local LLDB symbol audit with `C:/tools/llvm-22.1.6/bin/lldb.exe`: `image lookup --name FEngineLoop::Tick` resolved to `D:\project\uetemp\Engine\Source\Runtime\Launch\Private\LaunchEngineLoop.cpp:4802`; source-file `breakpoint set -f LaunchEngineLoop.cpp -l 4802/4803` resolved under K30 without adapter crash, so address fallback remains intentionally unimplemented.
- Full regression `nvim --headless -l tests/run.lua` -> 366/366 passed.
- `openspec validate fix-android-f9-breakpoint-hit` -> passed.

**Follow-ups**
- Only implement address fallback or active-session immediate breakpoint commands after live evidence proves source-file breakpoints are pending/crashing or the command path is stable.

### 2026-06-12 — fix(ue): make UE grep ignore CVar camelCase by default

**Task** — Continue the `<leader>/` result-completeness fix for the actual query `r.useLandscape`; the picker was still missing expected mixed-case CVar hits.

**Implemented**
- `lua/utils/code_search/init.lua` `stream_csearch`/`stream_rg`: added `ignore_case=true` as an explicit mode, separate from legacy smart-case, so callers can force case-insensitive literal searches unless `case=true`.
- `lua/ue.lua` `cached_grep`: made both csearch and rg-backed UE grep default to ignore-case; Alt-C still switches to strict case-sensitive mode.
- `lua/ue.lua` `cached_grep`: added temporary always-on backend debug logging to `stdpath("state") .. "/ue_grep_backend_debug.log"` while this issue is being verified live.
- `lua/ue.lua` `cached_grep`: fixed the csearch picker drain queue to track `pending_len` explicitly instead of using `#pending` after drained entries are set to nil.
- `tests/cases/utils_spec.lua`: added an rg streaming regression where `r.useLandscape` matches `r.UseLandscapeSrvBuffer`.
- `tests/cases/grep_cache_spec.lua`: added static coverage that UE grep wires ignore-case by default and that the csearch drain loop does not use `#pending` for a holey queue.

**Pitfalls / Gotchas**
- `r.useLandscape` contains an uppercase `L`, so smart-case treats it as case-sensitive and misses source/config spellings like `r.UseLandscapeSrvBuffer`.
- The live debug log showed the real remaining loss: csearch returned `recv=15` for `r.usela`, but the picker emitted only 12. The drain loop nilled old queue entries for GC and then used `#pending`; Lua length on a table with holes is undefined, so final tail hits could be skipped.
- Direct `rg -i -F "r.useLandscape"` over the active engine+project returned 14 hits; csearch with the new ignore-case stream returned the same 14, so the indexed result set now matches the direct scan for this exact query.

**Validation**
- `nvim --headless -l tests/run.lua utils` → 30/30 passed.
- `nvim --headless -l tests/run.lua grep_cache` → 21/21 passed.
- Real csearch stream probe from `D:/project/uetemp` for `r.useLandscape` with `ignore_case=true` → 14 hits, `code=0`.
- Direct `rg -n -i -F "r.useLandscape"` over `D:/project/uetemp/Engine` + `E:/aki/zeqiang_aki_3.5/Source/Client` → 14 hits.
- Full regression: `nvim --headless -l tests/run.lua` → 360/360 passed.

**Follow-ups**
- Remove the temporary `ue_grep_backend_debug.log` writer after the user confirms the live picker is fixed.

### 2026-06-12 — fix(ue): stop UEPrepare clangd error and guard live grep typing

**Task** — Fix two fresh regressions reported after the grep work: `:UEPrepare` surfaces an err from clangd startup, and `<leader>/` can freeze/crash while typing a search.

**Implemented**
- `lua/ue.lua` `clangd_cmd`: changed `--function-arg-placeholders` to `--function-arg-placeholders=true`, matching clangd 22's boolean flag parser.
- `lua/ue.lua` `cached_grep`: added a two-character live-search gate and a short-input result cap for csearch, while preserving the existing 5000-result cap for longer queries.
- `lua/ue.lua` `cached_grep`: forced the picker title to append the actual backend (`[csearch]` or `[rg]`) even when the caller passes a custom title.
- `lua/utils/code_search/init.lua`: recover from `cindex-uefilter` leaving a valid staged `csearch.idx~~`/`csearch.idx~` next to an empty final `csearch.idx`, and stop reporting cindex success when no usable final index exists.
- `tests/cases/ue_api_spec.lua`: added regression coverage for the clangd flag format.
- `tests/cases/grep_cache_spec.lua`: added regression coverage for the live grep input gate and backend title marker.
- `tests/cases/utils_spec.lua`: added regression coverage for staged csearch index recovery.

**Pitfalls / Gotchas**
- clangd 22 rejects the historical bare boolean flag and logs `Value specified by --function-arg-placeholders is invalid`; this shows up after `:UEPrepare` because the command refresh path restarts LSP.
- snacks live pickers refresh on typed input, so a one-character UE-wide grep can flood thousands of items before the user finishes the query.
- A successful `cindex-uefilter` process can still leave the large index in `csearch.idx~~` while `csearch.idx` is empty; the picker must treat that as recoverable, not as “no csearch”.

**Validation**
- `nvim --headless -l tests/run.lua ue_api` → 34/34 passed.
- `nvim --headless -l tests/run.lua grep_cache` → 19/19 passed.
- `nvim --headless -l tests/run.lua utils` → 29/29 passed.
- Real cache repair: restored `D:/project/uetemp/.cache/nvim-ue/csearch/Android-Development/csearch.idx` from the valid staged index; final index is >300 MB.
- Real backend probe from `D:/project/uetemp`: `current_backend(...)` → `csearch`, title seam → `Grep All Code (Engine+Project) [csearch]`.
- Real csearch stream probe for `VulkanRHI` with `max_count=1` → 1 hit, `on_done=true`.
- Full regression: `nvim --headless -l tests/run.lua` → 357/357 passed.

**Follow-ups**
- 无。

### 2026-06-12 — fix(grep): finish `<leader>/` result completeness and remove temporary diagnostics

**Task** — Continue the unfinished `<leader>/` search fix: results were still incomplete in some sessions, and the live code still contained temporary fingerprint logs from diagnosis.

**Implemented**
- `lua/utils/code_search/init.lua`: completed the single-flusher contract for the rg backend, matching csearch, including stop guards so killed searches do not emit late `on_line`/`on_done` callbacks.
- `lua/ue.lua` and `lua/plugins/snacks.lua`: removed temporary `DIAG v2` fingerprint file logging while keeping the opt-in `UEGrepTrace*`/`UEGrepDiagDump` diagnostics.
- `tests/cases/utils_spec.lua`: added rg stream ordering and stop-after-cancel regression coverage.
- `tests/cases/grep_cache_spec.lua`: added fallback visibility checks for the slow fallback title and WARN wording.
- `docs/architecture/grep-cache-invalidation.md` and `docs/CONSTRAINTS.md`: documented the stream callback-ordering pitfall and updated test coverage notes.

**Pitfalls / Gotchas**
- csearch and rg must both enforce `on_line` before `on_done`; fixing only csearch leaves the no-index rg path able to trip the same tail-loss class.
- The permanent diagnostics are the opt-in trace/dump commands, not unconditional writes to `stdpath("state")`.

**Validation**
- `nvim --headless -l tests/run.lua grep_cache` → 16/16 passed.
- `nvim --headless -l tests/run.lua utils` → 28/28 passed.
- `nvim --headless -l tests/run.lua structure` → 36/36 passed.
- Real backend diagnostic with temporary files: csearch selected with a generated index and returned 40/40 hits; rg selected without an index and returned 40/40 hits.
- Full regression: `nvim --headless -l tests/run.lua` → 352/352 passed.

**Follow-ups**
- 无。

### 2026-06-12 — docs(rules): add GPT/Codex AGENTS entrypoint

**Task** — 参考现有 Claude Code 工程方法论，为 GPT/Codex 增加可自动发现的本地执行入口。

**Implemented**
- 新增根 `AGENTS.md`：保留自主执行、SESSION START、命令风格、git/adb 策略、DoD，
  并要求 GPT/Codex 在局部改动前读取最近的 `CLAUDE.md` 规则。
- 更新 `docs/CONSTRAINTS.md` 与 `memory/project_overview.md`：把根 `AGENTS.md`
  登记为 GPT/Codex 入口，避免只提 Claude。
- 更新 `tests/cases/structure_spec.lua`：结构回归现在守护根 `AGENTS.md` 存在、链接可解析、
  且包含 GPT/Codex 入口与 Definition of Done。

**Pitfalls / Gotchas**
- 没有复制所有子目录 `CLAUDE.md` 为 `AGENTS.md`，避免两套局部规则并行维护导致漂移；
  GPT/Codex 从根入口按最近祖先 `CLAUDE.md` 读取局部增量。

**Validation**
- `nvim --headless -l tests/run.lua structure` → 36/36 passed, exit 0。

**Follow-ups**
- 无。

### 2026-06-11 — fix(grep): `<leader>/` 静默搜不全根因修复 + csearch 按平台分路径 + 失效逻辑补全

**Task** — `<leader>/`（cached_grep）某会话只返回残缺结果、picker 标题无 `[csearch]`/`[rg]`
后缀（=静默回落最底层 snacks 目录遍历）。三方诊断证明健康态无 bug，根因在会话级负探测缓存；
顺带补全用户诉求的失效逻辑（project/engine/platform 变更触发）。

**Implemented**
- **负探测不缓存**（`lua/utils/code_search/init.lua`）：`csearch_exe`/`cindex_uefilter_exe`
  仅成功时缓存路径，失败不钉死；新增 `M._reset_probe_cache()`。
- **回落可见**（`lua/ue.lua` `cached_grep` + `lua/plugins/snacks.lua` `ue_project_grep`）：
  拿不到 cached list 时一次性 WARN（`vim.b._ue_grep_fallback_warned` 去重，非 ticker）；
  回落标题改 `Grep All Code (slow fallback — run :UEPrepare)`。
- **engine_root 持久化**（`persist_project` 写入 + `read_state` 归一化）；`set_project` 比对
  project_root **与** engine_root，任一变即失效。
- **csearch/workspace_all 按平台+配置分路径**（`cache_paths(root, platform_key)`）：
  `csearch/<key>/` + `gtags/<key>/`；新增 `CORE_RT.platform_key_from_state`（与
  `ue.cdb.shards` 平台维度同源）；空 key 回落旧单一路径。
- **旧缓存自动迁移**（`CORE_RT.migrate_legacy_csearch_if_needed`，os.rename move、幂等、
  不覆盖）；`resolve_context` 末尾幂等调用。
- **失效/清缓存**：`invalidate_project_scoped_cache` 改删 `csearch/`+`gtags/`+`shards/` 整树
  （全平台）；UEPrepare 同步+异步 finalize 清 `context_cache`+`freshness_notified`+重探；
  `set_platform`（fast-swap + 交互两分支）清 context + 重探 + 迁移，**不删旧平台索引**。
- 测试 seam：`M.cache_paths`/`M.platform_key_from_state`/`M.migrate_legacy_csearch_if_needed`。

**Pitfalls / Gotchas**
- 无后缀标题 `(Engine+Project)` 是关键证据——它来自 snacks.lua 传入的 opts.title，
  仅当 cached_grep 返回 nil 回落时才出现；带后缀 `[csearch]`/`[rg]` 才是走成功。
- platform 切换**不删**旧平台 grep 缓存（与 cdb shard 模型一致，用户明确诉求），靠分路径隔离。

**Validation**
- 窄 filter：`grep_cache`（14/14）、`utils`（26/26）、`structure`（33/33）全绿。
- headless `scripts/diag_grep_csearch.lua`：分路径后索引解析到
  `csearch/Android-Development/csearch.idx`，`is_indexed=true`，14 条命中无遗漏。
- 提交前全量 `nvim --headless -l tests/run.lua`（见下方运行结果）。

**Follow-ups**
- 设计文档：`docs/architecture/grep-cache-invalidation.md`；坑 K26/K27、约束 C5b 已登记。

### 2026-06-11 — refactor(docs/rules): AI 持久化开发结构 — 递归本地规则 + 知识库 + 强制执行入口

**Task** — 让持续介入的 AI agent 能「从文件而非 chat 历史」发现并遵守项目规则；
参考 refra.txt 的持久化记忆 / 子系统边界 / 本地规则模型，但不重写工作系统、不移动 `lua/` 运行时代码。

**Implemented**
- 强制执行入口：根 `CLAUDE.md` 顶部加 `SESSION START` 协议块 + `Definition of Done`（回归/changelog/milestone 三条硬标准）。
- 递归本地规则（16 个 `CLAUDE.md`，子级声明继承父级、只写增量）：`lua/`、`lua/ue/`(+`cdb`/`core`/`dap`)、`lua/utils/`(+`ue_goto`/`code_search`/`platform`)、`lua/config/`、`lua/plugins/`、`lua/workarounds/`、`lua/trouble/`、`lua/nio/`、`tools/`、`scripts/`、`tests/`、`docs/`。
- 持久化知识库：`memory/project_overview.md`、`decisions/README.md`、`lessons/README.md`、`docs/architecture/overview.md`（ADR 索引指回 `docs/plans/`，不搬家）。
- 政策文档化：`docs/CONSTRAINTS.md` 新增 C6 回归政策 / C7 changelog 记录政策 / C8 milestone 政策 + §五知识库章 + §六维护契约；`docs/testing-regression.md` 新增「改动→filter 分范围映射」；`tests/CLAUDE.md` 内嵌 CHANGE-TO-FILTER MAP；`README.md` Layout 补 AI 持久化层。
- 可发现性回归：新增 `tests/cases/structure_spec.lua`（目录规则存在 / 知识库四根 / 内链不悬空 / 政策可发现）。
- 根目录卫生：删除 untracked 游离物（空名文件、Temp html、`lua/ue.lua.bak-*`）。

**Pitfalls / Gotchas**
- 不移动 `lua/`：Neovim runtimepath 强依赖该布局，移动会断 require —— 重构落在文档/规则层。
- 强制力只能靠根 `CLAUDE.md`（每个新 context 自动注入）；按用户决定不加 hook/CI 兜底。

**Validation**
- 回归范围：**全量** `nvim --headless -l tests/run.lua` → 327/327 passed, exit 0；`scripts/run_regression.ps1` 同样 327/327。
- 失败注入验证：临时删 `lua/nio/CLAUDE.md` + 造悬空链接 → structure_spec 各自 FAIL、exit 1，还原后复绿。

**Follow-ups**
- 归档本 openspec change `ai-persistent-dev-refactor`；`decisions/` 是否物理收纳 `docs/plans/` ADR 留作后续 `git mv` change。

### 2026-06-02 — fix(dap/android): resolve Source/Client project-root layout for <space>da

**Task** — User reported `<space>da` / `:UEDAPAttach android` error and asked to read the local docs plus config rules before fixing. The captured DAP protocol log showed `process attach --pid ...` failed with `lost connection`, followed by `target symbols add ... does not match any existing module`; the earlier probe also showed context project_root was `E:/aki/zeqiang_aki_3.4/Source/Client`.

**Implemented**
- `lua/ue/dap/android.lua`
  - Added `android_marker_path(root)` so Android cook outputs are resolved from both repository-root layout (`<root>/Source/Client/Binaries/Android`) and UE project-root layout (`<root>/Binaries/Android`).
  - Updated `read_package_info`, `discover_project_root`, `effective_project_root`, and `pick_symbol_lib` to use that marker instead of hard-coding `Source/Client` under every candidate root.
  - `effective_project_root(ctx)` now probes `ctx.project_root`, `ctx.uproject` dir, project parent/grandparent, config roots, buffer, and cwd; it treats `engine_root` only as a discovery start, not as a project root fallback.
  - `pick_source_map(ctx)` now also goes through `effective_project_root(ctx)`, so DWARF root `D:\project\uetemp` maps to the actual local project root instead of accidentally using engine_root when the current buffer is under Engine.
  - Added `_pick_source_map_for_test` alongside existing test hooks.

**Pitfalls / Gotchas**
- `ue.resolve_context()` can legitimately return project_root as the `.uproject` directory (`.../Source/Client`), not the repository root. Appending `/Source/Client/Binaries/Android` to that doubles the path and causes package/symbol discovery to miss cooked outputs.
- `nvim --headless -u NONE` does not load the normal `ue` setup state, so context-driven verification must pass an explicit ctx table; otherwise the picker prompts and the script appears to hang.
- The recorded `target symbols add ... does not match any existing module` was downstream of failed attach (`lost connection`), not primary proof that the symbol file was wrong. The fixed discovery is still required because the previous root contract could pick/prompt wrong paths before attach.

**Validation**
- `nvim --headless -u NONE -c "luafile lua/ue/dap/android.lua" -c qa` exits 0.
- `loadfile("lua/ue/dap/android.lua")` exits 0.
- `require("ue.dap.android")` succeeds and `_pick_source_map_for_test` is registered.
- Headless explicit-ctx probe:
  - `effective_project_root=E:/aki/zeqiang_aki_3.4/Source/Client`
  - `package=<android-package>`
  - `symbol=E:/aki/zeqiang_aki_3.4/Source/Client/Binaries/Android/Client_Symbols_v170300916/Client-arm64/libUE4.so`
  - attach config includes `target symbols add` for that exact host DWARF file and sourceMap `D:\project\uetemp -> E:/aki/zeqiang_aki_3.4/Source/Client`.

**Follow-ups**
- Full user-path verification still requires live Neovide/device `<space>da`: the protocol-level log currently proves the old attach reached `platform connect` then lost connection at `process attach`; this patch fixes the project-root discovery contract and stale path construction, but cannot guarantee the device-side lldb-server connection without a live attach run.


### 2026-05-28 — UE cache invalidation: setproject auto-invalidates, freshness uses external anchors, picker lazy-starts watcher

**Task** — The `<space><space>` picker and `:UEPrepare` were silently returning 5/14-era results on `D:\project\uetemp` after `z uetemp` + `:UESetProject E:\aki\zeqiang_aki_3.4` + build. Three compounding bugs hid behind one symptom.

**Implemented**
- `lua/ue.lua` — `set_project()` wrapped in `do ... end` + exposed as `CORE_RT.set_project` (dodges the 200-local LuaJIT cap). When `state.project_root` differs from incoming `project_root`, calls new `invalidate_project_scoped_cache(engine_root, "switch")` which removes the project file lists (project.files / workspace.files / workspace_all.files), csearch index (idx + ~ + ~~), gtags DBs under both `gtags_root` and `workspace_db`, all 4 cdb shards, `index_state` / `index_queue`, `dirty.json`, and every `*.idx` under `clangd/index/`. Clears `freshness_notified` + `context_cache` and stops/clears the watcher. Loud WARN toast lists what was invalidated and instructs the user to run `:UEPrepare` (or `:UEPrepare!`). **No auto-prepare** — explicit user-rule.
- `lua/ue.lua` — `CORE_RT.prepare_freshness(ctx)` rewritten against EXTERNAL anchors instead of self-validating against the list it consumes. `git_index_mtime(repo)` now resolves `.git` files (worktrees) by reading `gitdir: <path>` and stat-ing `<gitdir>/index`. Anchor set now includes `dir_mtime(engine_root)`, `dir_mtime(project_root)`, and `state.updated_at` (ISO8601 -> epoch). Watcher overlay: any non-empty `watch.persistent_dirty_status().count > 0` short-circuits to `stale`. The `"unknown"` return is gone — absence of all anchors now leans `stale`.
- `lua/ue.lua` — `prepare_async()` fast-path `need_index` block now delegates to `prepare_freshness(ctx)` instead of re-implementing a half-baked staleness check. Kills the self-validating loop where `csearch.idx.mtime >= workspace_all.files.mtime` always held because they were written within 1 minute of each other.
- `lua/ue.lua` — `M.cached_files()` lazy-starts `ue_watch` when entered with no live handle, so sessions that only ever open the picker still accumulate dirty data.
- `lua/utils/code_search/init.lua` — `build_index(ctx, abs_list, cb, opts)` learned `opts.mode = "reset" | "add"`. `"reset"` keeps `-reset -files-from`; `"add"` drops `-reset` for incremental cindex append.
- `lua/ue.lua` — `:UEPrepare` learned `bang = true`. Bare `:UEPrepare` runs the normal flow with the now-trustworthy external-anchor freshness check. `:UEPrepare!` marks engine_root dirty in `dirty_index_roots`, clears persistent dirty set, forces cold-path full rebuild with `force_csearch=true`.
- `lua/ue.lua` — `:UEPrepareIncremental` (new) snapshots the watcher's persistent dirty set and calls `build_index(..., { mode = "add" })` to append those files to csearch.idx without a full rebuild. Clears the dirty set on success. Only refreshes csearch — gtags/cdb still need normal `:UEPrepare`.

**Pitfalls / Gotchas**
- LuaJIT 200-local cap (skill `luajit-200-local-cap-with-loader-cache-mask`): adding `invalidate_project_scoped_cache` as a main-chunk `local function` pushed us over. Fixed by wrapping the pair in `do ... end` (block scope) and exposing `set_project` through `CORE_RT.set_project`. Updated `:UESetProject` command to call `CORE_RT.set_project(opts.args)`.
- A "function arguments expected near '5'" parse error reported at EOF turned out to be hermes-terminal stderr appended into the tail of `lua/ue.lua` and `code_search/init.lua` during patching (`/bin/bash: line 5: ...hermes-snap-*.sh: No such file or directory`). Detected via `wc -l` mismatch vs expected source length. Stripped via `head -n <last_legit> | cp` and re-verified with luac + loadfile. Worth a follow-up entry in `hermes-windows-io-traps`.
- `.git` as a file (worktree) is invisible to a naive `fs_stat(".git/index")`. Now there is one canonical `git_index_mtime` inside the `do ... end` containing `prepare_freshness`.
- `cindex-uefilter` (and upstream `cindex`) is documented as "add the file or directory tree to the index" when run WITHOUT `-reset`. That is the incremental contract `:UEPrepareIncremental` relies on.

**Validation**
- `luac -p` silent pass on both `lua/ue.lua` (9473 lines) and `lua/utils/code_search/init.lua` (499 lines).
- `nvim --headless ... loadfile()` returns a function for both (LuaJIT parse).
- Live nvim `M.setup()` registers all 5 expected commands with correct bang flag: `UEPrepare BANG-OK`, `UEPrepareIncremental noBang`, `UEPrepareReindex noBang`, `UESetProject noBang`, `UEWatchStatus noBang`.
- worktree-aware `git_index_mtime("D:/project/uetemp")` returned `1779855279` (vs old broken path returning `0`).
- Live anchor comparison on the actual failure case: list mtime 1778734024 (5/14) vs project_root dir mtime 1779351832, engine_root dir mtime 1779937352, state.updated_at epoch ~ 1779887792 -> max anchor far exceeds list -> `prepare_freshness` correctly returns `stale`.

**Follow-ups**
- Run `:UESetProject E:\aki\zeqiang_aki_3.4` on `D:\project\uetemp` and confirm: WARN toast with invalidation summary, then the picker shows freshness banner, then `:UEPrepare` / `:UEPrepareIncremental` both work.
- Update `hermes-windows-io-traps` skill with the "hermes stderr noise appended into edited file" trap.
- Extend invalidation hook to `:UESetUproject` and other state-changing config commands.


---

## 2026-05-28 (#2) - Engine/Config 没进文件 picker / csearch

**Issue**
`<space><space>` 文件 picker 找不到 engine 那份 `AndroidEngine.ini`（`D:\project\uetemp\Engine\Config\Android\AndroidEngine.ini`），只能找到 project 那份。`rg AndroidEngine.ini workspace_all.files` 确认 engine 那份**根本没进 list**。

**Root cause**
`UE_CONST.ENGINE_INDEX_DIRS = { "Engine/Source", "Engine/Plugins", "Engine/Shaders" }` —— **没有 `Engine/Config`**。project 侧 `PROJECT_INDEX_DIRS` 有 `Config`，engine 侧没有，不对称。`scan_relative_files` 走 `fd --search-path <whitelist>`，目录不在白名单就永远扫不到。文件扩展名层面没过滤（fd 全收），所以单纯加目录就够。

**Fix**
`lua/ue.lua:1515-1520` `ENGINE_INDEX_DIRS` 追加 `"Engine/Config"`。

**Validation**
- `luac -p lua/ue.lua` silent pass (9474 lines)
- nvim --headless `require("ue").setup()` ENGINE_INDEX_DIRS 内容: `Engine/Source, Engine/Plugins, Engine/Shaders, Engine/Config`，5 commands 全 REG
- `D:\project\uetemp\Engine\Config` 文件总数 = 85（list 增量可忽略）

**Follow-ups**
- 用户重启 nvim 后必须 `:UEPrepare!`（bang 强制重扫），否则 ENGINE_INDEX_DIRS 改了但 anchor mtime 没变，freshness 仍判 fresh，list 不会重生
- 同理：检查 `ENGINE_SHADER_DIRS` / `PROJECT_SHADER_DIRS` 是否也少目录（shader 扫描独立）
- 若以后 engine 侧再加目录（如 `Engine/Programs`），同步加入这里


---

## 2026-05-28 (#3) - csearch 漏 project 侧整个 CSharpScript / TypeScript / Config 树

**Issue**
用户希望 csearch 收 .ini / .ts / .cs，结果发现 csearch grep 完全搜不到 `E:\aki\zeqiang_aki_3.4\Source\Client\CSharpScript\...` 下的内容（GameSettingsConfig 0 hits），也搜不到 .ini 里的常见 token（AndroidPackageName 在 .ini 0 hits / .cpp 40 hits）。但 workspace_all.files 里这些路径都在。

**Root cause**
跨盘符 (project 在 E:，engine 在 D:) 导致 `workspace_root()` 退化为 `engine_root = D:/project/uetemp`，然后 `_ufs.relative_to(root, project_abs_path)` 因 `path_has_prefix` false → **返回原绝对路径**，所以 workspace_all 列表里 project 侧文件全是绝对路径 `E:/aki/...` 开头。但 ue.lua 三处构造 cindex `csearch_filelist.txt` 时无脑 `fout:write(cs_root, "/", rel, "\n")`，对 project 文件拼出 `D:/project/uetemp/E:/aki/.../GameSettingsConfig.cs` 这种荒诞路径 → cindex `os.Stat` fail → skipped++ → **整个 project 树（含 CSharpScript / TypeScript / Source / Config / Plugins）在 csearch 索引里完全不存在**。

只有 engine 侧（`Engine/...` 相对路径）拼出来是有效的，所以 csearch 看起来"能工作"，掩盖了 50%+ 文件缺失。

**Fix**
`lua/ue.lua` 三处构造 csearch filelist 的循环（7891 sync UEPrepare、8095 fast-path、8416 cold async）统一加 `_ufs.is_absolute_path(rel)` 判断——绝对路径直写，相对路径才前缀 cs_root。

顺手 `lua/utils/code_search/init.lua:143` 的 `opts.code_only` ext 白名单补 ts/tsx/js/yaml/yml/conf/py/lua/glsl/ipp/inc/m/mm/metal（之前缺 ts/tsx 等，未来如果有 caller 传 code_only=true 会误过滤）。

**Validation**
- `luac -p` 两文件 silent pass (ue.lua 9497 行 / code_search 502 行)
- nvim --headless setup() 5 commands 全 REG
- `is_absolute_path("E:/aki/x.cs") = "E:/"` (truthy), `"Engine/Source/X.cpp" = nil` (falsy)

**Validation pending (用户重启 nvim 后)**
- `:UEPrepare!` 强制重建（必须 bang，老 list/idx mtime 不能触发 freshness）
- csearch `'GameSettingsConfig'` 应有 hits
- csearch `-f '\.ini$' 'AndroidPackageName'` 应非空
- csearch `-f 'Source[\\/]Client[\\/]CSharpScript'` 应有 30k+ 文件

**Why csearch.idx 5/14 老 vintage hides this**
两个 bug 叠加：上次会话修了 set_project 不 invalidate cache（5/14 idx 一直被 fast-path 认为 fresh），但即便 invalidate 修好后重建出来的 idx 仍然缺 project 树——因为这第三个 bug 长期存在。两个 bug 修完才能真正看到完整 index。

**Follow-ups**
- 长期：考虑把 `workspace_all.files` 永久改成全绝对路径（统一格式），cindex filelist 构造时永不前缀。这是更干净的设计，但要改 list 消费者（picker、status 显示）所有 caller。这次先打 fix 不改格式契约。
- 验证 GTAGS 那条链是否也踩同样 bug（gtags 用 workspace.files 不含 .cs/.ts 反而幸免）


---

## 2026-05-28 (#4) - prepare_freshness 自指 anchor 假 stale WARN

**Issue**
`:UEPrepare!` 跑完后任何 `<leader>/` (cached_grep) 都立刻弹 `[grep] :UEPrepare is stale (worktree changed since last run) — results may miss new files`，但实际什么都没变。

**Root cause**
`prepare_freshness` (lua/ue.lua:~3253) 把 `iso_to_epoch(state.updated_at)` 算进 anchor max。但 state.updated_at 是 `:UEPrepare` finalize 阶段写的——`list_dump → cindex csearch ~120s → finalize 写 state.json`——所以 state.updated_at **必然** = list_mt + 2~3 分钟。于是 `list_mt < anchor_max(state.updated_at)` 永远 true → freshness 报 `stale` → notify_freshness (5612) 弹 WARN。每次 :UEPrepare 跑完下次 grep 100% 触发。

**Fix (方案 A)**
从 anchors 列表里删 `iso_to_epoch(state.updated_at)`。剩四个 anchor (git index×2 / dir mtime×2) 仍能感知真实 stale 信号。state.updated_at 原本想 catch project 重配置，现在 :UESetProject 走 invalidate_project_scoped_cache 删 list → list_stat==nil → "never" 分支已覆盖，所以 anchor#5 已是冗余 + 倒置语义。

**Validation**
- luac -p silent pass (9503 行)
- nvim --headless setup() 5 commands 全 REG

**Pending user validation**
- 重启 nvim → :UEPrepare!（让前面 cross-drive 修复也生效）→ 立刻 `<leader>/` → **不应**弹 stale WARN
- 后续真改文件（git pull / 新建文件）→ 仍应正确报 stale

**已归档**
- skill `ue-cdb-missing-new-files` Pitfall 12: prepare_freshness anchor 自指 stale

## 2026-05-28 (#5) - CDB partition by (platform, config) — fix gd jumping to wrong-config generated header

**Issue**
`gd UE_BUILD_DEVELOPMENT` in nvim jumped into
`E:\aki\zeqiang_aki_3.4\Source\Client\Intermediate\Build\Android\Client\Development\VulkanRHI\Definitions.VulkanRHI.h`
even though the current build config was Test (the .so was Test-built, the
`Test/VulkanRHI/Definitions.VulkanRHI.h` exists with `#define UE_BUILD_TEST 1`,
no `UE_BUILD_DEVELOPMENT` anywhere in Test/).

**Root cause**
UBT's `compile_commands.json` writer is config-agnostic — every :UEPrepare run
appends to whatever's there. After weeks of switching between Test, Dev, and
the Editor:
- 13640 cmds `(Android, Client, Test)` — current, correct
- 106 cmds `(Win64, UE4Editor, Development)` — Editor-only modules from a
  much older Dev rebuild; their `-include` points at
  `Intermediate/Build/Win64/UE4Editor/Inc/...`
- 30 cmds `(Android, Client, Development)` — stale Android Dev entries
- 1 cmd `(Android, UE4, Development)` — UE4→UE5 migration leftover (the old
  `UE4` project name)
- 5 cmds `(Android, Client, None)` — third-party `.c` (SQLite/minizip/kcp)
  without Definitions
- 1974 unclassified shaders (`.usf`/`.hlsl`/`.ush`/`.glsl`) — fine, they don't
  carry build context

clangd indexes every cmd in the CDB, so the Dev `Definitions.VulkanRHI.h`'s
`#define UE_BUILD_DEVELOPMENT 1` becomes the *only* visible definition of
that macro (Test's `.h` doesn't define it at all). `gd` is forced to jump
there.

This is structural — UBT will keep producing multi-group CDBs forever. The
right fix is to partition the CDB *by* `(platform, config)` and pin the
active group, so clangd only ever sees one config's headers at a time.

**Fix**
Three pieces:

1. **`tools/cdb_partition.py` (new, 11 KB)** — reads the base CDB, votes a
   `(plat, proj, cfg)` group for each cmd (most-common across all
   `Intermediate/Build/<plat>/<proj>/<cfg>/` matches in the args, with
   `--target=` fallback), writes per-group files to
   `<repo>/.cache/nvim-ue/cdb/active/compile_commands.<plat>-<cfg>.json`,
   and rewrites the base to contain only the active group + unclassifiable
   shaders.
   - `--active auto` picks the largest group (default).
   - `--active Android/Test` or `--active Android/Client/Test` pins explicitly.
   - Collision rule: when two groups share `(plat, cfg)` but differ in
     project (e.g. `Client` vs `UE4` leftover), the project segment is added
     to the filename so files don't overwrite each other.
   - Emits `<repo>/compile_commands.partition.json` manifest (with active
     group, group list, backup path).
   - Exit codes: `0`=ok, `2`=base CDB missing/bad, `3`=single-group (no
     partition needed, manifest only), `4`=bad --active spec.

2. **`lua/ue.lua` hook (3 patches, +7847 chars / +177 lines)**:
   - `INDEX_FN.partition_base_cdb(ctx, opts)` — spawns the Python script
     synchronously with `vim.system().wait()` (2 min timeout). Reuses the
     Python 3.12 absolute-path probe + PYTHONPATH/PYTHONHOME scrub already
     used by the ccjson subprocess. Non-fatal on failure (WARN, leave base
     untouched, downstream pipeline continues).
   - `INDEX_FN.read_partition_manifest(ctx)` — JSON-decodes manifest for
     status display.
   - Called from the ccjson `on_done` callback right after
     `run_compile_commands_pipeline` and BEFORE `clear_index_dirty` /
     `INDEX_FN.schedule_index_refresh`, so subset CDBs and clangd-indexer
     all see the already-partitioned base.

3. **3 commands** (registered after `:UEPrepareSync`):
   - `:UECDBPartition [Platform/Config]` — manual repartition, optional spec
   - `:UECDBSwitch <Platform> <Config>` — change active group, kicks clangd
     restart via existing `INDEX_FN.maybe_restart_clangd_for_index`
   - `:UECDBStatus` — show manifest contents (active group, all groups + cmd
     counts)

**Validation**
- `loadfile()` on ue.lua returns function (LuaJIT parse OK).
- `nvim --headless` setup() registers 4 commands: `UECDBPartition REG`,
  `UECDBSwitch REG`, `UECDBStatus REG`, `UEPrepare REG` (no stderr noise).
- Standalone partition script tested on real CDB (`D:\project\uetemp\compile_commands.json`,
  15756 cmds): produces 5 per-group files, base shrinks from 217.9 MB →
  215.6 MB (15614 cmds = 13640 Android-Test + 1974 shaders), manifest
  correct, collision logic puts `(Android,Client,Dev)` 30 cmds and
  `(Android,UE4,Dev)` 1 cmd into distinct files (`Android-Client-Development.json`
  vs `Android-UE4-Development.json`) instead of overwriting.

**Pending user validation**
- Restart nvim → `:UEPrepare!` (full path: ccjson → pipeline → partition →
  index) → check `:UECDBStatus` shows `Active: Android/Client/Test`.
- `gd UE_BUILD_DEVELOPMENT` should report "No definition found" (Test has
  no such macro) or jump to ENGINE source if some non-generated header
  defines it (verify by looking at the target — should NOT be under
  `Intermediate/Build/Android/Client/Development/`).
- `gd UE_BUILD_TEST` should jump to `Test/<Module>/Definitions.<Module>.h`.
- Try `:UECDBSwitch Win64 Development` → check clangd's behavior on
  Editor-only headers (FXxxEditorModule etc.) shifts to Win64 context.

**Known limits / follow-ups**
- Partition runs synchronously in the ccjson `on_done` (vim.system().wait()).
  Should complete in 1-2 s for 217 MB CDB; if a user has a much bigger CDB
  this would be a UI hitch. Watchpoint — convert to async via on_exit
  callback if reports come in.
- The partition picks active by raw cmd count. If you ever
  `:UEPrepare` build Dev then Test in quick succession with similar module
  counts, the "wrong" config could win the vote. Manual override:
  `:UECDBSwitch Android Test`.
- The 1974 unclassified shaders always live in base. Fine for clangd's C++
  TU resolution (shaders aren't C++ TUs anyway), but means base file size
  doesn't shrink to "pure active group" size — it's active + shader tax.
- Backup files (`compile_commands.json.bak-YYYYMMDD-HHMMSS`) accumulate
  forever in the engine root. Cleanup is manual for now.
- `.cache/nvim-ue/cdb/active/` is new; not yet wired into `:UECachePaths`
  output. Low-priority polish.

---

### 2026-06-02 — fix(dap/android): honor lldb-server priority order for <space>da

**Issue**

After the Source/Client project-root fix, live `<space>da` still failed. Fresh logs at 11:19 showed `platform connect` succeeded, but `process attach --pid 20595` returned `error: attach failed: lost connection`; the adapter then emitted `process exited during launch or attach`, `failed to retrieve threads from process`, and dap-ui's threads panel crashed on the failed response.

**Root cause**

`utils.platform.windows.default_lldb_server_paths()` correctly lists UE NDK r21 first, but `lua/ue/dap/android.lua` re-collected all glob hits and sorted them by highest NDK version. On this machine that selected NDK r27's LLDB 18 `lldb-server` and pushed it to `/data/local/tmp/lldb-server` (verified live: remote `lldb version 18.0.1`). That contradicted the platform driver's priority contract and reproduced the known Android platform handoff failure: outer `platform connect` works, inner `process attach` drops with `lost connection`.

**Fix**

Changed `pick_lldb_server_for_tests()` to be first-match-wins, preserving the ordered policy from `utils.platform.windows`: UE NDK r21 first, Android Studio compatibility server second, newer NDKs only as fallbacks. Updated the fallback prompt from "NDK 27 preferred" to "UE NDK r21 preferred".

**Do-not-change constraints kept**

- Did not change `stopOnEntry=true`.
- Did not add `process continue` to `attachCommands` or `postRunCommands`.
- Did not touch the nvim-dap stopped-event / all-threads burst handling.
- Did not change SIGSEGV/SIGBUS `--pass true --stop false --notify false` disposition.



**Follow-up during live retry**

The first remote-triggered retry exposed a second, editor-side cleanup bug: when lldb-dap exits during attach before a stable nvim-dap session remains, `M._attach_in_progress` can stay true even though `dap.session()` is already nil. Added a guarded stale-mutex release in `M.attach()` and a 10s post-`C.run()` grace cleanup in `_finalize_session()`. Also moved the mutex assignment to after the preflight `dap.session()` check, so a stale flag cannot survive the no-session fast path. This only clears our bootstrap mutex/progress popup when there is no live DAP session; it does not alter attach protocol, stopOnEntry, continue timing, or stopped-event handling.

**Validation**

- Live log classified as current (11:19 mtime) rather than stale.
- Device state before patch: target process was healthy (`State: S`, `TracerPid: 0`), but `/data/local/tmp/lldb-server` was LLDB 18 from NDK r27.
- Local candidate probe showed intended first match is NDK r21 LLDB 9; previous sorted picker chose NDK r27 LLDB 18.
- Headless parse/require checks passed for `lua/ue/dap/android.lua`.
- Running Neovide instance `nvim.24272.0` was hot-reloaded via remote `:luafile`; live module picker now returns NDK r21 and `is_ndk21=true`.
- Device stale `/data/local/tmp/lldb-server` was cleaned and re-pushed from NDK r21; remote `lldb-server version` now reports LLDB 9.0.9 and the game process is healthy (`State: S`, `TracerPid: 0`).
- Pending full user-path validation: press `<space>da` in the already-reloaded Neovide. This is now the same entry path with the corrected picker, but I did not synthesize a fake attach or send side-channel DAP commands.

---

### 2026-06-02 — fix(dap/android): make host lldb-dap version policy forward-only

**Issue**

User corrected an important boundary: the lldb version restriction in the Android DAP migration notes is about the **host-side `lldb-dap.exe` adapter**, not the device-side `lldb-server`. Host `lldb-dap` must stay on the validated 22.1.6 baseline or move forward after a probe; it must never silently fall back to LLVM 21.

**Fix**

- `lua/utils/platform/windows.lua`: removed `C:/tools/lldb-21/bin/lldb-dap.exe` from `default_lldb_dap_paths()` and rewrote comments to state the forward-only 22.1.6+ host policy.
- Skills updated:
  - `lldb-dap-android-attach-version-pinning`: replaced the old LLVM 21 downgrade workaround section with a 22.1.6+ forward-only policy and clarified host adapter vs device server.
  - `lldb-dap-22-platform-mode-breakpoint-crash`: added a non-negotiable host-version policy note.

**Boundary**

- Host adapter: `C:/tools/lldb-22/install/bin/lldb-dap.exe` (LLVM 22.1.6) is the floor; future versions require bare-DAP probe success.
- Device server: `/data/local/tmp/lldb-server` / NDK r21-r27 remains a separate probe variable and must not be confused with host adapter policy.

**Validation**

- `windows.lua` now returns only 22.1.6 private build and system LLVM candidates; no LLVM 21 fallback remains.
- `nvim --headless -u NONE -c "luafile lua/utils/platform/windows.lua" -c qa` exits 0.

### 2026-06-02 — fix(dap/ui): suppress dapui threads nil-response crash after failed Android attach

Task: live `<space>da` still surfaced a Lua callback error from nvim-dap-ui:
`dapui/components/threads.lua:11: attempt to index field 'response' (a nil value)`.

What the fresh protocol log showed:
- Host adapter is the required `C:/tools/lldb-22/install/bin/lldb-dap.exe` / LLVM 22.1.6.
- `platform connect` succeeded.
- `process attach --pid 23129` failed with `Cannot get process architecture`.
- lldb-dap then emitted an `entry` stopped event and later a deferred `attach` response with `success=false` / `process exited during launch or attach`.
- nvim-dap requested `threads`; lldb-dap correctly answered `success=false` / `failed to retrieve threads from process`, so nvim-dap passed `response=nil` to after-listeners.
- nvim-dap-ui's stacks component assumed `args.response.threads` always exists and crashed, masking the real attach failure.

Change:
- Added a UE Android lldb session guard in `lua/ue/dap.lua`.
- Wrapped existing `dap.listeners.after.threads` listeners installed by dapui during `setup_dap()`, and no-op only the UE Android attach failure shape (`err` present and no `response.threads`). This keeps the guard in the local nvim config instead of editing the lazy.nvim plugin checkout.
- Did not modify `nvim-data/lazy/nvim-dap-ui` permanently; the direct plugin defensive edit was reverted after confirming the safer local wrapper approach.

Boundaries kept intentionally unchanged:
- Did not change host `lldb-dap.exe` version policy: 22.1.6+ only, forward-only.
- Did not change `stopOnEntry=true`.
- Did not add `process continue` to `attachCommands` / `postRunCommands`.
- Did not change SIGSEGV/SIGBUS `--notify false --pass true --stop false`.

Verification:
- `nvim --headless -u NONE -c "luafile lua/ue/dap.lua" -c qa` passes.
- `nvim --headless -u NONE -c "luafile lua/ue/dap/android.lua" -c qa` passes.
- `nvim --headless -u NONE -c "lua local ok,m=pcall(require,"ue.dap"); assert(ok,m); assert(type(m.setup_dap)=="function")" -c qa` passes.

Follow-up:
- This fixes the editor-side secondary exception only. The real attach-layer failure remains `process attach --pid ... -> Cannot get process architecture` / previous `lost connection` and needs device/ptrace/lldb-server boundary diagnosis next; do not mistake the removed dapui popup for attach success.

### 2026-06-02 — fix(dap/android): guard nil cleanup session and re-isolate attach failure boundary

Task: user reported `<space>da` still errors and noted it was working before last Wednesday. Fresh logs show the current visible error is no longer the dapui `threads.lua:11` nil-response crash; the real attach boundary is now visible.

Fresh evidence:
- Host `lldb-dap.exe` is still the required LLVM 22.1.6 build.
- `platform connect` succeeds.
- `process attach --pid <game pid>` fails at the device/server boundary:
  - with the current device server it reports `Cannot get process architecture`;
  - with NDK r27 server as a regression probe it reaches module pull but reports `lost connection` / async-thread-dead during `configurationDone`.
- Direct `lldb-server gdbserver --attach <pid>` as shell also crashes/returns before setting `TracerPid`, so this is not caused by dapui or the local threads nil guard.

Change:
- `lua/ue/dap/android.lua`: fixed `_cleanup_device_side()` to tolerate `M._session == nil` (`if sess and sess.serial and sess.adb`) so a stale/failed attach cleanup cannot throw before writing diagnostics or retrying.
- Removed over-specific comments/prompt text that claimed NDK r21 was the proven device-server fix. Host lldb-dap remains 22.1.6+ forward-only; device `lldb-server` is now explicitly treated as a separate live-probe variable.

Validation:
- `nvim --headless -u NONE -c "luafile lua/ue/dap/android.lua" -c qa` exits 0.
- `require("ue.dap.android")` smoke check exits 0.
- Live Neovide module hot-reload of `ue.dap.android` succeeded.

Follow-up:
- Next fix should target the device/ptrace attach boundary, not dapui. Do not change `stopOnEntry`, `process continue`, or SIGSEGV/SIGBUS policy without a fresh protocol proof.

## 2026-06-02 — Android DAP gdbserver attach on a3ad86f3

- Task: continue the UE Android nvim-dap/lldb-dap attach fix, with validation limited to adb serial `a3ad86f3`.
- Completed:
  - Replaced the Android attach command path from `platform select/connect` + `process attach --pid` with a pre-spawned `lldb-server gdbserver --attach <pid>` and lldb-dap `gdb-remote 127.0.0.1:<port>` attach command.
  - Stage `lldb-server` through `/data/local/tmp/lldb-server`, then copy it into the app sandbox as `files/lldb-server`; Android 16 rejects executing the public `/data/local/tmp` binary through `run-as`, while the sandbox copy executes correctly.
  - Cleanup now kills app-uid lldb-server via `run-as`, removes the adb forward, and sends `kill -CONT` as the app uid when possible.
  - `:UEDAPStatus` now reports the server mode (`gdbserver`).
- Pitfalls / evidence:
  - On `a3ad86f3`, platform mode connected but `process attach --pid` reported `lost connection`, then the deferred DAP attach response failed with `process exited during launch or attach`; `threads` failed.
  - `settings set target.memory-module-load-level minimal` did not solve the platform path: attach still stalled while the target was in `t (tracing stop)` with a live lldb-server tracer.
  - Bare gdbserver attach on `a3ad86f3` reached `initialized`, `configurationDone`, a successful `attach` response, and successful `threads` enumeration through lldb-dap.
  - `disconnect` in the bare probe can still leave the process in `T (stopped)`; recovery was `am force-stop` + relaunch. Keep using the production two-phase stop path and app-uid cleanup.
- Verification:
  - Headless Neovim parse/load smoke passed for `lua/ue/dap/android.lua`.
  - Headless config smoke confirmed first attach command is `gdb-remote 127.0.0.1:5039` and no `platform connect` / `process attach --pid` command is emitted.
  - Device-only verification was performed on adb serial `a3ad86f3`; final device state: app relaunched, `TracerPid: 0`, no `lldb-server` process, no adb forwards.
- Follow-up:
  - Validate once through the real user entry path (`<space>da` / `:UEDAPAttach android`) in Neovide, because headless/bare-DAP probes cannot fully prove the UI path.


## 2026-06-02 — Android device selection + lldb-server sandbox staging

- Task: fix two regressions reported after Android DAP/gdbserver work.
- Completed:
  - `UELaunch` / `<leader>ul` no longer silently uses the first `adb devices` row when multiple ready devices are connected. It now prompts with `vim.ui.select` and launches with the selected serial.
  - `ue.dap.android` lldb-server staging now reports detailed sandbox diagnostics and falls back from `cp` to `cat > files/lldb-server` before chmod/stat.
- Pitfalls:
  - The launch helper had an independent adb-device picker from the DAP helper, so fixing `<space>da` did not fix `<space>ul`.
  - A bare "failed to stage" message hid whether public staging, run-as copy, chmod, or stat failed; include expected/got size and run-as directory details.
- Verification:
  - Headless Lua parse/load smoke passed for `utils.ue_launch` and `ue.dap.android`.
  - Headless simulated multi-device launch selected `a3ad86f3` and produced `adb -s a3ad86f3 shell monkey ...`.
  - Real-device checks were limited to adb serial `a3ad86f3`: monkey launch succeeded; target process was alive with `TracerPid: 0`; sandbox `files/lldb-server` exists and runs `version`.
- Follow-up:
  - Current Neovide may need restart/manual reload because it runs embedded and may keep stale Lua closures.


## 2026-06-02 — Android run-as cwd regression fix

- Task: follow-up for persistent `<space>da` `failed to stage lldb-server in app sandbox` after previous diagnostics.
- Completed:
  - Fixed `ue.dap.android` run-as shell invocations to pass the whole `run-as <pkg> sh -c '<cmd>'` as one `adb shell` command string.
  - Added `shell_quote()` and `adb_run_raw()` so failed adb commands keep stdout/stderr instead of collapsing to an empty string.
  - Staging diagnostics now reveal `PWD`, `id`, mkdir/cp/cat/chmod/stat markers, and final `STAT_SIZE`.
- Root cause:
  - On Windows/adb argument-vector form, `adb shell run-as <pkg> sh -c <cmd>` executed `sh -c` with `PWD=/` while still as shell in this environment; `mkdir files` then failed on read-only `/`, so copied_size was empty.
  - Passing a single remote shell string (`run-as <pkg> sh -c '<cmd>'`) correctly starts in `/data/user/0/<pkg>`.
- Verification:
  - Headless Lua parse passed for `lua/ue/dap/android.lua`.
  - Real-device staging command on adb serial `a3ad86f3` now reports `PWD=/data/user/0/<android-package>`, `STAT_SIZE=17190248`, and `files/lldb-server version` succeeds.
  - Cleanup verified on `a3ad86f3`: no adb forwards, no lldb-server, target `TracerPid: 0`.
- Follow-up:
  - Running Neovide is still embedded, so restart Neovide to load this patch before retesting `<space>da`.

## 2026-06-02 - Android DAP lldb-server latest-version probe

Task: temporarily test the Android DAP path on adb serial `a3ad86f3` with the newest available device-side `lldb-server` instead of the UE/NDK21-pinned binary.

Completed:
- Cleaned the active debugger state only on `a3ad86f3` (`lldb-server` processes and adb forwards), leaving the game process alive.
- Probed local Android lldb-server candidates on-device and selected the newest runnable binary:
  `C:/Users/lizeqiang/AppData/Local/Programs/Android Studio 2/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server`
  (`lldb version 19.0.1`, size `45818944`).
- Staged that LLDB 19 binary to both `/data/local/tmp/lldb-server` and the app sandbox `files/lldb-server` via `run-as <android-package>`.
- Temporarily changed `lua/utils/platform/windows.lua` candidate priority so `:UEDAPAttach android` will pick the Android Studio bundled LLDB 19 binary first during this probe instead of immediately re-staging NDK21.
- Verified with a bare DAP probe using host `C:/tools/lldb-22/install/bin/lldb-dap.exe` + device `lldb-server gdbserver --attach` on `a3ad86f3`: `initialize`, `gdb-remote`, `configurationDone`, `attach`, `threads`, and `disconnect` all succeeded.

Verification:
- `/data/local/tmp/lldb-server version` and app sandbox `files/lldb-server version` both report `lldb version 19.0.1`.
- Bare DAP probe enumerated UE threads and detached cleanly.
- Post-cleanup state on `a3ad86f3`: target process `State: S (sleeping)`, `TracerPid: 0`, adb forwards removed.

Caveat:
- This is an experiment override, not a proven permanent policy. If LLDB 19 causes regressions, revert the `windows.lua` priority change to put NDK21 first again.

## 2026-06-02 - Android DAP post-attach E474 guard

Task: fix the post-attach `Vim:E474: Invalid argument` reported after `<space>da` connects.

Completed:
- Hardened `lua/ue/dap.lua` source-frame navigation after DAP stopped events.
- Added a single `jump_to_local_source_frame()` helper that clamps lldb-dap `line`/`column` to Neovim-valid cursor coordinates and wraps the edit/cursor hop in `pcall`.

Root cause:
- lldb-dap can report source-backed frames with `line=0` or other out-of-range coordinates during attach/entry stops. The previous listener called `nvim_win_set_cursor()` directly with that value, which raises `Vim:E474: Invalid argument` even though the debugger attach itself succeeded.

Verification:
- `lua/ue/dap.lua` headless parse passed.
- Existing live session was inspected through the nvim pipe; attach was active and the error was isolated to UI source navigation, not the adb/lldb-server attach boundary.

Follow-up:
- Reload/restart Neovide before the next `<space>da` user-path retest so the listener closure is refreshed.

## 2026-06-02 - Android DAP synthetic frame E474 guard

- Task: keep investigating the post-attach `Vim:E474: Invalid argument` popup on the real Android DAP path (`a3ad86f3` only).
- Completed: traced the live Neovim error through Snacks notifier and an instrumented `nvim_win_set_cursor()` wrapper. The remaining popup came from upstream `nvim-dap` (`dap/session.lua:set_cursor`) trying to jump to LLDB PC-only synthetic frames with `sourceReference` and `line=0`, not from the local `ue-dap-source-nav` listener.
- Fix: `lua/ue/dap.lua` now installs an idempotent UE Android guard around `dap.session._frame_set` and drops synthetic/invalid UE Android frames before nvim-dap opens `dap-src://...` and tries cursor `{0, 0}`. Local source frames are still allowed.
- Verification: syntax check passed with `nvim --headless -u NONE`; hot-reloaded the running Neovim pipe `nvim.39212.0`; self-test called `_frame_set()` with a synthetic `line=0/sourceReference` frame and returned without E474, without changing buffer, and with empty `v:errmsg`.
- Follow-up: F9 breakpoints are still unverified; continue from symbol/module mismatch (`target symbols add ... libUE4.so does not match any existing module`).

## 2026-06-02 - Android DAP E474 stackTrace response filter

- Task: user reported `Vim:E474: Invalid argument` still appeared after the `_frame_set` synthetic-frame guard.
- Root cause: the previous guard was at the wrong layer. nvim-dap's built-in `Session:event_stopped()` handles `stackTrace` responses before `after.event_stopped` and does not call `_frame_set`; it directly calls its local `jump_to_frame()` with the first frame. LLDB/lldb-dap was returning PC-only UE Android frames with `line=0` and `sourceReference>0`, so nvim-dap opened `dap-src://...` and attempted cursor `{0,0}`.
- Fix: extended `dap.listeners.before.stackTrace["ue_source_path_rewrite"]` in `lua/ue/dap.lua` to filter synthetic/invalid frames for UE Android lldb-dap sessions before nvim-dap consumes the response. Non-Android sessions are unchanged, and valid local-source frames still pass through.
- Verification: syntax check passed; hot-reloaded current nvim PID `30096`; live self-test invoked the `before.stackTrace` listener with one synthetic frame plus one local source frame and confirmed the synthetic frame was removed (`totalFrames=1`).
- Follow-up: existing Snacks notification history still contains old E474 entries; verify on the next stopped event / fresh attach that no new E474 notification is added.

## 2026-06-02 - Android DAP breakpoint rejection diagnosis

- Investigated F9 breakpoints on `a3ad86f3` after the sign changed from `DapBreakpoint` (`●`) to `DapBreakpointRejected` (`R`).
- Confirmed nvim-dap is sending `setBreakpoints` and lldb-dap is responding successfully, but every breakpoint is `verified=false`; the `R` sign is nvim-dap's rejected-breakpoint state, not a sign rendering bug.
- Added a UE Android `setBreakpoints` source-path rewrite guard that can convert local Windows UE source paths to basename-only DAP requests before lldb-dap sees them, while remapping adapter responses back to local paths for editor display.
- Live test on the active session showed basename requests are now sent (`source.path = "MobileShadingRenderer.cpp"`), but lldb still returns `verified=false` because the current LLDB target reports `image list -> target has no associated executable images`; `image list libUE4.so` has no module and `target symbols add .../libUE4.so` says the symbol file does not match any existing module.
- Follow-up: fix Android attach module/executable registration first (the target currently has `arch=aarch64-unknown-linux-android`, `pid=12554`, but no images), then re-test F9 verification on `a3ad86f3`.
## 2026-06-02 — Android DAP F9 rejected breakpoint: create target before gdb-remote

- Task: continue Android nvim DAP fix, testing only on adb serial `a3ad86f3`.
- Root cause confirmed: direct `gdb-remote` custom attach succeeded but left LLDB with `target #0: <none>` / no executable images, so lldb-dap returned `verified=false` and nvim-dap changed the sign from `DapBreakpoint` (`●`) to `DapBreakpointRejected` (`R`).
- Source check: lldb-dap 22 `AttachRequestHandler.cpp` only supports custom target creation inside `attachCommands`; the earlier `targetCreateCommands` key is not parsed for attach requests.
- Fix: `lua/ue/dap/android.lua` now prepends `target create "<symbol-rich libUE4.so>"` before `gdb-remote 127.0.0.1:<port>` when `session.symbol_lib` is available, and removes the later `target symbols add` path that cannot work without an existing module.
- Verification on `a3ad86f3`: bare `lldb.exe --batch` with the exact command order `target create <Client_Symbols.../libUE4.so>` then `gdb-remote` produced `image list libUE4.so` with UUID `C8800DF4-7600-D609-D706-ADDCE90C2AB8-7E8291C9` and resolved `breakpoint set -f MobileShadingRenderer.cpp -l 1345` to `libUE4.so` address `0x00000061e57b005c` with `locations = 1`.
- Live Neovide nvim PID `6036` was hot-reloaded after the patch.
- Follow-up: full lldb-dap JSON probe still floods per-thread SIGSTOP console output and can close stdin before post-attach evaluate; rely on the bare LLDB attach proof plus next user F9 in live nvim to confirm final `verified=true` UI state.
## 2026-06-02 — Android DAP attach warning: quiet lldb-dap attach output flood

- Task: user reported `<space>da` flashed a warning and the session disappeared after the `target create` fix.
- Live nvim probe (PID `27628`) captured Snacks warnings: `Debug adapter didn't respond...` followed by `command C:/tools/lldb-22/install/bin/lldb-dap.exe exited with 3221226505`.
- Protocol log showed `target create` and `gdb-remote` succeeded, then lldb-dap emitted one console/disassembly output block per stopped thread (~700+ DAP `output` events) and died right after `setBreakpoints` was queued.
- Fix: prefix Android custom `attachCommands` with lldb-dap's quiet-on-success marker `?` for `target create`, `gdb-remote`, and `process handle` commands. This keeps the commands but suppresses successful console output so the Windows stdio adapter is not flooded before `setBreakpoints` responds.
- Reloaded live Neovide nvim PID `27628`; cleaned only adb serial `a3ad86f3` (`forward --remove-all`, killed app-sandbox `lldb-server`, verified game `TracerPid: 0`).
- Follow-up: user should retry `<space>da`; if another warning flashes, dump live Snacks/DAP protocol history again before changing config.



## 2026-06-02 - Android DAP attach known package/symbol defaults

- Task: Prevent `<space>da` / agent-driven Android attach from prompting for values already known in this workspace.
- Completed:
  - `ue.dap.android` now carries default attach context for `<android-package>`, device serial supplied by caller, and the known Android symbol lib path `E:/aki/zeqiang_aki_3.4/Source/Client/Binaries/Android/Client_Symbols_v170300916/Client-arm64/libUE4.so`.
  - `pick_package()` and `pick_symbol_lib()` accept explicit context overrides before falling back to discovery or input.
  - Fixed `_progress.lua` hidden-buffer reload trap where stale `[ue-dap progress]` buffer name raised `E95` and aborted attach bootstrap.
- Pitfall: missing context previously fell through to `vim.fn.input()` for package/symbol values, which is wrong for this fixed Android attach workflow.
- Verification: Lua parse checks run for android.lua, dap.lua, and _progress.lua.


## 2026-06-02 - Android DAP suppress lldb-dap setBreakpoints crash

- Task: Fix lldb-dap 22.1.6 exiting with `3221226505` immediately after Android attach initialization.
- Evidence: `lldb-dap-protocol.log` showed attach reached `initialized`, then nvim-dap sent `setBreakpoints` for `MobileShadingRenderer.cpp` and the adapter exited before any response. `dap.log` recorded `Process exit ... 3221226505`.
- Completed:
  - `lua/ue/dap/android.lua`: pre-seeds current nvim breakpoints as quiet LLDB `?breakpoint set -f <file> -l <line>` attachCommands immediately after `?gdb-remote`, before nvim-dap's initial breakpoint sync.
  - `lua/ue/dap.lua`: wraps `dap.session.request` for UE Android sessions so `setBreakpoints` is not sent to lldb-dap on this direct gdb-remote path; returns a synthesized verified breakpoint response to keep nvim-dap signs/UI stable.
- Pitfall: `dap.listeners.before.setBreakpoints` cannot suppress a request; it only sees the response later in nvim-dap's callback pipeline. Suppression must happen at `Session:request` before `send_payload()`.
- Verification:
  - Parse checks passed for `lua/ue/dap/android.lua` and `lua/ue/dap.lua`.
  - Hot reload into live nvim PID 23252 succeeded; `string.dump(dap.session.request)` confirmed the synthetic setBreakpoints wrapper is active.
  - Device cleanup was limited to adb serial `a3ad86f3`; target process remained healthy with `TracerPid: 0`.


## 2026-06-02 - Android DAP synthetic breakpoint response core fallback

- Task: Fix the scheduled callback error `attempt to call field 'norm' (a nil value)` introduced by the UE Android setBreakpoints suppression wrapper.
- Completed: `lua/ue/dap.lua` now uses local `norm_path()` / `is_file()` fallback helpers so the synthetic breakpoint response path does not require `setup_core()` to have populated `core.norm` before the callback runs.
- Verification: `lua/ue/dap.lua` parse check passed and live nvim was hot-reloaded; wrapper remains active.


## 2026-06-02 - Android DAP suppress unavailable-location entry burst

- Task: Stop repeated `Debug adapter stopped at unavailable location` warnings immediately after UE Android lldb-dap attach.
- Evidence: protocol log showed the adapter returning many `stackTrace` responses containing only PC synthetic frames (`line=0`, `sourceReference>0`) for the stopOnEntry all-thread burst. Filtering those frames to an empty stack avoided E474 but caused nvim-dap to warn once per thread.
- Completed: `lua/ue/dap.lua` now suppresses benign UE Android `reason=entry` stopped events before upstream nvim-dap requests stackTrace, while seeding minimal stopped state (`stopped_thread_id`, thread.stopped) so F5/continue still works. Breakpoint hits, user pauses, and real exceptions still go through upstream handling.
- Verification: parse check passed and live nvim was hot-reloaded.


## 2026-06-02 - Android DAP entry-stop burst fixed at attachCommands layer

- Task: Replace the temporary entry-stopped suppression with the protocol-level fix for the repeated `Debug adapter stopped at unavailable location` burst.
- Evidence: nvim-dap warns when lldb-dap reports many stopOnEntry stacks containing only PC synthetic frames (`line=0`, `sourceReference>0`). Directly swallowing `event_stopped` is unsafe because it can desynchronize nvim-dap's stopped/running state.
- Completed: removed the UE Android `Session.event_stopped` monkey-patch and changed Android lldb-dap attach config to `stopOnEntry=false` with `?process continue` inside `attachCommands` after breakpoint preseed / signal handling. The inferior is resumed inside lldb before the per-thread entry burst reaches nvim-dap.
- Verification: `lua/ue/dap.lua` and `lua/ue/dap/android.lua` parse checks passed; live nvim was hot-reloaded. Full user-path verification requires a fresh `<space>da` because an already-started DAP session keeps its original attachCommands.


## 2026-06-02 - Android DAP sanitize synthetic stack frames without empty-stack warnings

- Task: Stop repeated `Debug adapter stopped at unavailable location` warnings after UE Android lldb-dap attach without reintroducing E474 or swallowing stopped events.
- Evidence: lldb-dap returned many stackTrace responses whose frames were PC-only synthetic entries (`line=0`, `sourceReference>0`). Emptying those frames avoided E474 but made upstream nvim-dap warn once per stopped thread.
- Completed: `lua/ue/dap.lua` now strips `source` from synthetic UE Android frames instead of returning an empty stack. nvim-dap can keep frame/scopes by `frameId`, but `jump_to_frame()` exits before opening `dap-src://` or cursoring to line 0. Real local-file frames are still preserved.
- Verification: parse check passed and live nvim was hot-reloaded. Existing historical Snacks notifications remain in history; new attach/stackTrace responses should not add the unavailable-location burst.


## 2026-06-02 - Android DAP breakpoint preseed handles bufnr-keyed nvim-dap breakpoints

- Task: Fix F9 breakpoints showing verified in nvim but not actually stopping after UE Android attach.
- Evidence: live `dap.breakpoints.get()` returned breakpoints keyed by buffer id (`[8] = ...`) while the Android preseed code only handled string file paths. The live attachCommands contained no `?breakpoint set ...`, so LLDB never received the breakpoints. The `Source missing` notification came from PC-only synthetic entry frames and was not the root cause of the missed breakpoint.
- Completed: `lua/ue/dap/android.lua` and `lua/ue/dap.lua` now resolve both string-path keys and bufnr keys from nvim-dap breakpoint storage, dedupe by file:line, and generate `?breakpoint set -f "<basename>" -l <line>` for attachCommands preseed.
- Verification: parse checks passed and the running Neovide/nvim session was hot-reloaded. Because lldb-dap crashes on post-attach DAP `setBreakpoints`, existing active sessions still need stop/re-attach for newly fixed preseed commands to reach LLDB.


## 2026-06-02 - Android DAP breakpoint preseed moved after signal handlers

- Task: Avoid lldb-dap 22.1.6 crashing when breakpoint preseed commands are injected immediately after `gdb-remote`.
- Evidence: after fixing bufnr-keyed breakpoint discovery, the next attachCommands contained `?breakpoint set ...` directly after `?gdb-remote` and lldb-dap exited with `3221226505` before logging those commands. A live post-attach evaluate of `breakpoint set` also reproduced the same crash, confirming this command path is fragile in the direct gdb-remote attach flow.
- Completed: breakpoint preseed insertion now happens after the `process handle SIG*` commands, preserving the safe attach order: target create -> gdb-remote -> signal disposition -> breakpoint set. This still runs inside attachCommands, before nvim-dap's post-attach DAP `setBreakpoints` path.
- Verification: parse checks passed and live nvim was hot-reloaded. Requires another user-path attach to validate on device `a3ad86f3`.


## 2026-06-02 - Android DAP disable unsafe source breakpoint preseed

- Task: Stop repeated lldb-dap `3221226505` crashes when F9 breakpoints are present during UE Android attach.
- Evidence: live protocol logs on `a3ad86f3` showed attachCommands with `?breakpoint set -f "MobileShadingRenderer.cpp" ...` reaching symbol/DWARF indexing and then lldb-dap exiting with `3221226505` before any attach response or breakpoint command output. Moving preseed after signal handlers did not prevent the crash. A post-attach evaluate `breakpoint set` also crashed the adapter earlier, so both post-attach source breakpoints and attachCommands source-file breakpoint preseed are unsafe in this direct gdb-remote path.
- Completed: disabled source-file breakpoint preseed in `lua/ue/dap/android.lua` to keep attach stable; changed the UE Android synthetic `setBreakpoints` response to `verified=false` with an explicit message instead of falsely marking F9 as wired when LLDB has no breakpoint.
- Verification: parse checks passed, live nvim was hot-reloaded, and only adb serial `a3ad86f3` was cleaned (`lldb-server` killed, forwards removed, game SIGCONT'd). Follow-up needed: design a different validated breakpoint mechanism (likely function/address based, or another adapter command order) rather than source-file `breakpoint set` in lldb-dap 22.1.6.
