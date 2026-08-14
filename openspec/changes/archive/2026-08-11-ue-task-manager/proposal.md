## Why

本仓有大量后台任务（终端构建、index/prepare 子进程、launch/install、文件流式 logcat、`xdg-open`/`open` 之类 detach job 等），但**没有统一的「看得到、停得掉」入口**：句柄散落在各模块局部变量或 `CORE_RT.*` 字段，部分 `vim.fn.jobstart` / `vim.system` 句柄根本没保存，`async_launcher` 浮窗的 `q` 也明确「只隐藏指示器、不取消底层 job」（见 `lua/utils/async_launcher.lua`）。用户「发起一个任务后想把它停掉」目前无路可走，只能手动找终端 buffer 杀或重启 nvim。

这是一个**通用编辑器能力**，不绑定 UE。社区有成熟范式（overseer.nvim 的 task registry + task list + `Task:stop()`/`dd`，asyncrun/asynctasks 的 job 跟踪），但都偏重（独立 UI / 模板系统，与 snacks-only 生态正交）。本 change 用本仓既有 async 基础设施抽出一个**通用、轻量的任务注册表**，给任意后台任务补「列出 / 停止」能力，不引入新依赖。

## What Changes

- 新增**通用任务注册表** `lua/utils/task_registry.lua`（纯内存、与 UE 无关）：登记每个后台任务的 `id` / `name` / `group` / `kind`（`job`=jobstart/termopen 的 channel | `system`=`vim.system` handle）/ 取消句柄。**任务状态不存储，由 `M.status(id)` 实时查询句柄派生**（详见 design.md「从架构消除竞态」）。`M.*` 公共 API，可 headless 自验证。
- 新增通用用户命令（**非 UE 前缀**）：
  - `:Tasks` — snacks.picker 自定义源（双列：左列表 + 右预览），列出任务及实时状态，picker 内 `dd` 停、`<cr>` 聚焦终端/日志、`gl` 看日志。
  - `:TaskStop [id]` — 停止指定任务；无参时若仅一个运行中任务则直接停（不确认），多个走选择器。
  - `:TaskStopAll` — 停止全部运行中任务（一次确认 `停掉 N 个任务？`）。
- 新增键位 `<leader>X`（任务列表/停止），通用层（`lua/config/keymaps.lua`），不挂在 `<leader>u*`（UE 专属）下。
- 新增 statusline 计数段 `⏵N`（N>0 时显示运行中任务数，N==0 不显示；复用既有 statusline 刷新 tick，不新增 timer，合 P5）。
- `lua/utils/async_launcher.launch` 增加可选 `cancel` 回调；浮窗 `<C-c>` 真正取消底层 job，`q` 维持「仅隐藏」旧语义（向后兼容）。
- 现有任务发起点**接入注册表**（复用既有 job 创建，不改其执行）：终端构建（`open_terminal_command`）、prepare 子进程（gtags `jobstart` + ccjson `vim.system`）、launch/install（`ue_launch.lua` / `install_android`）、logcat（`dap.lua` / `ue_logs.lua`）。一次性短命 `detach=true` 的 `xdg-open`/`open`/`cmd /c start` 类**不登记**（无意义、无句柄管理价值）。
- **取消边界**：Android DAP 调试会话**不**经本注册表 SIGKILL（会杀真机被调试进程，违反既有 K5 约束）；停止 DAP 仍走 `:UEDAPStop`。注册表只管「我们 spawn 的本机辅助进程」。

## Capabilities

### New Capabilities
- `task-management`: 通用后台任务的统一登记、列出与取消契约——**派生状态（不存副本，竞态由架构消除）**、单一 `register` 写入入口、两类 job（`job` channel / `system` handle）的取消机制、`:Tasks`/`:TaskStop`/`:TaskStopAll` 命令、`async_launcher` 取消接入，以及对调试会话「不经此路 kill」的边界。design.md 给出「登记侧路对既有 job 行为等价」的理论证明，并论证鲁棒性是从架构（派生状态 + 单一写者）结构性消除竞态，而非用运行期规则约束。

### Modified Capabilities
<!-- 无既有 spec 的 REQUIREMENT 行为契约发生变更。命令冻结清单（commands_spec 的 UE_COMMANDS）变化属冻结清单同步，在 tasks 中处理。 -->

## Impact

- 新增运行时代码：`lua/utils/task_registry.lua`（通用，零 UE 依赖）。
- 修改运行时代码：`lua/utils/async_launcher.lua`（`cancel` 接入）、命令与键位注册（通用层）、各发起点接入 `register`/`mark_done` 并保存此前丢弃的句柄（ccjson `vim.system` handle、launch/install jobid）。
- 测试：新增 `tests/cases/task_registry_spec.lua`；同步 `commands_spec` 的冻结清单与计数。
- 文档：`docs/changelog.md`、cheatsheet、README 键位表。
- 不引入新依赖；不改任何现有 job 的执行行为（等价性见 design.md §「行为等价性证明」）。
