## ADDED Requirements

### Requirement: Host load awareness SHALL be continuous, cheap, and attributable

宿主资源纪律（P6 第 2 层）的全部决策都依赖负载读数，因此该读数本身 SHALL 满足下列性质。
感知层 SHALL 只回答「现在多忙、趋势如何、谁在占用」，MUST NOT 内嵌阈值或推迟/降级策略 ——
后者属于准入判定，混入感知层会使阈值散落多处并互相漂移。

**常驻**：系统 SHALL 持续维护宿主忙碌度，使任意调用方在建立首个差分间隔后都能立即获得有效
缓存读数。MUST NOT 采用「仅在被调用时才开始采样」的被动模式：差分读数需要至少两次采样，
被动模式在首次询问时必然返回未知，而那恰是最需要判定的时刻。启动后的首个差分间隔 SHALL 明确
报告为 `warming`，MUST NOT 伪装成 `idle`。

**廉价**：常驻采样的稳态开销 SHALL 可忽略并有明确上限，且 SHALL 优先使用便宜的数据来源。
昂贵来源（如需为每个逻辑核分配对象的整机查询）SHALL 低频调用。感知层 MUST NOT 通过 spawn
子进程获取负载（周期性同步子进程往返会阻塞主循环，见 K40）。一个自身消耗可观 CPU 的 CPU
感知层是自相矛盾的。

**可归属**：系统 SHALL 同时暴露宿主整体忙碌度与 Neovim 本进程的占用，使调用方能观察主循环
自身是否繁忙。`uv.getrusage()` 不包含仍在运行的 clangd 等子进程，因此剩余占用 SHALL 标记为
`unattributed`，MUST NOT 伪装成「外部进程占用」；它既可能来自 rustc，也可能来自本配置启动的
clangd。完整进程树的所有权与控制属于后续资源控制器，不得由感知层编造。

**趋势**：系统 SHALL 暴露平滑值与变化方向，使调节不被单次尖峰误导。

**诚实的状态**：`warming`（首个差分间隔）、`unknown`（平台不支持或计数器未推进）SHALL 与
`idle` 明确区分。调用方 MUST NOT 把 `warming` / `unknown` 当作空闲；系统 MUST NOT 为掩盖未知
而编造读数，也 MUST NOT 因 `unknown` 永久阻塞工作。`uv.loadavg()` MUST NOT 用作判据
（在 Windows 恒为 0，会谎报空闲）。

#### Scenario: A caller asks for load after the priming interval
- **WHEN** 某工作在感知层完成首个差分间隔后查询宿主负载，且此前无人查询过
- **THEN** 系统 SHALL 返回一个基于已有常驻采样的有效缓存读数
- **AND** 查询 MUST NOT 触发新的整机采样

#### Scenario: A caller asks during the priming interval
- **WHEN** 某工作在感知层尚未完成首个差分间隔时查询宿主负载
- **THEN** 系统 SHALL 返回 `warming`
- **AND** MUST NOT 返回 0 或伪装成 `idle`

#### Scenario: Steady-state sampling cost stays negligible
- **WHEN** 感知层常驻运行
- **THEN** 其稳态每秒开销 SHALL 低于既定上限，并由回归用例守护
- **AND** MUST NOT 通过 spawn 子进程采样

#### Scenario: Host and editor-process signals differ
- **WHEN** 宿主整体忙碌度高，而 Neovim 本进程占用很低
- **THEN** 读数 SHALL 分别暴露两者，并把差值标记为 `unattributed`
- **AND** MUST NOT 将该差值宣称为「外部进程占用」

#### Scenario: Neovim itself burns CPU
- **WHEN** 宿主整体忙碌度高，且 Neovim 本进程占用同样可观
- **THEN** 读数 SHALL 使调用方可观察到两个独立信号
- **AND** 感知层 MUST NOT 自行执行降级动作

#### Scenario: A single spike must not flip decisions
- **WHEN** 宿主负载出现单次短时尖峰后立即回落
- **THEN** 平滑值 SHALL 抑制该尖峰的影响
- **AND** 趋势 SHALL 反映方向，使调节不在尖峰上反复启停

#### Scenario: Counters do not advance or the platform is unsupported
- **WHEN** 负载计数器未推进、发生回退（休眠/恢复），或平台不提供所需数据
- **THEN** 系统 SHALL 报告 `unknown`
- **AND** MUST NOT 返回 0 或任何编造的数值

#### Scenario: Awareness layer holds no policy
- **WHEN** 用例检查感知层实现
- **THEN** 其中 SHALL NOT 出现高/低水位阈值、推迟上限或降级动作
- **AND** 这些 SHALL 只存在于准入判定层
