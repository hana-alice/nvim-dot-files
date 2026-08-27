## Why

**clangd 本体从未受任何动态资源约束。** 用户报告"clangd 时不时把我电脑卡死，复发了"。

### 我上一轮的修复没有覆盖 clangd

`throttle-background-work-under-cpu-pressure` 实现了宿主 CPU 准入控制，但它挂在
`lua/ue/index/_schedule.lua` 上，**只拦 controlled index 构建（python 子进程）**。
核对结果：`lua/ue.lua` 与 `lua/plugins/ue.lua` 里**没有任何** `admit_background_phase` /
`cpu_load` 调用。clangd 完全在节流之外。

所以"复发"是准确的描述 —— 对 clangd 而言，那个功能从来没生效过。

### clangd 侧现有的约束全是静态的

```
-j=20                                  启动时一次性算出（24 核 → 83% 的核）
--background-index-priority=background clangd --help 明说 "effect is OS-specific"
--pch-storage=memory                   每个在飞 preamble 1.5–3 GB
```

三条都是**启动参数**，进程活着期间不再调整。而 `-j` 的问题在
`throttle-background-work-under-cpu-pressure` 里已论证过：静态预算假设"除了我们和 UI 没别人"，
但用户机器上同时有 rustc、多个 zellij、Chrome、AppControl（实测 top CPU 进程无一属于我们）。
我们"保留"的 4 核在别人也满载时并不存在。

`--background-index-priority=background` 值得单独说明：它是 clangd 唯一的自我限速手段，但
**其效果按 OS 而定**，且我们从未在 Windows 上验证过它真的降低了线程优先级。把未经验证的旗标
当作已有防线，是这次"以为修好了其实没修"的一部分原因。

### 缺的那一层

我们从未对 clangd 进程做过**任何** OS 级约束：全仓 `rg "PriorityClass|ProcessorAffinity"`
零命中。而 Windows 两个手段都可用（实测）：`PriorityClass` 可写、`ProcessorAffinity` 受支持。

这与 index 构建的处境不同：index 构建是**我们启动的、可推迟的批任务**，所以"高负载时不启动"
是正确策略。clangd 是**长驻的交互式服务**，不能推迟、更不能杀（杀掉等于丢失 preamble，
下一次导航要重付分钟级代价）。它需要的是**降级而非暂停**。

**Why now**：用户已多轮受此影响；而且我上一轮宣称"CPU 节流已实测生效"，那个结论对 index
构建成立、对 clangd 不成立 —— 这个覆盖缺口必须显式修掉，而不是让用户继续踩。

## What Changes

- **clangd 进程接受 OS 级资源约束**：clangd 启动后 SHALL 可被施加降优先级（Windows
  `PriorityClass`，其他平台等价手段），使其在宿主繁忙时让路于 UI 与前台工具链。
- **约束是动态的，且只降不升到危险区**：宿主 CPU 高于高水位时 SHALL 降级；回落后 SHALL
  恢复到正常优先级（双水位滞回，复用既有 `utils.cpu_load` 与通用
  `utils.host_admission` 的判据，不另写一套）。
- **MUST NOT 杀死或暂停 clangd**：它是交互式服务，终止会丢失已建 preamble 并使下一次导航
  重付分钟级代价。约束仅限优先级/亲和性。
- **不得伪装成已有防线**：`--background-index-priority` 的实际效果 SHALL 被记录为
  未在本平台验证；本 change 的 OS 级约束 SHALL 独立于它成立。
- **诚实边界**：系统 MUST NOT 声称能保证宿主 CPU 低于阈值。clangd 的工作量由用户的编辑行为与
  索引需求决定；我们只能降低它抢占 UI 的能力。

## Impact

- Specs: `cpp-semantic-index-coverage`（clangd 进程的资源约束义务）
- Code: `lua/plugins/ue.lua`（clangd `cmd` 工厂处可拿到进程句柄）或 `lua/ue.lua`
  `clangd_cmd` 周边；判定复用 `lua/utils/cpu_load.lua` + `lua/ue/index/_admission.lua`
- 回归: `cpu_admission` `ue_api` `index_delivery` `stability`；提交前全量
- 风险：
  - 降优先级过度会让 `gd` 变慢 —— 必须只在高负载时降、回落即恢复。
  - `ProcessorAffinity` 硬绑核比降优先级更激进（可能让 clangd 在空闲时也用不满机器），
    **优先用 PriorityClass**，affinity 仅作为后续可选项。
  - Neovim RPC public client 不暴露 pid：Windows 通过 Toolhelp32 只枚举当前 nvim 的 direct child；
    拿不到时 SHALL 跳过约束并记录，MUST NOT 报错或阻塞启动。
- **验证纪律（沿用用户约束）**：agent MUST NOT 自行启动真实 clangd 验证（前次如此操作导致
  用户机器卡死）。判定逻辑用注入测试；真实效果由用户在自身会话观察。
