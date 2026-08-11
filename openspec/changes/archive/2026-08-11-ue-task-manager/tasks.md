## 1. 通用任务注册表核心模块（派生状态架构）

- [x] 1.1 新建 `lua/utils/task_registry.lua`（零业务依赖，不 `require("ue")`）：定义 state（`tasks` 表 + 单调不复用 `next_id` + 终态上界 `KEEP_DONE`）与记录结构 `{id, name, group, kind, handle}`——**MUST NOT 含 `state` 字段**（状态是派生量，D1/D2）。
- [x] 1.2 实现 `M.register(spec) -> id`：校验 `kind ∈ {job, system}`，写入记录，返回唯一 id。**MUST 为纯内存写入，不调任何 `vim.api`/`vim.fn`/`vim.notify`/IO/`vim.schedule`（C-INV-2）**。是注册表唯一常规写 `tasks` 的入口（D4）。
- [x] 1.3 实现 `M.status(id)`：**实时查询句柄**——`job` 经 `vim.fn.jobwait({handle},0)`（-1=running，>=0=已退+退出码），`system` 经 handle 存活查询；查询封装为可注入探针 `probe(rec)` 以便测试 mock。**无 `mark_done`、无 transition、无写回**（D2）。
- [x] 1.4 实现 `M.cancel(id) -> ok`：**先 `M.status` 复检**——已退出则不 kill、返回「未取消」；运行中则按 kind 取消（`job`→`vim.fn.jobstop`，`system`→`handle:kill(15)`），`pcall` 包裹。**取消后不写任何状态**（D3）；幂等（对已退/再次取消为安全 no-op）。
- [x] 1.5 实现 `M.cancel_all() -> n`：遍历运行中任务（按 `status`）取消，返回数量。
- [x] 1.6 实现 `M.get(id)` / `M.list()`：`list` 对每条实时 `status`，并把「已退出且超 `KEEP_DONE`」者裁剪（GC 是查询副产物，无 timer，D5）/ `M._reset_for_test()` / 测试注入探针的 `M._set_probe_for_test(fn)`。

## 2. async_launcher 取消接入（向后兼容）

- [x] 2.1 `lua/utils/async_launcher.lua`：`launch(opts)` 读取可选 `opts.cancel`，存 `state.cancel`。
- [x] 2.2 加 `<C-c>` 映射：`state.cancel` 存在则调用 `cancel` 后关窗；`q` **维持旧「仅隐藏」语义不变**（引理 3a：不传 cancel 时 `<C-c>` 分支也短路）。
- [x] 2.3 浮窗 hint 文案：有 `cancel` 时显示 `q dismiss · <C-c> cancel`，否则原 `press q to dismiss`。
- [x] 2.4 grep 全部 `async_launcher.launch` 调用点，确认均不传 `cancel`、`q` 行为不变。（4 处：keymaps restart、ue.lua UEPrepareReindex/UEIndexHot/UEIndexFull——均只传 name/group/run/hold_ms；仅 UEPrepare 显式传 cancel。`<C-c>` 在 cancel==nil 时短路，q 旧语义不变。）

## 3. 发起点接入注册表（只允许「创建后追加一行 register」，不碰 on_exit）

> 每个接入点 diff MUST 只含一处：创建语句后插 `pcall(task_registry.register, ...)`。**MUST NOT 修改/插入任何 `on_exit`/完成回调代码**（C-INV-1；派生状态架构无需 mark_done）。不改命令/cwd/env/原回调语句。给可接入的发起点（prepare/build）补 `opts.cancel = function() M.cancel(id) end` 传入 async_launcher。

- [x] 3.1 终端构建 `open_terminal_command`（`lua/ue.lua:5777`）：`termopen` 返回 jobid 后 `register({kind="job"})`。`on_exit` 零改动。
- [x] 3.2 prepare gtags（`lua/ue.lua:8756`，`CORE_RT.prepare_jobid`）：`register({kind="job"})`；`:UEPrepare` 的 async_launcher 传 `cancel`。`on_exit` 零改动。
- [x] 3.3 prepare ccjson（`lua/ue.lua:10032` 的 `vim.system` handle）：**保存此前丢弃的 handle** 并 `register({kind="system"})`。完成回调零改动。
- [x] 3.4 launch desktop/android（`lua/utils/ue_launch.lua:352/374`）：android launch job `register({kind="job"})`；desktop detach job 故意不登记（同短命 detach 例外）。`on_exit` 零改动。
- [x] 3.5 install android（`lua/ue.lua:8070`）：保存 jobid 并 `register`。`on_exit` 零改动。
- [x] 3.6 logcat（`lua/ue/dap.lua:1841`）与流式日志（`lua/utils/ue_logs.lua:609`）：`register({kind="job"})`；既有 `stop_logcat`/停止路径保持不变（停止后下次 `status` 自然反映已退）。
- [x] 3.7 显式**不接入**短命 detach job（`platform/*.lua`、`config/windows.lua` 的 `xdg-open`/`open`/`cmd start`）——Non-Goals，源码零改动。
- [x] 3.8 确认 Android DAP 会话（lldb-dap 适配器 / 真机进程）**不**登记为可 kill 任务（K5 边界）。

## 4. 用户交互：命令 / picker / statusline / 键位

- [x] 4.1 实现 `:Tasks` 列表：每行 `status 图标 + name + group + 时长/终态`（status 实时 `M.status`）；空列表给 notify 不开空 picker。（NOTE: 本期用 `vim.ui.select`（snacks 后端）满足核心诉求；双列 preview + `gl`/`<cr>` 富 picker 列为 design Open Question 的后续增强。）
- [x] 4.2 选中即停：`:Tasks` 选中 running 任务调 `M.cancel`（单个不确认），已结束任务给提示。（富 picker 多动作键 `gl`/`<cr>`/`<Tab>` 批量随 4.1 一并留后续。）
- [x] 4.3 注册 `:TaskStop [id]`：带 id 停指定；无参时唯一运行任务直接停（不确认）、多个走 select、零个提示。
- [x] 4.4 注册 `:TaskStopAll`：`vim.fn.confirm("停掉 N 个任务？")` 一次确认 → `M.cancel_all` → 汇总通知。
- [x] 4.5 statusline 计数段：复用 `M.statusline_status` 既有 eval（不新增 timer），running 数 N>0 显示 `⏵N`，N==0 不显示。
- [x] 4.6 取消反馈：单个取消一次 `vim.notify("已停止 <name>")`；发起/完成复用 fidget 句柄。
- [x] 4.7 `lua/config/keymaps.lua` 通用层加 `<leader>X` → `:Tasks`（核对未占用）。

## 5. 测试与冻结清单同步（验证「竞态不存在」而非「竞态被防住」）

- [x] 5.1 新建 `tests/cases/task_registry_spec.lua`：register / `status` 派生（mock 探针翻转 running→done）/ 两类 kind cancel（mock handle）/ cancel 前复检 / get 不存在 / id 单调不复用。
- [x] 5.2 **AR-T1** 状态即真相：注入 mock 探针返回 -1→`status=running`，翻转为 0→`status=done`，全程未调任何注册表写函数。
- [x] 5.3 **AR-T2/T3** 取消语义：T2 取消运行中→句柄被调、注册表未写状态、随后 `status=cancelled`；T3 取消已退出→不调句柄（计数 0）、不报错、返回 false。
- [x] 5.4 **AR-T4** 无回调写路径：源码扫描 `register` 体无 `vim.api`/`vim.notify`/`io.`/`vim.schedule`；无 `M.mark_done`/`M.transition`（C-INV-1/2 守护）。
- [x] 5.5 **AR-T5** list GC 幂等：登记 `KEEP_DONE+5` 个并全部 mock 已退→连续两次 `list()` 稳定、终态 ≤ `KEEP_DONE`、running 恒在列。
- [x] 5.6 DAP 边界断言：`cancel_all` 只作用于注册表内任务集合，不含 DAP 会话。
- [x] 5.7 UX 行为断言：`running_count` N==0/N>0 计数正确（statusline 段来源）；DAP 边界 cancel_all 作用域。（`:TaskStopAll` confirm-mock 与 picker 富 UI 随 4.1 富 picker 增强一并留后续。）
- [x] 5.8 同步 `tests/cases/commands_spec.lua` 的命令冻结清单：加 `Tasks`/`TaskStop`/`TaskStopAll`，更新计数断言。
- [x] 5.9 跑分范围回归 `commands` `utils` `smoke`（async_launcher 改动）并全绿；C6 提交前跑全量 `nvim --headless -l tests/run.lua`。（全量 540/540。）

## 6. 文档与知识库

- [x] 6.1 `lua/utils/cheatsheet.lua` 加 `<leader>X` / `:Tasks` 等条目（新增「Tasks」段）。
- [x] 6.2 `README.md` / `docs/README.zh-CN.md` 通用键位/命令表补充任务管理 + statusline `⏵N` 段说明。
- [x] 6.3 `docs/changelog.md` Unreleased 追加一条（模板齐全；Validation 写明所跑回归范围与结果）。
- [x] 6.4 `lua/utils/CLAUDE.md` 补一行维护契约：新增后台发起点只需「创建后追加一行 `task_registry.register`」，**不要**在 on_exit 里回写状态（派生状态架构）。
