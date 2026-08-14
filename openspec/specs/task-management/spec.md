# task-management Specification

## Purpose

定义 Neovim 通用后台任务注册、派生状态、取消、任务列表、命令与 statusline 的行为边界。

## Requirements

### Requirement: 通用任务注册表登记后台任务

系统 SHALL 提供一个与具体业务无关的纯内存任务注册表（`lua/utils/task_registry.lua`），为任意后台任务登记一条记录，记录至少包含：唯一 `id`（单调递增、不复用）、`name`、`group`、`kind`（取值 `job` | `system`）、取消所需的句柄引用。记录 MUST NOT 存储 `state` 字段——任务状态是**派生量**，由 `M.status(id)` 实时查询句柄得出（见「状态为派生量」要求）。注册表 MUST 通过 `M.*` 公共 API 暴露登记、查询、取消能力，且可在 `nvim --headless` 下自验证，不依赖任何 UE / 业务模块。

#### Scenario: 登记一个 job（channel）任务

- **WHEN** 调用 `M.register({ name = "build", group = "make", kind = "job", handle = <chan_id> })`
- **THEN** 返回唯一 `id`，`M.list()` 中存在该任务，其派生状态为 `running`

#### Scenario: 登记一个 system 任务

- **WHEN** 调用 `M.register` 且 `kind = "system"`、`handle` 为 `vim.system` 返回对象
- **THEN** 该任务被登记，保存可调用 `:kill()` 的 handle 引用

#### Scenario: 记录中不含 state 副本

- **WHEN** 检视任一登记记录的字段
- **THEN** 不存在被写入/缓存的 `state` 字段；状态只能经 `M.status(id)` 查询得出

#### Scenario: id 单调不复用

- **WHEN** 连续登记两个任务
- **THEN** 第二个 `id` 严格大于第一个，即使第一个对应的 job 已退出

#### Scenario: 查询不存在的任务

- **WHEN** 调用 `M.get(<不存在 id>)`
- **THEN** 返回 `nil`，不抛错

### Requirement: 状态为派生量（derived），不存储

任务状态 SHALL 由 `M.status(id)` 在被调用时**实时从句柄查询**得出，而非读取任何存储的状态字段：`job` 经 `vim.fn.jobwait({handle}, 0)`（-1=running，>=0=已退出），`system` 经其 handle 的存活查询。注册表 MUST NOT 维护 `mark_done` / 状态转移函数 / `on_exit` 写回路径。由此，「存储状态与真实进程不一致」这一类竞态在架构上不存在。

#### Scenario: 状态实时反映句柄

- **WHEN** 一个登记任务的底层句柄从「运行中」变为「已退出」
- **THEN** 下一次 `M.status(id)` 返回 `done`（或其退出码），无需任何 mark/通知/同步

#### Scenario: 无 on_exit 写回路径

- **WHEN** 扫描注册表实现与所有接入点
- **THEN** `on_exit` / `vim.system` 完成回调体内不存在对 `task_registry` 的写调用；注册表中唯一常规写 `tasks` 的路径是 `M.register`

### Requirement: 取消即操作句柄，不回写状态

`M.cancel(id)` SHALL 先以 `M.status(id)` 复检：若已退出则不再调用取消句柄、直接返回「未取消」；若运行中则按 `kind` 调用取消（`job` → `vim.fn.jobstop`，`system` → `handle:kill(signal)`），`pcall` 包裹。取消后 MUST NOT 回写任何状态副本——其效果由下次 `status`/`list` 实时查询反映。取消 SHALL 幂等：对已退出/已取消任务再次调用为安全 no-op。

#### Scenario: 取消运行中的 job 任务

- **WHEN** 对句柄运行中的 `kind="job"` 任务调 `M.cancel(id)`
- **THEN** 调用 `vim.fn.jobstop` 终止该 channel，且注册表未写任何状态字段；随后 `M.status(id)` 实时返回 `done`

#### Scenario: 取消前复检——已退出则不重复 kill

- **WHEN** 对一个句柄已退出的任务调 `M.cancel(id)`
- **THEN** 不调用 `jobstop`/`:kill`（取消句柄调用次数为 0），返回「未取消」，不抛错

#### Scenario: 取消幂等

- **WHEN** 连续两次对同一任务 `M.cancel(id)`
- **THEN** 第二次为安全 no-op，不抛错

### Requirement: 登记侧路对既有 job 行为等价

把一个既有后台 job 接入注册表 MUST NOT 改变该 job 的可观察行为。接入**只允许一种编辑**：在 job 创建语句之后用其已有句柄调用一次 `pcall(M.register, ...)`。接入 MUST NOT 修改传给 `jobstart`/`vim.system`/`termopen` 的命令、参数、`cwd`、`env`、`stdout`/`stderr`，**MUST NOT 修改或在其中插入任何对 `on_exit`/完成回调的代码**，也 MUST NOT 改变 job 的创建时机或条件。

#### Scenario: 命令与回调逐字节不变

- **WHEN** 某发起点接入注册表后再次运行
- **THEN** 其底层进程命令行、cwd、env、stdout/stderr 处理与 `on_exit`/完成回调体与接入前逐字节相同（接入只在创建后追加一行 `register`）

#### Scenario: register 失败不影响 job

- **WHEN** `M.register` 因任何原因抛错（理论上不应发生）
- **THEN** 接入点 MUST 用 `pcall` 隔离，job 本体照常运行、照常完成（登记是尽力而为的侧路）

### Requirement: `:Tasks` 双列 picker 列出并操作任务

系统 SHALL 注册通用命令 `:Tasks`，用 snacks.picker 自定义源列出全部任务，每行显示 `status 图标` / `name` / `group` / 运行时长或终态词，`status` 列 MUST 由 `M.status()` 实时求值；右侧预览 SHALL 显示该任务的终端 buffer 或日志尾部（缺失时显示占位提示，不报错）。picker SHALL 提供多动作键：`dd` 停止选中任务（`M.cancel`，单个停止不二次确认）、`<cr>` 聚焦其终端/日志、`gl` 打开完整日志、`q`/`<esc>` 关闭。注册表为空时 MUST 给可见提示而非打开空 picker。

#### Scenario: 命令已注册

- **WHEN** 配置加载完成后查询 `:Tasks`
- **THEN** 该命令存在（`vim.fn.exists(":Tasks") == 2`）

#### Scenario: status 列实时求值

- **WHEN** 打开 `:Tasks` 时某任务句柄已退出
- **THEN** 该行 `status` 显示为已退出（done/cancelled），而非缓存的旧值

#### Scenario: dd 停止选中任务且不二次确认

- **WHEN** 在 `:Tasks` 中对一个运行中任务按 `dd`
- **THEN** 直接调用 `M.cancel`（无确认弹窗），其句柄被取消，随后 `status` 实时反映已退出，给出一次反馈通知

#### Scenario: 预览缺失不报错

- **WHEN** 选中一个无可用终端/日志的运行中任务
- **THEN** 预览区显示占位提示（如「(running, no log)」），不抛错

#### Scenario: 无任务时提示

- **WHEN** 注册表为空时执行 `:Tasks`
- **THEN** 显示「无后台任务」一类提示，不打开空 picker

### Requirement: `:TaskStop` 与 `:TaskStopAll`

系统 SHALL 注册 `:TaskStop [id]` 与 `:TaskStopAll`。`:TaskStop` 带 `id` 停指定；无参时唯一运行中任务直接停、多个走选择器、零个提示。`:TaskStop` 停单个 MUST NOT 二次确认（可逆操作）。`:TaskStopAll` MUST 在执行前一次性确认（`停掉 N 个任务？[y/N]`），确认后取消所有运行中任务并报告数量。

#### Scenario: 命令已注册

- **WHEN** 配置加载完成后查询 `:TaskStop` 与 `:TaskStopAll`
- **THEN** 两命令均存在

#### Scenario: 无参且唯一运行任务直接停止（不确认）

- **WHEN** 恰有一个运行中任务时执行无参 `:TaskStop`
- **THEN** 该任务句柄被取消（无确认弹窗、无选择器）

#### Scenario: TaskStopAll 先确认

- **WHEN** 有 N 个运行中任务时执行 `:TaskStopAll`
- **THEN** 先弹一次确认；确认后 N 个任务句柄被取消，通知「已停止 N 个任务」；取消确认则不停任何任务

### Requirement: statusline 运行中任务计数段

statusline SHALL 在有 N>0 个运行中任务时显示一个极简计数段（如 `⏵N`），N==0 时该段完全不显示（不占位）。计数 SHALL 由 `task_registry.list()` 过滤运行中得出，并在 statusline **既有刷新时机**求值，MUST NOT 为此新增周期性 timer（合 P5）。

#### Scenario: 有运行任务时显示计数

- **WHEN** 存在 2 个运行中任务且 statusline 刷新
- **THEN** statusline 含 `⏵2` 一类计数段

#### Scenario: 无运行任务时不显示

- **WHEN** 没有运行中任务
- **THEN** statusline 不出现任务计数段（无 `⏵0`、不占位）

### Requirement: 操作反馈不刷屏

发起 / 完成 / 取消 SHALL 复用既有 `fidget.progress` 句柄给出进度（只 start + 中段 + 收尾自然消退，无周期 toast，合 P5）。取消单个任务 SHALL 给一次 `vim.notify` 反馈；`:TaskStopAll` 给一次汇总通知。MUST NOT 周期性轮询刷新 `:messages`。

#### Scenario: 取消给一次通知

- **WHEN** 取消一个运行中任务
- **THEN** 恰有一次反馈通知（如「已停止 build」），无重复刷屏

#### Scenario: 无周期性 ticker

- **WHEN** 任务在后台运行期间
- **THEN** 任务管理本身不产生周期性通知（进度由各任务自身的 fidget 句柄负责）

### Requirement: async_launcher 取消接入（向后兼容）

`lua/utils/async_launcher.launch` SHALL 接受可选 `cancel`（function）。提供时，占位浮窗 SHALL 用 `<C-c>` 触发 `cancel` 真正取消底层 job，并在浮窗 hint 显示该取消键；`q` MUST 维持现有「仅隐藏指示器、不取消 job」语义。未提供 `cancel` 时所有现有调用点行为不变。

#### Scenario: 提供 cancel 时 <C-c> 触发取消

- **WHEN** 以带 `cancel` 的参数调用 `launch`，随后在浮窗按 `<C-c>`
- **THEN** `cancel` 被调用一次且浮窗关闭

#### Scenario: q 维持仅隐藏语义

- **WHEN** 在带 `cancel` 的浮窗按 `q`
- **THEN** 仅关闭/隐藏浮窗，不调用 `cancel`、不取消 job

#### Scenario: 未提供 cancel 时保持旧行为

- **WHEN** 以不带 `cancel` 的参数调用 `launch` 后按 `q`
- **THEN** 仅关闭/隐藏浮窗，不取消任何 job

### Requirement: 调试会话不经任务注册表 SIGKILL

任务注册表 MUST NOT 通过通用取消路径对 Android DAP 调试会话发送会杀死真机被调试进程的信号（遵守既有 K5：默认 terminate 会 SIGKILL 设备游戏）。注册表 SHALL 不登记 DAP 适配器会话为可 kill 任务；停止 DAP SHALL 仍走 `:UEDAPStop`（`terminateDebuggee=false` detach）。

#### Scenario: DAP 停止走专用路径

- **WHEN** 用户希望停止一个 Android DAP 会话
- **THEN** 系统引导其使用 `:UEDAPStop`，注册表不对该会话调 `jobstop`/`:kill`

#### Scenario: TaskStopAll 不触及 DAP 适配器进程

- **WHEN** 执行 `:TaskStopAll`
- **THEN** 仅取消注册表内登记的辅助任务（build/prepare/launch/install/logcat），不取消或杀死 lldb-dap 适配器与真机被调试进程

### Requirement: 异步竞态由架构消除（派生状态 + 单一写入入口）

注册表 MUST 通过架构而非运行期规则消除竞态：状态为派生量（不存副本，故无「副本 vs 真相」竞态）；唯一常规写 `tasks` 的入口是 `M.register`（只在主循环创建 job 时调用，故无回调写回竞态）；`cancel` 操作句柄、不回写。由此每个任务的状态在任意回调到达顺序下都唯一确定于「查询那一刻句柄的真相」。注册表对终态记录数量 SHALL 设上界（`KEEP_DONE`），裁剪在 `list()` 查询时进行（无后台 timer，合 P5）。

#### Scenario: 状态即真相——无 mark 也正确

- **WHEN** 句柄从运行中翻转为已退出（不调用任何注册表写函数）
- **THEN** `M.status(id)` 立即返回 `done`，`M.list()` 反映之

#### Scenario: 取消-退出并发无竞态

- **WHEN** 在 job 即将自然退出的同时调用 `M.cancel(id)`
- **THEN** 无论二者到达顺序如何，最终 `M.status(id)` 一致返回 `done`；取消句柄至多被调用一次（`cancel` 前的 `status` 复检保证已退出时不再 kill）

#### Scenario: 无 fast-event 写入风险

- **WHEN** 检视注册表代码在 `on_exit`/`vim.system` 回调上下文中的执行
- **THEN** 注册表不在这些回调里运行任何代码（无写回路径），故不存在 fast-event 下调用 `vim.api`/`vim.fn` 的风险

#### Scenario: 终态记录数量有界且 GC 幂等

- **WHEN** 登记并令超过 `KEEP_DONE` 个任务句柄退出后，连续两次 `M.list()`
- **THEN** 两次结果稳定，终态记录数 ≤ `KEEP_DONE`，所有运行中任务始终在列

#### Scenario: 选择器时窗内任务已结束

- **WHEN** `:Tasks`/`:TaskStop` 选中一个在操作期间句柄已退出的任务
- **THEN** `cancel` 经 `status` 复检判定已退出 → 不 kill、不报错，命令层给「该任务已结束」一类提示
