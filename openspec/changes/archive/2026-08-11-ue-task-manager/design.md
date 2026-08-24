## Context

本仓所有后台工作都遵守「async-first，不阻塞主线程」（CONSTRAINTS P6 / C4.2）。但每个发起点各自管理句柄，没有统一的「列出 / 停止」入口，且部分句柄根本未保存：

| 发起点 | 文件:行 | 机制 | 句柄现状 |
|---|---|---|---|
| 终端构建 | `lua/ue.lua:5777` | `vim.fn.termopen` | 存 `CORE_RT.build_term_jobid`，有探活无停止 |
| prepare gtags | `lua/ue.lua:8756` | `vim.fn.jobstart` | 存 `CORE_RT.prepare_jobid` |
| prepare ccjson | `lua/ue.lua:10032` | `vim.system` | **局部 `handle`，未保存** |
| launch desktop/android | `lua/utils/ue_launch.lua:352/374` | `vim.fn.jobstart` | **jobid 用完即弃** |
| install android | `lua/ue.lua:8070` | `vim.fn.jobstart` | **未保存** |
| logcat | `lua/ue/dap.lua:1841` | `vim.fn.jobstart` | 存 `logcat_job`，有 `stop_logcat` |
| 流式日志 | `lua/utils/ue_logs.lua:609` | `vim.fn.jobstart` | 存 `state.jobid` |
| `xdg-open`/`open`/`start` | `platform/*.lua`, `config/windows.lua` | `jobstart{detach=true}` | 短命、无管理价值 |

`async_launcher` 浮窗 `q` 注释明确：「The underlying job is NOT cancelled — this only hides the indicator.」（`lua/utils/async_launcher.lua:160`）。

这是**通用编辑器能力**，与 UE 无关。社区参照 overseer.nvim（registry + task-list buffer + `Task:stop()`），但重且 UI 与 snacks 生态正交（P1/P10）。

## Goals / Non-Goals

**Goals:**

- 通用、轻量、零业务依赖的任务注册表，命令/键位走通用层（`:Tasks` / `<leader>X`），不带 UE 前缀。
- **接入既有 job 不改其执行行为**——这是硬约束，须给出理论证明。
- 纯内存、headless 可测，不引入依赖。
- 取消对两类 job（`job` channel / `system` handle）正确分发。

**Non-Goals:**

- 不引入 overseer 等重型运行器，不做任务模板系统、不做独立 task-list buffer。
- 不接管 DAP 会话停止（K5）。
- 不登记短命 detach `xdg-open`/`open`/`cmd start`（无句柄管理价值）。
- 不做跨会话持久化、不做进程树级 kill（MSBuild 派生 cl.exe 等留作 Follow-up）。

## Decisions

### D1：注册表只存「句柄 + 元数据」，不存状态机

`lua/utils/task_registry.lua`，`state.tasks = { [id]=rec }`，`rec = { id, name, group, kind, handle }` —— **没有 `state` 字段、没有 `mark_done`、没有状态转移函数**。`next_id` 单调不复用。公共 API：`register(spec)->id`、`status(id)`、`cancel(id)->ok`、`cancel_all()->n`、`get(id)`、`list()`、`_reset_for_test()`。零 `require("ue")`。

这是鲁棒性的**架构根因**：竞态的来源永远是「存了一份状态副本，它和真实世界可能不一致」。不存状态副本，就没有可被竞争的对象（详见下文「鲁棒性的架构来源」）。

### D2：状态是 derived（实时查询），不是 stored

任务状态由 `M.status(id)` **每次实时从句柄查询**得出，而非读一个字段：

```lua
function M.status(id)
  local r = tasks[id]; if not r then return nil end
  if r.kind == "job" then
    -- jobwait(_,0) 非阻塞：-1=running，>=0=已退出(即 exit code)
    local w = vim.fn.jobwait({ r.handle }, 0)[1]
    return w == -1 and "running" or "done", (w >= 0 and w or nil)
  else -- system
    return r.handle:is_closing() and "done" or "running"
  end
end
```

`running` / `done` 永远等于 job-control 此刻的真相。**不存在「我以为它在跑但其实已退」的窗口**——因为没有「我以为」。

### D3：取消即 `jobstop`/`:kill`，无需先抢状态

`M.cancel(id)`：`job` → `vim.fn.jobstop(handle)`，`system` → `handle:kill(15)`，`pcall` 包裹。**取消后不写任何状态**——下一次 `status`/`list` 自然反映「已退」。对已退 job 调 `jobstop`/`:kill` 由运行时保证安全（见下「外部保证的复用」）。取消天然幂等：再调一次还是对一个已死句柄 no-op。

### D4：唯一可变写入点是 `register`，且只追加、永不并发改同一记录

`register` 是注册表中**唯一**写 `tasks` 的常规路径（`list` 的 GC 是裁剪、见 D5）。它由用户在主循环创建 job 时调用，天然串行、不与任何回调争用同一 `rec`。没有 `on_exit`→`mark_done` 的写回，也就没有「cancel 写 vs exit 写」这条经典竞态边——它在架构上根本不存在。

### D5：list 即查询，过期即纠正；GC 是查询的副产物

`list()` 遍历 `tasks`，对每条**实时** `status()`；顺手把「已 `done` 且超出 `KEEP_DONE` 上界」的记录从表里删掉（纯裁剪，不触 running）。无 timer、无周期 ticker（符合 P5）。用户看到的永远是「查询那一刻的真相」，不依赖任何后台同步。

### D6：async_launcher 向后兼容接入 cancel

`launch(opts)` 新增可选 `opts.cancel`；浮窗取消键有 `cancel` 才取消，否则旧语义。所有现有调用点不传 `cancel`，行为不变。

### D7：通用命令与键位

`:Tasks` / `:TaskStop [id]` / `:TaskStopAll`；`<leader>X` → `:Tasks`。命令名无前缀，体现「通用功能」定位。`:Tasks` 列表与停止都基于 `list()`/`status()`/`cancel()`，即「先查实时状态、再操作」，操作落空（任务已 done）由 `cancel` 幂等吞掉。

### D8：DAP 边界

logcat（我们 spawn 的 adb 子进程）可登记可停。DAP **会话**（lldb-dap 适配器 + 真机进程）不登记；停止转 `:UEDAPStop`。`cancel_all` 只遍历注册表，天然不触及 DAP。

---

## 用户交互设计（UX）

任务管理是「平时不可见、需要时一键召出」的能力。设计目标：**默认零打扰**（不刷屏、不抢焦点、不轮询），**需要时信息密度足够**（一眼看清谁在跑、停哪个），**操作直觉对齐编辑器肌肉记忆**（snacks.picker 的 `dd`、`<cr>`）。

### 三层可见性（从被动到主动）

```
被动感知 ──────────────► 主动召出 ──────────────► 即时反馈
statusline «⏵2»          :Tasks / <leader>X        一次 notify
(余光看到有 2 个在跑)      (双列 picker 列表+预览)     ("已停止 build")
```

#### 第 1 层：statusline 计数段（被动、零打扰）

statusline 已有 build status 段（`BOK`/`Bxxx`，`set_build_status`）。新增一个**极简计数段**：

- 有 N>0 个运行中任务时显示 `⏵N`（如 `⏵2`）；N==0 时该段**完全消失**（不占位、不显示 `⏵0`）。
- 纯指示，无点击/跳转逻辑（statusline 本就不易点击；保持简单）。
- 计数来源 = `task_registry.list()` 过滤 running 的数量，**在 statusline 既有刷新时机求值**（BufEnter/定时刷新——复用现有 `M._statusline_timer` 的 tick，不新增 timer，合 P5）。
- 这是「余光感知」：用户不必主动查，就知道后台有没有活在跑。

#### 第 2 层：`:Tasks` 双列 picker（主动召出，信息密度高）

主入口是 snacks.picker 自定义源（与本仓 grep/files 同栈，复用 `picker_first_open_freeze` 等既有 workaround，不引入第二套 UI）：

```
╭─ Tasks (3) ─────────────────╮╭─ Preview ──────────────────╮
│ ● build    make    00:42     ││ $ UnrealBuildTool ... -Win64│
│ ○ prepare  ue      done      ││                             │
│ ● logcat   dap     03:11     ││ [tail of build terminal /   │
│                              ││  prepare log / logcat]      │
╰──────────────────────────────╯╰─────────────────────────────╯
  dd stop · <cr> focus · gl log · q close
```

- **每行**：`status 图标`（● running / ○ done / ◌ cancelled）+ `name` + `group` + 运行时长 / 终态词。`status` 列**实时由 `M.status()` 求值**（D2 派生状态）——打开那一刻就是真相，无过期。
- **右侧预览**：对 `terminal` 任务显示其终端 buffer 尾部；对 `job`/`system` 显示对应日志文件尾部（复用 `_logged_jobstart` 的 log_path / build 终端 buffer）。预览缺失时显示 `(running, no log)`，不报错。
- **多动作键**（对齐 snacks.picker / overseer 肌肉记忆）：
  - `dd` → 停止选中任务（= `M.cancel`）。**单个停止不二次确认**（可恢复操作，重跑即可——合本仓「最小打扰」取向）。
  - `<cr>` → 聚焦该任务的终端/日志（build 任务跳到其 termopen 窗口；其余打开日志）。
  - `gl` → 打开完整日志文件。
  - `q` / `<esc>` → 关闭面板（不影响任何任务）。
- **空列表**：不打开空 picker，给一次性 `vim.notify("无后台任务")`（合 spec「无任务时提示」）。
- **多选**：picker 支持 `<Tab>` 多选 + `dd` 批量停（snacks 原生能力，自定义源声明 `actions` 即可）。

#### 第 3 层：即时反馈（一次性，不刷屏）

- **发起/完成/取消**复用既有 `fidget.progress` 句柄（与 `:UEPrepare`/install 一致的右下角进度），**只 start + 中段 + 收尾自然消退**，不轮询、不周期 toast（合 P5）。
- **取消后**单次 `vim.notify("已停止 <name>")`；`:TaskStopAll` 单次 `vim.notify("已停止 N 个任务")`。

### 确认策略

| 操作 | 确认 | 理由 |
|---|---|---|
| `dd` / `:TaskStop` 停单个 | **不确认** | 停后重跑即恢复，是可逆操作；确认是噪声 |
| `:TaskStopAll` 停全部 | **一次确认** `停掉 N 个任务？[y/N]`（`vim.fn.confirm`） | 批量、范围大、可能误触；一次足够 |

### 命令-意图映射

- 想**看**有什么在跑 / 停某一个 → `:Tasks`（或 `<leader>X`），可视化选。
- 已知**就一个**在跑、想直接停 → `:TaskStop`（无参，唯一 running 直接停，免选择器）。
- 知道 **id** / 脚本化 → `:TaskStop <id>`。
- **全停**（如开始新构建前清场）→ `:TaskStopAll`（带确认）。

### async_launcher 浮窗的取消键

接入 `cancel` 的浮窗（如 `:UEPrepare`）：取消键用 `<C-c>`（终端「中断」直觉）而非 `q`——`q` 维持「仅隐藏指示器」旧语义（向后兼容，引理 3a），`<C-c>` 才真正取消底层 job。浮窗底部 hint 文案据是否有 `cancel` 动态显示 `press q to dismiss` 或 `q dismiss · <C-c> cancel`。

### 不做（UX Non-Goals，避免过度设计）

- 不做常驻 task-list 侧栏/面板（overseer 风格的独立 buffer）——`:Tasks` 按需召出已够，常驻面板与 snacks 生态正交、占屏。
- 不做任务进度百分比聚合面板——单任务进度已由各自 fidget 句柄覆盖。
- 不做 statusline 点击跳转——statusline 点击在多客户端（Neovide/终端）行为不一，留简单。

---

## 行为等价性证明（Behavioral Equivalence Proof）

**命题.** 设 `J` 为某后台 job 的原始实现，`J'` 为「按 §D-接入规则」接入注册表后的实现。则对任意外部可观察行为 `B`（进程命令行、cwd、env、stdout/stderr 内容与时序、退出后副作用如通知/quickfix/状态位、UI 焦点），有 `B(J') = B(J)`。

### 接入规则（接入只允许一种编辑，别无其他）

1. **R1（登记）**：在 job 创建语句**之后**插入 `local id = pcall(task_registry.register, spec_with_existing_handle)`。`spec` 只读取 job 创建已返回的句柄（chan id / system handle）与静态元数据（name/group），不回写、不传入 job 创建参数。

**没有 R2**：派生状态架构下注册表**不在 `on_exit`/完成回调里写任何东西**（状态由 `status()` 实时查询句柄，见 D2）。接入点的退出回调因此**零改动**——这比「末尾追加一条幂等 mark_done」更强：连那一行都不存在，等价性更易证。

不允许：改命令/参数/cwd/env、改或包裹原回调的任何已有语句、在 `on_exit` 里调用任何 `task_registry.*`、改 job 创建时机或条件、为登记新增 timer 或 autocmd。

### 引理 1：R1 不改 job 行为

`jobstart`/`vim.system`/`termopen` 的行为完全由其**调用参数**决定（Neovim job-control 语义：channel 一经 `jobstart` 返回即已 spawn，后续对返回值的读取无副作用）。R1 在创建语句之后执行，且：

- 不修改任何创建参数（按规则禁止）；
- 只读句柄值（`vim.fn.jobstop`/`:kill` 不在 R1 执行，仅保存引用）；
- `register` 是纯内存表写入（`state.tasks[id]=rec`），无 vim 副作用、无 IO、无调度。

∴ 在 R1 执行点之前与之后，job 的进程状态、输出流、回调绑定均不变。又因 R1 被 `pcall` 隔离，即便 `register` 抛错，控制流也回到原路径，job 继续。**引理 1 成立。** ∎

### 引理 2：退出回调零改动 ⇒ 退出后副作用恒等

接入**不触碰** `on_exit`/完成回调（无 R2）。设原回调体为 `S`，接入后仍为 `S`（逐字节相同）。故其可观察副作用集 `E(S)` 不变。**引理 2 成立。** ∎

> 注：旧方案在此需证「末尾追加 mark_done 不改 E(S)」；新架构直接删除了这条编辑，引理 2 从「需证副作用相等」退化为「回调根本没改」，无需证明。这正是「从架构消除」相对「用规则约束」的体现。

### 引理 3：未接入路径完全不变

- async_launcher：`opts.cancel` 默认 `nil`。取消键分支 `if state.cancel then state.cancel() end` 在 `nil` 时短路，回到原「仅隐藏」语句。所有现有调用点不传 `cancel` → 取 `nil` 分支 → 与改前字节级等价。**引理 3a。**
- 短命 detach job（`xdg-open` 等）：不接入（按 Non-Goals），源码零改动。**引理 3b。**
- 新增命令 `:Tasks`/`:TaskStop*`：新符号，不覆盖、不重定义任何既有命令/键位（`<leader>X` 经核对未被占用）；纯加法，对既有命令解析无影响。**引理 3c。**

### 主定理

任一接入点 `J'` 由「`J` 的创建语句 + R1」构成，退出回调零改动。由引理 1，创建+R1 段不改 job 行为；由引理 2，退出回调段逐字节不变；其余代码路径由引理 3 不受影响。可观察行为 `B` 是「创建段行为 ∪ 输出流 ∪ 退出副作用 ∪ 未接入路径」之并，各分量均经证不变。

∴ `B(J') = B(J)`。**接入注册表对既有 job 行为等价。** ∎

### 证明的可机械检验充分条件（落到回归测试）

上述证明依赖两条**语法级不变式**，均可由测试 / review 机械核对：

1. **C-INV-1（仅在创建后追加 register）**：每个接入点的 diff 仅含「创建语句后插入一行 `register`」，**无对 `on_exit`/完成回调的任何修改**（对应 AR-T4/AR-T6）。→ diff 审查 + grep「接入文件的 on_exit 体内无 `task_registry`」。
2. **C-INV-2（register 纯内存且被隔离）**：`register`/`status`/`cancel`/`list` 实现中不写副本状态字段、`register` 不调任何 `vim.api`/`vim.fn`/`vim.notify`/IO/`vim.schedule`；接入点对 `register` 的调用被 `pcall` 包裹。→ `task_registry_spec` 断言 + grep 守护。

只要 C-INV-1..2 成立，主定理前提即满足，等价性即被保证。

---

## 异步鲁棒性：从架构消除竞态，而非用规则约束竞态

> 前一版方案曾用「先抢状态、再动句柄」「核心函数禁止 `vim.*`」「mark_done 幂等」等一串规则去*管理*一个 stored 状态机的竞态。那本质是 workaround——竞态依然存在，只是被规则压住，实现稍错即破。本节改为从架构上**让竞态无处可生**。

### 竞态的唯一根因

所有 H1–H7 类竞态，根因只有一个：**注册表存了一份状态副本（`rec.state`），它与真实世界（OS 进程 / nvim job-control）可能不一致，于是需要「同步」，而同步就有时序竞争。**

- 取消-退出竞态、chan-id 复用误杀、退出后 kill、选择器时窗——全部是「副本 vs 真相」不一致的不同表现。
- 只要**不存副本**，这些竞态在架构上不存在，无需任何不变式去守。

### 架构决策：单一写入入口 + 派生状态（D1–D5）

1. **不存状态机（D1/D2）**：`rec` 只有 `{id,name,group,kind,handle}`，**没有 `state` 字段、没有 `mark_done`、没有 transition**。状态由 `M.status(id)` 每次**实时查询句柄**得出（`jobwait(_,0)` / `handle:is_closing()`）。没有副本 ⇒ 没有「副本 vs 真相」⇒ 没有同步 ⇒ 没有同步竞态。

2. **唯一可变写入点是 `register`（D4）**：注册表里唯一写 `tasks` 表的常规路径是 `register`，它**只在主循环、由用户创建 job 时调用**，天然串行。**不存在 `on_exit → mark_done` 的回调写回**，所以根本没有「回调写 vs 命令写」这条竞态边——它被结构性删除，而非被规则压制。这是 Actor / 单一写者模型的核心：让并发的多个事件源**只通过一个串行入口**改变共享状态；这里推到极致——写入点退化为仅 `register`，其余全是读。

3. **取消即操作真相，不回写副本（D3）**：`cancel` = `jobstop`/`:kill`，事后**不写任何状态**。下一次 `status`/`list` 自然反映「已退」。「取消」与「自然退出」不再争抢一个状态字段——两者都只是让真相变成「已退」，谁先谁后结果相同（幂等来自 OS：对已死进程再 kill 是 no-op）。

4. **list 即查询，过期即纠正（D5）**：展示永远是「查询那一刻的真相」，GC 是查询副产物（裁剪已退且超界者）。无 timer、无后台同步（合 P5）。

### 每个原威胁如何被架构消解（不是被规则防住，是不存在了）

| 原威胁 | 旧方案（规则压制 / workaround） | 新架构（结构性消除） |
|---|---|---|
| H1 取消-退出竞态 | RB-INV-1/2「先抢状态」 | **无 state 字段可抢**；两者都只是让真相→已退，幂等 |
| H2 fast-event 违例 | RB-INV-3「核心禁 `vim.*`」 | **注册表不在 `on_exit` 里跑任何代码**；`status` 只在用户命令（主循环）调用，无 fast-event 路径 |
| H3 chan-id 复用误杀 | RB-INV-4 generation 计数 | `cancel(id)` 前先 `status(id)`，已退则不 kill；死记录在下次 list GC，旧 id 自然失效 |
| H4 退出后 kill 报错 | RB-INV-2 + pcall | `cancel` 前 `status` 复检 + `pcall`；对已死句柄本就是 OS no-op |
| H5 发起点重入 | RB-INV-5 | 新 spawn 取新 id；无回写 ⇒ 无悬挂副本可覆盖 |
| H6 选择器时窗 | RB-INV-6「操作时点复检」 | **本就是查询语义**：选中后 `cancel` 先 `status`，已退即提示，无副本可过期 |
| H7 终态无限累积 | RB-INV-7 上界 | `list()` 查询到「已退且超界」时裁剪；上界保留，但它现在是 GC 策略而非竞态防线 |

关键差异：旧表里每个威胁都需要一条**主动维护的不变式**（实现稍错就破）；新表里大多数威胁**不再有对应的代码路径**，剩下的（H4/H7）退化为「查询 + pcall + 裁剪」这类无时序假设的局部逻辑。

### 唯一保留的运行时依赖（且是被复用，不是被假设）

新架构把正确性**外包**给 Neovim job-control 与 libuv 既有保证，而非自己复刻：

- `jobwait(_,0)` 返回的 running/exited 是 job-control 的权威真相 → 直接用，不缓存。
- `jobstop` 对已退 channel、`uv_process_kill` 对已退 pid 是安全 no-op → 取消幂等来自这里。
- `on_exit`/`vim.system` 完成回调恰好一次 → 但我们**根本不依赖它来改状态**，所以连这条都不需要。

「外部保证的复用」优于「自建状态机 + 规则维护」：前者的正确性由 runtime 负责（我们只读），后者要靠每次改动都不破坏一串不变式。

### 落到测试（验证「竞态不存在」而非「竞态被防住」）

1. **AR-T1 状态即真相**：`register` 一个 mock job（`jobwait` 返回 -1）→ `status=running`；翻转 mock 为已退（返回 0）→ `status=done`，**无需任何 mark/通知**。
2. **AR-T2 取消后状态自然翻转**：`cancel` 调 `jobstop`（mock 记录被调）后把句柄置已退 → `status` 立即 `done`，注册表自身未写过任何状态字段。
3. **AR-T3 取消前复检**：对 mock「已退」记录 `cancel` → 先 `status` 判已退 → **不调** `jobstop`/`:kill`（mock 计数 0），不报错。
4. **AR-T4 无回调写路径**：grep 全文件，`register`/`status`/`cancel`/`list` 之外无写 `tasks[*]` 的语句；接入点的 `on_exit`/`vim.system` 回调体内**无** `task_registry.*` 写调用。
5. **AR-T5 list GC 幂等**：登记 `KEEP_DONE+5` 个并全部 mock 已退 → 连续两次 `list()` 结果稳定，终态条数 ≤ `KEEP_DONE`，running 恒在列。
6. **AR-T6 fast-event 无关性**：断言接入点 `on_exit` 体内不出现 `task_registry` 调用（结构保证，而非「禁 `vim.*`」规则）。

## Risks / Trade-offs

- [derived 状态依赖 `jobwait`/`is_closing` 在 mock 下可测] → 注册表对句柄的查询封装为一个可注入的探针函数（`probe(rec)`），测试注入 mock，生产用真实 `jobwait`/uv。这本身也是架构产物：状态查询是纯函数，输入句柄、输出真相。
- [`vim.system` 句柄存活查询] → 用 handle 的 `is_closing()`/`is_active()`；若 API 不足则以「完成回调里仅做一次 `register` 元数据补全（如记录 exit code 到 rec 的只读快照字段，不作为状态判据）」兜底——注意这仍**不是**状态副本，status 仍以句柄为准。Open Question 待实现期定。
- [接入点遗漏 → 列表不全] → 新发起点接入作为维护契约写进 `lua/utils/CLAUDE.md`。
- [async_launcher 回归] → 引理 3a + `task_registry_spec` + 跑 `utils`/`commands`/`smoke`，提交前全量（C6）。

## Migration Plan

1. 落 `task_registry.lua`（derived 状态 + 单一 `register` 写入点 + 可注入 `probe`）+ 单测（含 AR-T1..T6），独立绿。
2. async_launcher 加 `cancel`（默认 nil）。
3. 按 R1（仅创建时 `register`，**不在 on_exit 回写**）逐点接入，保存此前丢弃的句柄。
4. 注册通用命令 + 键位 + 冻结清单同步。
5. 文档 / cheatsheet / changelog。
6. 全量回归门禁。

回滚：纯侧路，删 3 命令注册 + 各接入点的 `register` 一行即可，job 本体零影响。

## Open Questions

- `vim.system` 句柄的「是否存活」最稳的查询 API（`is_active` / `is_closing` / pid 探测）在目标 Neovim 版本上的行为，实现期确认并在 `probe` 内封装。
- `:Tasks` 是否升级为 snacks.picker 自定义源以支持多动作（停止/聚焦终端/查看日志）？本期 `vim.ui.select` 满足核心诉求，富 UI 留后续。
- 取消构建是否需杀 UBT 派生 cl.exe/link.exe 进程树？本期记 Follow-up，超出范围。
