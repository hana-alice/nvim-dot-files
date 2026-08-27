## Why

**「不能卡」的完整含义是「不能让这台机器卡」，而不只是「不能阻塞 Neovim 的主循环」。**

用户的原话把这一点说透了：

> 不仅仅是 clangd 整个 editor 都应该遵循此原则 而且是首要原则：这也和之前说的"丝滑"是
> 补充条款 —— cpu 占满了整个电脑卡了怎么丝滑得起来

这是对既有 P6 的**补全**，也纠正了我先前把范围理解得太窄的错误。

### 我先前的理解错在哪

P6 现有表述是「不阻塞主线程 …… 多秒等待可接受，但必须 async」。我据此做的工作
（`ui_responsiveness`、`stall_probe`、`cpu_load` + index 准入）都在优化**Neovim 进程内**的
调度延迟。但 P6 的字面要求可以在**机器已经不可用**时依然满足：主循环空转得很顺，
而 24 核被我们自己 spawn 的子进程占满，编辑器一样卡。

真实证据（AppControl 的 `app_sysmon.db`，`binary_id=258` = `C:\Program Files\LLVM\bin\clangd.exe`）：

```
14:34–14:54  ████████████████████████████
16:45–16:55  ██████████████████████████████
17:56–18:46  ██████████████████████████████   ← 持续 50 分钟满负荷
```

**17:56–18:46 那段发生在我全部 CPU 相关修改（16:03–16:05）之后。** 用户说"复发"是准确的。

### 覆盖缺口是结构性的，不是漏了一处

核对结果：

```
rg -l "admit_background_phase"  →  只有 lua/ue/index/_admission.lua 与 _schedule.lua
rg -c "vim.system|jobstart|vim.fn.system" lua/  →  ue.lua 24 处、dap/android 16 处、
                                                  cdb/pipeline 10、index/_build 4、
                                                  task_registry 4、dap 3 …
```

**准入控制只覆盖 1 条路径，其余全部裸奔。** 而且 spawn 点分散在十几个文件里，没有统一收口：
`target_tasks.run`、`task_registry.register`、`_logged_jobstart`、裸 `vim.system` 并存。
所以这不是"再补几处调用"能解决的，缺的是**一条全仓适用的资源纪律 + 一个可复用的判据**。

同时有三类负载**根本不在**现有机制视野内：

| 负载 | 现状 | 为何管不到 |
|---|---|---|
| clangd 本体 | 事发时只有启动时静态 `-j=20`（24 核的 83%；工作区已先降为 12） | 长驻服务，非我们调度；`--background-index-priority` 按 clangd 自己文档为 OS-specific，本平台未验证 |
| UE build / UBT | 无约束 | 用户显式发起，但会与索引/编辑争核 |
| Neovide 渲染 | `refresh_rate_idle=30` | 前台渲染本身耗 CPU/GPU |

外加一类**不是我们的**：rustc、其他编译器、Chrome、AppControl 自身。这些必须诚实排除在契约外。

### 为什么必须提到「首要原则」

用户把它定为首要原则是对的：**其他所有优化都以机器可用为前提**。索引再快、`gd` 再准，
如果代价是 50 分钟不能用电脑，那是净损失。当资源与功能冲突时，**资源让路优先于功能尽快完成**。

## What Changes

- **把「宿主资源纪律」提升为仓库级约束**：不只是不阻塞主循环，还 SHALL NOT 让本配置启动的
  工作把宿主 CPU 占满到编辑器不可用。该约束适用于**所有** agent 启动的重活，不限于索引。
- **提供全仓可复用的负载判据**：把现有 `ue.index._admission` 的双水位滞回判定提升为通用
  工具（不再绑在 index 子系统上），使任何 spawn 点都能用同一套阈值，MUST NOT 各写一套。
- **按负载类型采取正确策略**（不能一刀切）：
  - **可推迟的批任务**（controlled index、csearch/gtags 重建、CDB pipeline）→ 高负载时
    推迟启动（已在 index 实现，SHALL 扩展到同类任务）。
  - **长驻交互服务**（clangd）→ MUST NOT kill/suspend；SHALL 用可逆的 OS 级降级
    （优先级/亲和性）+ 更保守的启动并发度。
  - **用户显式发起的前台任务**（UEBuild / 安装 / 部署）→ SHALL NOT 被自动推迟或降级
    （用户在等它），但 SHALL 与后台批任务互斥（K51 已有先例）。
- **并发预算必须为宿主留出余量**：`-j` 类参数 SHALL 同时受 RAM 与 CPU 约束，且 SHALL 保守
  于「核数 − UI 预留」；`-j=20/24` 这类 83% 的默认值不可接受。
- **诚实边界**：系统 MUST NOT 声称能保证宿主 CPU 低于任何阈值，MUST NOT 操作非自身启动的
  进程（rustc 等）。契约仅为：**我们自己不在宿主已饱和时继续加压，且在饱和时主动让路。**

## Impact

- Specs: `editor-behavior-regression`（主循环余量 requirement 扩展为宿主资源纪律）、
  `cpp-semantic-index-coverage`（clangd 进程约束，与
  `constrain-clangd-under-cpu-pressure` 协同）
- Docs: `docs/CONSTRAINTS.md` P6 需扩写为「不得阻塞主循环 **且** 不得占满宿主」；
  `README.md` Conventions 第 2 条同步
- Code: `lua/utils/cpu_load.lua`（已有）、新的通用准入模块、
  `lua/ue/clangd_jobs.lua`（更保守预算）、`lua/plugins/ue.lua`（clangd 进程约束）、
  各 spawn 点接入
- 回归: `cpu_admission` `ui_responsiveness` `index_delivery` `ue_api` `ue_cdb`
  `stability` `structure`；提交前全量
- 风险：
  - 过度节流会让索引/构建变慢到无法接受 → 必须有推迟上限与滞回，且用户显式发起的任务不受抑。
  - 分散的 spawn 点逐一接入有遗漏风险 → 需要一条回归用例扫描「新增 spawn 未接入准入」。
- **验证纪律**：agent MUST NOT 自行启动真实 clangd / 真实构建来验证（前次如此操作导致用户
  机器卡死，且未换回有效信息）。判定逻辑用注入测试；真实效果由用户在自身会话观察。
