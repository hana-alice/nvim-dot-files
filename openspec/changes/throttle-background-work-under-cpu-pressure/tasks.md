## 1. 宿主 CPU 采样器（utils/cpu_load.lua）

- [x] 1.1 基于 `uv.cpu_info()` 差分算宿主 busy%；**禁止 spawn 子进程**（K40）。
- [x] 1.2 纯函数 `busy_from_samples(prev, cur)`：两次 tick 快照 → busy%（headless 可测）。
- [x] 1.3 最小采样间隔 + 平滑（EMA 或多点），避免极短窗口噪声；采样不可用时返回 nil。
- [x] 1.4 `uv.loadavg()` 在 Windows 恒为 0，MUST NOT 用作判据（注释写明）。
- [x] 1.5 开销实测记录（本机 200/500/1000ms 采样均可忽略）。

## 2. 准入判定（纯函数，滞回 + 推迟上限）

- [x] 2.1 `admit(busy, state, opts)` → `allow` / `defer`：
      busy > high 且未超推迟上限 → defer；busy < low → allow；中间带维持上一状态（滞回）。
- [x] 2.2 busy 为 nil（不可测）→ allow（不得因无法测量而阻塞交付）。
- [x] 2.3 推迟上限：连续推迟超过上限后 → allow（不得被外部负载无限饿死）。
- [x] 2.4 关闭开关 → 恒 allow，且不做采样。

## 3. 接入索引调度

- [x] 3.1 `_schedule.lua` 在 deadline 到达、启动 `build_phase_async` 前做准入判定。
- [x] 3.2 defer 时按短间隔重排（不得丢失该阶段；与 protect 反饿死机制兼容）。
- [x] 3.3 已在跑的构建**不杀**；仅抑制新阶段启动。
- [x] 3.4 defer 原因可观测（进度 message + 日志），遵守 P5（不刷屏）。

## 4. 配置

- [x] 4.1 `ue.config` 加入 `index.cpu_high_pct` / `index.cpu_low_pct` /
      `index.cpu_admission`（开关）/ `index.cpu_defer_max`。
- [x] 4.2 默认：high=85（用户指定）、low=70、开启、推迟上限有限。
- [x] 4.3 环境变量覆盖（与 `UE_CLANGD_JOBS` 风格一致）。

## 5. 回归

- [x] 5.1 用例：高负载→defer；回落→allow；滞回中间带不抖动；nil→allow；
      超推迟上限→allow；关闭→恒 allow 且不采样。
- [x] 5.2 用例：defer 不得丢阶段（重排后仍会启动）。
- [x] 5.3 分范围 `index_generation` `index_delivery` `cpp_semantic_index` `ue_config`
      `stability` `utils`；提交前全量。
- [x] 5.4 **agent MUST NOT 启动真实 clangd / 索引构建验证**；用注入采样器。

## 6. 收尾

- [x] 6.1 门禁：`ue.lua` ≤10562；`_schedule.lua`/新文件 ≤800。
- [ ] 6.2 changelog + spec 一致性处置。
- [x] 6.3 明确记录边界：只抑制我们自己的工作，不动 rustc 等外部进程。

## 7. 实测记录（真实宿主，未启动 clangd）

- [x] 7.1 采样开销可忽略：200/500/1000ms 采样均无可测主循环影响。
- [x] 7.2 端到端负载响应（`tools`-free 受控脚本，22 个自限 8s worker，跑完自动退出）：
      idle **42% → ALLOW**（below-low-watermark）→ 加载 **100% → DEFER**
      （above-high-watermark）→ 撤载 **28% → ALLOW**。滞回与恢复均符合契约。
- [x] 7.3 验证后宿主回到 19% 空闲，无遗留 worker（残留 powershell 为本次之前既存进程，
      CPU≈0）。**全程未启动 clangd 或索引构建**（遵守上一轮教训）。
