## Why

**索引/构建类后台工作没有任何负载感知：它按静态预算启动，然后无条件跑到底。**

用户报告：平时机器正常，一开 Neovide，**一分钟内 clangd + rustc 就把 CPU 挤满**。
两个事实叠加造成这个结果：

1. **我们的预算是静态的**。`ue.clangd_jobs` 只按 RAM 与核数一次性算出 `-j`（本机 24 核 →
   `-j=20`，保留 4 核给 UI）。它假设"除了我们和 UI 之外没别人"。
2. **实际上有别人**。用户机器上同时跑着 `rustc`、多个 `zellij`、Chrome、AppControl 等
   （实测 top CPU 进程里没有一个是我们的）。`rustc` 尤其是突发型满核负载。

于是：我们预留的 4 核在别人也满载时**根本不存在**。静态预算在共享机器上是错的前提 ——
它只能防住"我们自己占满"，防不住"我们在别人已经占满时还照常加压"。

### 现有机制为何不够

- `UI_RESERVED_CORES`（`lua/ue/clangd_jobs.lua`）是**启动时**的一次性决策，进程活着期间不再调整。
- `CORE_RT.ue_build_running()` 已实现 build ⇄ prepare 互斥（K51），但那是**我们内部**两个子系统
  之间的互斥，对外部进程（rustc/其他编译）完全无感。
- 索引阶段调度（`lua/ue/index/_schedule.lua`）只看时间（deadline），不看当前负载。

### 可用的测量手段（已实测）

`vim.uv.cpu_info()` 返回每核累计 tick（user/nice/sys/idle/irq），两次采样差分即得**宿主整体**
CPU 使用率，**不需要 spawn 任何子进程**（这点关键：K40 的教训是周期性探测绝不能同步 spawn）。
本机实测：200ms 采样 11.6%、500ms 22.6%、1000ms 18.1%，采样自身成本可忽略。

注意 `uv.loadavg()` 在 Windows 恒为 `{0,0,0}`，不可用作判据。

**Why now**：用户明确要求"CPU 使用率 > 85% 就要暂停一部分工作，要有动态调节"。这也是 P6
（不阻塞 UI）的自然延伸 —— 主循环没被我们的 Lua 阻塞，但宿主被挤满时编辑器同样卡，
而我们本可以让路。

## What Changes

- **新增宿主 CPU 采样器**（`lua/utils/cpu_load.lua`）：基于 `uv.cpu_info()` 差分，
  提供平滑后的宿主 busy%。MUST NOT spawn 子进程（K40）；MUST NOT 在 fast-event 里做
  非法调用；采样开销必须可忽略。
- **后台重活接入准入判定（admission control）**：controlled index 构建在**启动前**检查宿主负载；
  超过高水位（默认 85%）时 SHALL 推迟启动而非加压，并以可观测方式说明原因。
- **动态调节而非一刀切**：
  - 高于高水位 → 推迟启动；已在跑的构建**不杀**（避免白烧已完成的工作），但不再启动新阶段。
  - 回落到低水位以下（默认 70%，带滞回避免抖动）→ 恢复启动。
  - 推迟 SHALL 有上限：不得因宿主长期繁忙而无限饿死交付（与
    `deliver-semantic-index-from-prepare` 的反饿死契约一致）。
- **用户可见 + 可配置**：推迟原因经既有进度/日志通道可见（P5：不刷屏）；
  高/低水位与开关走 `ue.config`，`UE_*` 环境变量可覆盖。
- **诚实边界**：我们只能控制**自己**启动的工作。MUST NOT 尝试挂起/降级外部进程
  （rustc 等），也 MUST NOT 声称能保证宿主总体 CPU 低于阈值 —— 只能保证"我们不在高负载时
  主动加压"。

## Impact

- Specs: `cpp-semantic-index-coverage`（后台索引的负载准入与推迟语义）
- Code: 新增 `lua/utils/cpu_load.lua`；`lua/ue/index/_schedule.lua`（准入检查与重排）；
  `lua/ue/config.lua`（阈值 schema）
- 回归: `index_generation` `index_delivery` `cpp_semantic_index` `ue_config` `stability` `utils`；
  提交前全量
- **验证纪律（沿用用户约束）**：
  - agent MUST NOT 启动真实 clangd / 触发真实索引构建来验证（上轮致机器卡死）。
  - 负载判定为纯函数 + 注入采样器，headless 可测；真实端到端由用户在自身会话观察。
- 风险：
  - 阈值过低会让交付被无谓推迟 → 必须有推迟上限与滞回。
  - `cpu_info()` 差分在极短采样窗口噪声大 → 需要最小采样间隔与平滑。
  - 门禁：`_schedule.lua` 当前 151/800、`ue.lua` 10562（ratchet）—— 不得抬高。
