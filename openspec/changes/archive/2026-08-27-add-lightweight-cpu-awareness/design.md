## Context

见 `proposal.md` 的 Why。现有 `utils.cpu_load.busy()` 是按需采样：首次查询只能建立基线，
因此在重活到期时可能返回 `nil`；真实整机查询还会为每个逻辑核分配一个 table。

实现受以下约束塑形：

- P6 要求感知层自身不得成为主循环负担。
- K40 禁止周期性 spawn 子进程。
- Windows 的 `uv.loadavg()` 恒为 0，不能使用。
- `uv.getrusage()` 只统计当前 Neovim 进程，**不包含仍在运行的 clangd 等子进程**；
  libuv 没有可移植的进程树 CPU 接口，不能虚构完整归属。
- 感知层是决策输入，不持有准入水位、推迟上限或进程降级动作。

## Goals / Non-Goals

**Goals:**

- UI 会话中常驻维护整机 CPU 与 Neovim 本进程 CPU 的缓存读数。
- 查询为 O(1) 缓存读取，不在工作到期时临时建立基线。
- 输出原始值、EMA、趋势、采样年龄以及 `warming` / `ready` / `unknown` / `stopped` 状态。
- 所有差分、平滑和趋势计算保持纯函数，可用合成计数器验证。

**Non-Goals:**

- 不测量或控制完整进程树；子进程所有权由后续资源控制器通过其持有的进程句柄管理。
- 不在此模块决定何时推迟、降低优先级或恢复。
- 不保证宿主总体 CPU 低于任何阈值。
- 不启动真实 clangd、构建或外部负载验证。

## Decisions

### 1. 一个 250ms 计时器，分层采样

计时器每 250ms 读取一次 `uv.getrusage()`；每 4 tick（1s）读取一次 `uv.cpu_info()`。
前者实测约 0.0019ms，后者约 0.515ms，因此稳态整机查询成本约 0.515ms/s，约为单核的
0.052%，同时避免多个计时器互相漂移。

替代方案：每 200ms 调用 `cpu_info()`。拒绝，因为会制造约 2.5ms/s 的固定成本与每秒 120 个
core table 分配，感知层自身成为不必要的 GC 来源。

### 2. UIEnter 启动，headless 不常驻

在现有 `init.lua` 的 `UIEnter` 一次性回调中调用 `cpu_load.setup()`，与 `stall_probe` 同层。
`setup()` 立即取得首个基线，然后启动计时器；不等待第二个样本、不阻塞启动。
headless 回归不触发 `UIEnter`，因此不会留下常驻计时器。

替代方案：模块加载时启动。拒绝，因为测试、脚本和无 UI Neovim 不需要常驻监控。

### 3. 查询只读缓存

`reading()` 返回缓存快照；兼容 API `busy()` 只返回 `reading().host_pct`。二者都不调用
`cpu_info()` 或 `getrusage()`。这样工作到期时的查询恒为 O(1)，也不会由多个调用者改变采样节奏。

启动后的首个整机间隔内状态为 `warming`，这是物理上不可避免的：累计计数器必须有两个时间点。
准入层可短暂推迟 `warming`，但 `unknown`（平台不支持）仍须允许工作，避免永久停摆。

### 4. 归属输出保持诚实

感知层输出：

- `host_pct`：整机 EMA；
- `editor_pct`：Neovim 本进程占整机容量的 EMA；
- `editor_core_pct`：Neovim 本进程相对单核的 EMA；
- `unattributed_pct = max(host_pct - editor_pct, 0)`。

`unattributed_pct` 的名字刻意不写 `external`：其中既可能是 rustc，也可能是本配置启动的 clangd。
后续控制器知道自己持有哪些子进程句柄，感知层不知道，二者不得混淆。

替代方案：把 `getrusage()` 宣称为“本进程及其子进程”。拒绝，因为该断言在 Windows 与 Unix
对仍在运行的子进程都不成立。

### 5. 信号处理与策略分离

EMA 权重与趋势差分属于信号处理；高低水位、推迟次数、优先级动作属于策略。
`cpu_load.lua` 只保留前者。`ue.index._admission` 继续持有后者，并接收完整 reading；
现阶段准入行为仍以 `host_pct` 为主，附带其他字段用于诊断，避免在此 change 偷渡控制策略。

## Risks / Trade-offs

- [启动后约 1s 为 `warming`] → 首次基线在 `UIEnter` 立即取得；准入层把 warming 与 unsupported
  分开，前者可短暂让路，后者不会永久阻塞。
- [`cpu_info()` 在高核数机器分配更多对象] → 固定为 1Hz，并暴露样本数与平均 tick 开销供诊断。
- [计时器被主循环卡顿延迟] → 计数器差分使用真实 `hrtime`，不会把延迟误当 CPU；读数带 age，
  后续策略可识别陈旧数据。
- [Neovim 本进程 CPU 不能代表完整工作树] → API 与文档明确命名为 `editor` / `unattributed`，
  禁止推导“外部进程占用”。

## Migration Plan

1. 保留 `snapshot()`、`busy_from_samples()`、`busy()`、`reset()`、`status()` 兼容入口。
2. 新增常驻 lifecycle、process 差分、reading 与纯信号函数。
3. 将 index 准入从数字输入迁移为 reading 输入，同时继续接受数字以兼容现有测试/调用者。
4. 在 `UIEnter` 启动；出现问题可删除该 setup 调用，准入层会按 `stopped/unknown` 维持旧的放行行为。
