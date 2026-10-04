# task-management Specification

## Purpose

定义 Neovim 通用后台任务注册、派生状态、取消、任务列表、命令与 statusline 的
行为边界：一个业务无关的纯内存任务注册表，登记 job/system 两类后台任务，
供 `:Tasks` / `:TaskStop` / `:TaskStopAll` 与 statusline 计数复用。核心立场
是「状态为派生量」——不存储状态副本，只在查询时向句柄实时求值，从架构上
消除竞态。边界：注册表不管理 DAP 调试会话（进程杀错会杀死真机被调试进程），
也不新增任何周期性 timer。

## Requirements

### Requirement: 通用任务注册表登记后台任务，不存储状态副本

系统 SHALL 提供业务无关的纯内存任务注册表（`lua/utils/task_registry.lua`），
登记记录至少含唯一 `id`（单调递增、不复用）、`name`、`group`、`kind`
（`job` | `system`）、取消所需句柄引用。记录 MUST NOT 存储 `state` 字段——
任务状态由 `M.status(id)` 实时查询句柄得出。MUST 通过 `M.*` 公共 API 暴露
登记/查询/取消，且可在 `nvim --headless` 下自验证，不依赖 UE / 业务模块。

#### Scenario: 记录中不含 state 副本
- **WHEN** 检视任一登记记录的字段
- **THEN** 不存在被写入/缓存的 `state` 字段；状态只能经 `M.status(id)`
  查询得出

### Requirement: 状态为派生量，取消操作句柄而不回写状态

任务状态 SHALL 由 `M.status(id)` 实时查询句柄得出（`job` 经
`vim.fn.jobwait`，`system` 经其存活查询）；注册表 MUST NOT 维护状态转移
函数或 `on_exit` 写回路径。`M.cancel(id)` SHALL 先以 `M.status(id)` 复检：
已退出则不再调用取消句柄；运行中则按 `kind` 调用取消并 `pcall` 包裹，
取消后 MUST NOT 回写状态副本。取消 SHALL 幂等。由此每个任务状态在任意
回调到达顺序下都唯一确定于「查询那一刻句柄的真相」。

#### Scenario: 取消前复检——已退出则不重复 kill
- **WHEN** 对一个句柄已退出的任务调 `M.cancel(id)`
- **THEN** 不调用 `jobstop`/`:kill`，返回「未取消」，不抛错

### Requirement: 接入既有 job 只允许追加式登记，不改变原有行为

接入注册表 MUST NOT 改变既有 job 的可观察行为：只允许在 job 创建语句之后
用其已有句柄调用一次 `pcall(M.register, ...)`；MUST NOT 修改传给
`jobstart`/`vim.system`/`termopen` 的命令、参数、`cwd`、`env`、
`stdout`/`stderr`，MUST NOT 修改或插入任何 `on_exit`/完成回调代码。
`M.register` 失败 MUST 被 `pcall` 隔离，job 本体照常运行。

#### Scenario: 命令与回调逐字节不变
- **WHEN** 某发起点接入注册表后再次运行
- **THEN** 其命令行、cwd、env、stdout/stderr 与 `on_exit` 回调体与接入前
  逐字节相同

### Requirement: `:Tasks` / `:TaskStop` / `:TaskStopAll` 提供统一操作面

`:Tasks`（共享底部任务列表，打开/刷新时从句柄求状态，`<CR>` / `dd` 停止不二次
确认、`r` 刷新，空表给可见提示）、`:TaskStop [id]`（无参且唯一运行中
任务直接停、多个走选择器）与 `:TaskStopAll`（执行前 MUST 一次性确认，
确认后取消所有运行中任务并报告数量）SHALL 提供统一的任务操作面。

#### Scenario: TaskStopAll 先确认
- **WHEN** 有 N 个运行中任务时执行 `:TaskStopAll`
- **THEN** 先弹一次确认；确认后 N 个任务句柄被取消，通知「已停止 N 个任务」

### Requirement: statusline 计数与反馈遵守 P5，不新增周期性 ticker

statusline SHALL 在 N>0 个运行中任务时显示极简计数段，N==0 时完全不显示；
计数 SHALL 在既有刷新时机求值，MUST NOT 为此新增周期性 timer（P5）。
发起/完成/取消 SHALL 复用既有 `fidget.progress` 句柄；取消给一次
`vim.notify` 反馈，MUST NOT 周期性轮询刷新 `:messages`。

#### Scenario: 无运行任务时不显示
- **WHEN** 没有运行中任务
- **THEN** statusline 不出现任务计数段（无 `⏵0`、不占位）

### Requirement: 调试会话不经任务注册表通用取消路径

任务注册表 MUST NOT 通过通用取消路径对 Android DAP 调试会话发送会杀死真机
被调试进程的信号（既有 K5：默认 terminate 会 SIGKILL 设备游戏）。注册表
SHALL 不登记 DAP 适配器会话为可 kill 任务；停止 DAP SHALL 仍走
`:UEDAPStop`（`terminateDebuggee=false` detach）。

#### Scenario: TaskStopAll 不触及 DAP 适配器进程
- **WHEN** 执行 `:TaskStopAll`
- **THEN** 仅取消注册表内登记的辅助任务，不取消或杀死 lldb-dap 适配器与
  真机被调试进程

## 选型与踩坑

- **选型（2026-10-03 IDE）**：终态优先展示原生句柄可取得的退出码；不可取得时标 unknown，
  不在 on_exit 保存另一份状态。底部面板保留有界阶段历史，后台完成保持源码焦点；运行链路
  以冻结选择和 operation owner 消费真实完成回应，发出 launch/attach 请求不等于成功。

- **选型（2026-10-03）**：任务列表与构建输出、原生 quickfix、logcat 共享每 tab 的底部窗口，
  只换 buffer，不叠窗口。显式切换/刷新才读取任务状态；不新增轮询，隐藏面板不取消进程。
  构建退出后保留输出，日志停止仍由原 owner 执行；调试 UI 只能关闭自己当前可见的内容。

- **选型**：状态设计为派生量而非存储副本，是本 capability 的核心架构
  决策：唯一常规写 `tasks` 的入口是 `M.register`（只在创建 job 时调用），
  故不存在回调写回竞态；`cancel` 只操作句柄、不回写，故不存在「副本落后
  于真相」这类竞态——靠架构消除竞态，而非运行期加锁/校验规避。
- **选型**：接入既有 job 限定为「创建语句后追加一行 `pcall(M.register,...)`」
  的单一编辑动作，不允许触碰 `on_exit`，保证接入是零行为风险的重构。
- **踩坑**：DAP 会话必须排除在通用取消路径之外——K5 记录了 Android 上
  默认 terminate 会 SIGKILL 设备上的被调试进程；若 `:TaskStopAll` 误把
  DAP 适配器当普通任务取消，会造成杀死真机游戏进程的严重后果。
- **重要事项**：statusline 计数与进度反馈都复用现有刷新时机/`fidget`
  句柄，不新增任何周期性 timer 或轮询——这是 P5 在本 capability 内的具体
  应用；终态记录数量有界（`KEEP_DONE`），裁剪只在 `list()` 查询时进行。
