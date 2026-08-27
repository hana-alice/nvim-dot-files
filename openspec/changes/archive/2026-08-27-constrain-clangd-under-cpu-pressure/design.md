## Context

见 `proposal.md` 的 Why。`add-lightweight-cpu-awareness` 已提供 1Hz host cache；
`enforce-host-resource-discipline` 已把双水位策略提升为 `utils.host_admission`。

Neovim 0.11 的 `vim.lsp.rpc.start()` 返回 `PublicClient`，只暴露 request/notify/is_closing/terminate；
底层 `vim.SystemObj.pid` 被 private transport 隐藏。通过 `debug.getupvalue` 挖 private transport 虽能取到，
但属于脆弱的上游内部依赖，拒绝采用。

## Goals / Non-Goals

**Goals:**

- 只管理当前 Neovim 直接启动的 clangd PID。
- host 高水位或本配置前台任务活动时切到 Windows `BELOW_NORMAL_PRIORITY_CLASS`；回落到低水位后
  恢复 `NORMAL_PRIORITY_CLASS`。
- 多 client/restart 自动发现、去重、淘汰已死 PID。
- 无 PID、平台无 capability、原生调用失败均 fail-open 并记录，不影响 LSP。

**Non-Goals:**

- 不 kill/suspend clangd，不修改 ProcessorAffinity。
- 不枚举或调整非当前 Neovim 子进程（包括其他 editor 的 clangd、rustc）。
- 不承诺宿主 CPU 数值上限。
- 不通过 PowerShell/WMI 周期轮询；那会让控制器本身成为额外进程负担。

## Decisions

### 1. Windows driver 用原生 Toolhelp32 + PriorityClass

在 `utils.platform.windows` 增加宿主专属 capability：

- `child_processes(parent_pid, executable_name)`：`CreateToolhelp32Snapshot` + `Process32First/NextW`；
- `process_exists(pid)`；
- `set_process_priority(pid, "normal"|"low")`：`OpenProcess` + `SetPriorityClass`，其中 low 映射
  `BELOW_NORMAL_PRIORITY_CLASS`。

这些函数通过 LuaJIT FFI 直接调用 kernel32，不 spawn PowerShell。其他 driver 不添加假实现；调用方以
method presence 判断 unsupported，符合 platform capability 规则。

### 2. cmd factory 启动后枚举直接子进程

`vim.lsp.rpc.start` 同步完成底层 spawn 后，cmd factory 调用 controller 的 0/100/500ms 有界异步发现。
枚举只接受 `th32ParentProcessID == vim.fn.getpid()` 且 exe 名匹配的进程，并打开一个绑定该 process
object 的原生 HANDLE。后续 1Hz reconcile 只做 `GetExitCodeProcess(HANDLE)`，不重复 Toolhelp 全机快照；
HANDLE 不会因数字 PID reuse 指向新进程。

替代方案：读取 RPC private closure。拒绝，因为 Neovim 升级可无提示改变 private layout。

### 3. controller 订阅已有 CPU sampler，不创建第二个监控 timer

`utils.cpu_load` 增加 policy-free `subscribe/unsubscribe`；仅在既有 1Hz host sample 更新后 schedule
listener。`clangd_resource_controller` 订阅该流并对已登记 PID reconcile，避免再造轮询器。

### 4. priority 判定复用通用 admission

纯函数 `desired_priority(load, current, opts)` 调 `host_admission.admit(load, 0, opts)`：

- high / foreground active → `low`；
- low / unknown / disabled → `normal`；
- hysteresis band → 保持 current。

controller 不包含 85/70 数字。`warming` 保守为 low；平台真正 unknown 恢复 normal。

### 5. 失败永不影响 LSP

注册、枚举、SetPriorityClass 全部 pcall/fail-open。失败按 reason 去重写 `utils.log`，不 notify；
RPC public client 原样返回。每次 reconcile 先 `process_exists`，死亡 PID 直接移除，不向复用 PID 写入。

## Risks / Trade-offs

- [Toolhelp snapshot 中 PID 在 OpenProcess 前死亡] → 该候选无法取得 HANDLE，跳过并在有界重试后记录；
  一旦取得 HANDLE，process identity 不受数字 PID reuse 影响，每轮只检查 `STILL_ACTIVE`。
- [clangd 通过 wrapper 间接启动] → 当前 resolved command 是 clangd.exe 直启；若未来增加 wrapper，发现会
  fail-open 并记录，不能猜后代进程。
- [BELOW_NORMAL 使 gd 在高压时稍慢] → 高压时机器可用性优先；回落经低水位立即恢复 NORMAL。
- [1Hz 反应最多延迟约一秒] → 与 awareness 采样频率一致，不增加额外 timer；比持续系统卡死的代价小。

## Migration Plan

1. 增加 Windows 原生 capability 与纯注入测试。
2. 增加 cpu_load subscriber 与 controller。
3. cmd factory 启动后调用 discover；无 capability 时保持原行为。
4. 回滚只需移除 cmd factory discover，clangd 启动协议不变。
