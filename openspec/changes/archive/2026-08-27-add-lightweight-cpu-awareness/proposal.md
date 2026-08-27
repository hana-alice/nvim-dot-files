## Why

用户要求的是**动态平衡**，而动态平衡有前置条件：

> 这个是要你做动态平衡调整的 也就是说首先你要有一个 lightweight cpu usage awareness 的东西

现有 `lua/utils/cpu_load.lua` 不满足这个前置条件，实测有三个结构性缺陷。

### 缺陷 1：它是被动的，需要时拿不到读数（最严重）

`cpu_load.busy()` 只在**被调用时**才采样，而差分需要两次采样。实测冷启动序列：

```
reset 后立即 busy()      -> nil     （无基线）
300ms 后 busy()          -> nil     （仍需第二次采样）
再 300ms busy()          -> 19.7%   （第三次调用才有读数）
```

而准入判定对 `nil` 的处理是（`_admission.lua:61`）：

```lua
if type(busy) ~= "number" then
  return true, "load-unknown"   -- 放行
end
```

**后果完全反了**：如果只在"要启动重活时"才问负载，那一刻恰好拿到 `nil` → 判为 unknown → **放行**。
最需要节流的那一刻反而不节流。`load-unknown → 放行` 这条规则本身是对的（不能因测不出而永久停摆），
错的是**让感知层在关键时刻处于冷态**。

动态平衡还需要**趋势**（在升还是在降），单点采样天然给不出。

### 缺陷 2：采样开销不够"lightweight"

实测（本机 24 核）：

| 操作 | 开销 | 备注 |
|---|---|---|
| `uv.cpu_info()` | **0.698 ms** | 每次分配 24 个 core table → GC 压力 |
| `cpu_load.snapshot()` | **0.515 ms** | 同上 |
| `cpu_load.busy()`（命中节流） | 0.00007 ms | 只是返回缓存值 |
| `uv.getrusage()` | **0.0019 ms** | **比 cpu_info 便宜 270 倍** |

`busy()` 看着便宜，只因为它多数时候**没真采样**。真采样 0.515ms 若要常驻高频运行就不可接受 ——
一个自身消耗可观 CPU 的 CPU 感知层是自相矛盾的（K40 的同类教训）。

### 缺陷 3：缺少本进程占用信号，且不能虚构完整归属

`cpu_info` 只给整机忙碌度，`getrusage` 只给 Neovim 本进程。两者必须同时暴露，调用方才能知道
「整机很忙时，Neovim 主循环自身是否也在烧 CPU」。但这里有一条必须诚实的边界：
`uv.getrusage()` **不包含仍在运行的 clangd 等子进程**，所以 `host 高 + editor 低` 只能叫
`unattributed`，不能武断地叫「外部进程占用」；它既可能是 rustc，也可能是我们启动的 clangd。

后续动态控制器通过自己持有的进程句柄管理子进程；感知层只提供整机与 Neovim 本进程两个可验证信号，
不得把不可测的完整进程树占用编造成读数。

**Why now**：K54 已记录"只覆盖 index、clangd 裸奔"的结构性缺口，`enforce-host-resource-discipline`
定下了全仓纪律。但那条纪律的**判据来源**（感知层）目前是被动、偏贵且信息不全的 ——
不先修好它，全仓接入只会把同一个盲区复制到十几处。

## What Changes

- **感知层改为常驻轻量采样**：由一个低频计时器持续维护宿主忙碌度，使任意调用方在**任何时刻**
  都能立即拿到有效读数，MUST NOT 出现"需要时才冷启动、拿到 nil"的情形。
- **采样开销必须可忽略且有明确预算**：常驻采样 SHALL 优先使用便宜来源（本进程 `getrusage`
  实测 0.0019ms），整机 `cpu_info`（0.515ms，分配 N 个 table）SHALL 低频调用；
  感知层自身的稳态开销 SHALL 有上限并被回归守护。MUST NOT spawn 子进程（K40）。
- **同时暴露整机与 Neovim 本进程占用**：调用方 SHALL 能观察主循环自身是否繁忙；
  未归属部分 SHALL 明确标为 `unattributed`，MUST NOT 伪装成外部进程占用。
- **暴露趋势而非仅瞬时值**：SHALL 提供平滑值与变化方向，使动态调节不被单次尖峰误导
  （rustc 的突发满核不应立刻触发降级）。
- **冷态与不可用必须可区分**：启动后首个差分间隔为 `warming`，平台不支持为 `unknown`，二者与
  `idle`（确实空闲）SHALL 是不同状态；调用方 MUST NOT 把它们当作空闲，同时 MUST NOT 因
  `unknown` 永久阻塞工作。
- **感知层与决策层分离**：感知层只回答"现在多忙、趋势如何、谁在占"，MUST NOT 内嵌任何阈值或
  推迟/降级策略（那属于准入判定），以免阈值散落多处。

## Impact

- Specs: `editor-behavior-regression`（宿主资源纪律的判据来源）
- Code: `lua/utils/cpu_load.lua`（改为常驻采样 + 自身占用 + 趋势）；
  `lua/ue/index/_admission.lua`（消费新读数，阈值仍留在决策层）；
  感知层启动位置需遵守启动顺序约束（C3），并在 headless 下不常驻
- 回归: `cpu_admission` `ui_responsiveness` `stability` `utils`；提交前全量
- 风险：
  - 常驻计时器本身违反 P5/P6 的可能：**必须**低频、fast-event 安全、只做算术，
    且回归用例守护其稳态开销上限。
  - 平台差异：`cpu_info` 的 times 字段在部分平台可能不推进 → 必须保持 `unknown` 而非编造读数。
  - `uv.loadavg()` 在 Windows 恒为 `{0,0,0}`，MUST NOT 用作判据（已有约束，需继续守护）。
- **不在范围**：阈值与推迟/降级策略（属 `enforce-host-resource-discipline` 与
  `constrain-clangd-under-cpu-pressure`）；外部进程的资源操作（永久排除）。
- **验证纪律**：agent MUST NOT 自行启动真实 clangd / 真实构建验证（前次致用户机器卡死）。
  感知层用注入时钟与合成负载测；真实效果由用户在自身会话观察。
