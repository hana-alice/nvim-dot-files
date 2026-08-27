# hana-alice/nvim 1.8.0 — Minor Release

> Version: 1.8.0
> Repo:    https://github.com/hana-alice/nvim-dot-files
> Platform: Windows 11 + Neovide GUI (primary); macOS host for Mac/iOS targets
> Date:    2026-08-27
> Type:    Minor release (host resource discipline, lightweight CPU awareness, semantic-index delivery)

---

## One-line summary

This release makes host responsiveness a first-class runtime contract: one lightweight continuous
CPU-awareness layer feeds a shared admission policy, deferrable batch work yields under pressure,
explicit foreground work starts immediately while suppressing new background load, and only clangd
processes proven to belong to this Neovim receive reversible Windows priority changes. It also makes
`UEPrepare` own semantic-index delivery and failure visibility, and converges equivalent compiler
contexts before showing a translation-unit picker.

## Release gate

- Full regression: `nvim --headless -l tests/run.lua` → **1300/1300 passed, 0 failed**.
- OpenSpec after sync/archive: `openspec validate --all` → **43 passed, 0 failed**.
- Structure/spec-reference regression: **71/71 passed, 0 failed**.
- Private local denylist and generic secret scanner passed over the complete staged diff; a private
  checkout example caught by the first scan was replaced with neutral placeholders before commit.
- Archived completed changes:
  `2026-08-27-add-lightweight-cpu-awareness`,
  `2026-08-27-enforce-host-resource-discipline`, and
  `2026-08-27-constrain-clangd-under-cpu-pressure`.
- Main specs now contain the synchronized host-awareness, workload-discipline, and owned-clangd
  pressure-control contracts.
- Git tag `v1.8.0` is intentionally pending explicit user confirmation (repo git policy).

## Verified caveats

- No real clangd, UE build, or real index was started by the agent; the Windows priority capability
  was validated only against a bounded headless Neovim process and restored to Normal.
- Dynamic PriorityClass behavior and the final C++ `gd` destination still require observation in the
  user's normal restarted GUI session.
- Four OpenSpec changes remain active because their task lists are incomplete; they were committed as
  planning/implementation state but were not archived.

---

## Working log (sliced from docs/changelog.md Unreleased, newest first)


### 2026-08-26 — 全仓动态宿主资源纪律：batch 让路、前台优先、owned clangd 可逆降级

**Task**

用户明确「丝滑」是宿主级首要原则，不只针对 clangd：本配置启动的任何工作都不能把整台电脑
挤到不可用；动态平衡必须建立在统一 lightweight awareness 上，而不是各子系统各抄一份阈值。

**Implemented**

- 新增 `utils.host_admission`：唯一持有 85/70 双水位、CPU defer cap、5s one-shot retry 与
  foreground 引用计数。配置从 `index.cpu_*` 上移到 `ue.config.resources`；新
  `NVIM_HOST_CPU_*` 环境变量优先，旧 `UE_INDEX_CPU_*` 保持兼容。`ue.index._admission` 只保留薄委派。
- 所有确认的可推迟重活在 process creation 前统一 gate：workspace fd scan、ccjson headless subprocess、
  CDB pipeline、CDB partition、cold/watcher GTAGS、csearch/cindex、controlled index。
  cold prepare 原本仍在 UI 进程执行代码自述会冻结 17s+ 的 CDB generator，现与 fast path 统一走
  admitted headless ccjson；controlled index 的 queued-drain 第二启动路径也复用同一 gate。
  `cdb_partition.py` 原本在正常 async prepare 链里仍 `:wait(timeout=120000)`，现正常 prepare 与
  `:UECDBPartition` / `:UECDBSwitch` 全改 async；只给显式 `:UEPrepareSync` 保留 blocking twin。
- watcher shader GTAGS 从 debounce timer 内同步 wait（实测约 1.1s）提取到 `ue.gtags.rebuild_async`：
  admitted、单写者、`vim.system` callback、task registry，全程不阻塞 timer callback。
- 用户前台工作不等待 CPU：terminal build/package、target task install/deploy、Android bespoke install、
  PCH rebuild、core health audit 登记 foreground token；最后一个 token 完成后立即唤醒 queued batch。
  已经运行的 batch 不因 CPU 被杀；既有 build⇄CDB WAW correctness cancel 保留。
- clangd 长驻服务采用独立可逆策略：`cpu_load` 在既有 1Hz host sample 上提供 subscriber（无第二个
  monitor timer）；`clangd_resource_controller` 复用通用滞回判据。Windows driver 通过原生
  Toolhelp32 只枚举当前 Neovim 的 direct child，并在 `NORMAL_PRIORITY_CLASS` 与
  `BELOW_NORMAL_PRIORITY_CLASS` 间切换；发现后持有绑定原 process object 的 HANDLE，1Hz 只调用
  `GetExitCodeProcess`，不重复 Toolhelp 全机快照，也不会因 PID reuse 误伤。
  不使用 PowerShell/WMI 轮询，不用 affinity，不 kill/suspend。
- clangd RPC public client 不暴露 pid；cmd factory 原样返回 RPC，在 spawn 后 100ms 异步 discover。
  无 PID/无 capability/原生调用失败只落结构化日志，绝不阻塞 LSP。
- 新增精确 spawn audit：覆盖 `vim.system`、`vim.fn.system/systemlist`、`jobstart`、`termopen`、
  `vim.loop|uv.spawn`、`vim.lsp.rpc.start`（含 project-owned trouble sidebar）。每个现有引用都有
  path+anchor+期望数量+类别+理由；新增/漂移立即 FAIL，
  禁止整文件或整个 API whitelist。

**Pitfalls / Gotchas**

- `vim.lsp.rpc.start` 把底层 `vim.SystemObj.pid` 藏在 private transport；拒绝用 `debug.getupvalue` 挖内部
  状态，改用 host-owned Toolhelp32 direct-child proof。Toolhelp 实测约 16.0ms/次，因此只用于有界启动
  发现；持续 reconcile 必须复用原生 HANDLE，不能每秒重扫。
- `uv.getrusage()` 不含 live child，不能拿 editor_pct 判断 clangd；controller 只消费 host signal 与
  自己证明过的 PID ownership。
- CPU defer cap 不能穿透正在运行的 foreground：cap 只解决长期高 CPU 饿死，不允许用户仍在 build 时
  反向启动后台索引。
- source scanner 若只看 `vim.system|jobstart` 会漏 UEBuild(termopen)、cindex(uv.spawn)、
  clangd(rpc.start)，形成危险假绿灯；现已补全 API 面。
- 不调整 Neovide refresh rate：无证据表明它是本次饱和源，降低前台帧率反而违背丝滑；本次只约束
  有证据的 process workloads。

**Validation**

- 定向：`cpu_admission` 37/37；`host_resource_discipline` 13/13；`clangd_resource` 10/10；
  `platform` 39/39；`ue_target_tasks` 8/8；`ue_workflows` 24/24；`ue_config` 11/11；
  `ue_api` 63/63；`ue_cdb` 31/31；`index_generation` 25/25；`index_delivery` 86/86；
  `core_health` 28/28；`ui_responsiveness` 20/20；`smoke` 19/19；`stability` 10/10，全部通过。
- Windows capability 宿主守卫：Toolhelp32 能枚举当前 nvim direct children，当前 PID 可查询；
  独立 headless nvim 对**自身 PID**执行 `low → normal` 两次 `SetPriorityClass` 均成功并恢复，
  未触碰 clangd/其他进程。
- 全量 `nvim --headless -l tests/run.lua`：1300/1300 passed，0 failed。
- Spec 一致性：两份 delta 已同步到 `editor-behavior-regression` / `cpp-semantic-index-coverage`
  主规格；changes 已归档至 `openspec/changes/archive/2026-08-27-*`。

**Follow-ups**

- 用户真实会话验证：观察 AppControl 中 clangd 高压时 PriorityClass 为 Below normal、回落后恢复 Normal；
  agent 不启动真实 clangd/构建代替该验收。

### 2026-08-26 — 建立常驻轻量 CPU 感知层，作为动态资源平衡的统一输入

**Task**

用户补全「丝滑」的首要原则：不能只保证 Neovim 主循环 async；本配置启动的工作若占满宿主 CPU、
让整台电脑卡死，同样不可能丝滑。用户进一步明确动态平衡的正确架构顺序：**首先必须有一个
lightweight CPU usage awareness 层**，再由 index/clangd/其他工作负载共享该读数做动态调整。

**Implemented**

- 新建 change `add-lightweight-cpu-awareness`，补齐 proposal/design/delta spec/tasks。实现中纠正一条
  错误假设：`uv.getrusage()` 只统计 Neovim 本进程，不包含仍在运行的 clangd 等子进程；未归属差值
  只能叫 `unattributed`，不得伪装成「外部进程占用」。
- `lua/utils/cpu_load.lua` 从按需冷采样改为 UI 会话常驻缓存：一个 250ms timer 每 tick 读取便宜的
  `getrusage`，每 4 tick（1Hz）读取 `cpu_info`；查询 `reading()` / `busy()` 只读缓存，不改变采样节奏。
- 暴露整机与 Neovim 本进程的 raw/EMA/trend、采样年龄及 `warming` / `ready` / `unknown` / `stopped`
  状态；差分、EMA、趋势均为可注入纯函数。headless 不启动 timer。
- `_admission` 改为消费完整 awareness reading：首个差分间隔 `warming` 短暂让路；平台不可测仍以
  `load-unknown` 放行，防止永久停摆；既有 85%/70% 双水位与防饿死上限仍只留在决策层。
- index 调度诊断追加 awareness status、Neovim CPU、host trend 与样本年龄；感知层自身不含水位、
  推迟上限或进程动作。
- `init.lua` 在既有 `UIEnter` 性能探针旁启动感知层；P6/K54 补记「感知必须常驻，不能在重活到期时
  冷启动」的架构教训。

**Pitfalls / Gotchas**

- 累计 CPU 计数物理上需要两个时间点，启动后第一个 1s 间隔只能诚实标为 `warming`，不能编造 0。
- 原被动实现最危险的组合是「首次查询 nil」+「unknown 放行」：最该节流的第一项重活反而穿透。
- `cpu_info()` 本机实测约 0.515ms/次并分配 24 个 core table，不能 4Hz 高频调用；`getrusage()`
  约 0.0019ms，可高频使用。受控 1.3s smoke 得到 `ready`、6 ticks、2 host samples，
  `average_tick_ms=0.339`。
- 本 change 只交付**感知输入**；clangd OS 级动态降级与全仓 spawn 接入分别由
  `constrain-clangd-under-cpu-pressure` / `enforce-host-resource-discipline` 承载。

**Validation**

- `cpu_admission`：32/32；`ui_responsiveness`：20/20；`index_delivery`：86/86；
  `ue_config`：10/10；`stability`：10/10；`utils`：49/49，全部通过。
- 有界真实 sampler smoke（不启动 clangd/构建）：`ready`，host 11.9%，24 cores，
  2 host / 6 editor samples，0.339ms average tick。
- 全量 `nvim --headless -l tests/run.lua`：1270/1270 passed，0 failed。
- Spec 一致性：delta 已同步到 `editor-behavior-regression` 主规格；change 已归档至
  `openspec/changes/archive/2026-08-27-add-lightweight-cpu-awareness/`。

**Follow-ups**

- 后续动态执行已由上方 `enforce-host-resource-discipline` / `constrain-clangd-under-cpu-pressure`
  条目完成；阈值统一归 `utils.host_admission`，不得各子系统复制。

### 2026-08-26 — 让 UEPrepare 真正交付语义索引（含进度指示），并让 C++ gd 诚实失败

**Task**

用户报告 `VulkanResources.h:1167` 的 `WrapAroundAllocateMemory` 跳转"等一会出来几个 unity cpp
然后让我选"，并指出**这明明可以定位**。用户的操作习惯是
`set platform → set project → 编译 → :UEPrepare`，明确表示"我不可能记住所有平台的这种命令，
你设计出来也不应该给人增加心智负担"。

**根因（不是用户漏跑命令）**

该符号在模块内**只有唯一定义**（`VulkanRHI.cpp:3594`），是 C5 契约最干净的情形，本该确定性
resolve。探针在故障当时已记下原因：
`ambiguous-context | stage=context | reason=semantic-tu-unavailable | generation_class=missing`。

先纠正一个我自己的错误判断：**prepare 确实会间接触发 index** —— `lua/ue.lua` 三条完成路径
（8234/8357/8692）全都调 `schedule_index_refresh{current,hot,full}`。用户的判断是对的，
不需要手动 `:UEIndexFull`。真正的缺陷在**交付链路**：

| 缺陷 | 代码/磁盘证据 |
|---|---|
| 失败完全静默 | 失败分支只写 `status="error"`，**无 notify、无日志**；全仓 index 构建日志 0 条 |
| 无跨会话恢复 | 无 `VimLeave`/resume；`build.status` 永久卡在 `running`、`finished_at=0` |
| 交付不完整不算失败 | `full.json` 落盘但 manifest 缺失 → gate 判 not ready → `gd` 静默退化 |
| 陈旧产物不清理 | `.pre-pch.bak` + `.pre-unify.bak` 实测 **1065MB**；旧 bucket 7/24 僵尸 CDB 92MB |
| 违背 P12 | 语义失败后给候选列表；P12 明确要求"Clang 语义失败必须诚实失败" |

旧 bucket 里挖出一条**从未被用户看到的真实失败**：`stats={full_runs:0}`、`status=error`，
message 里 25KB 的诊断信息（`ERROR: cannot find Intermediate dev root`、`exit 1`、
indexer `3221225477`）全部只躺在 JSON 里，用户屏幕上什么都没有。

**误分类的确切机制**：`semantic_sidecar.lua` 把"多个 context 各自失败"聚合成
`ambiguous-context`（`has_ambiguous and not has_unavailable`），而 `ambiguous-context` 是**唯一会
给用户弹候选**的终态 → readiness 问题被伪装成真歧义 → 唯一定义变成假候选列表。

**Implemented**

- `lua/utils/ue_goto/semantic_navigation.lua`：新增纯函数 `M._apply_readiness_override`
  —— index 未就绪时把 `ambiguous-context` 降级为 `unavailable` + readiness reason；
  降级后**不再透传 contexts**（候选=可选定位目标，不可用时不得给）。index 就绪时的**真歧义仍保留**。
  失败提示新增 `remedy`，指向用户的习惯入口 `:UEPrepare`，不要求记忆平台专属命令。
- `lua/ue/index/_build.lua`：**新增进度指示**（用户要求）—— 复用 prepare 同一 fidget 通道
  （右下角、非侵入），P5 合规：由真实子进程输出驱动、无周期 ticker、成功自然消退；
  子进程输出按 pending-buffer 拼行后再展示（chunk 非行对齐，K51 教训）。
  失败改为 **notify + `utils.log` 结构化落盘**（phase / exit code / stderr 尾部）。
  `running` 状态携带 `owner_pid`，使"构建中"跨进程可falsify。
- `lua/ue/index/_generation.lua`：新增 `reset_orphaned_build`（经 `M._reset_orphaned_build` 暴露），
  挂在 `normalize_index_state` 上 —— 每次读状态即自愈孤儿 `running`；**owner 存活时不得抢占**
  （保护另一个 Neovim 的在飞构建，K43）。
- `lua/ue/cdb/pipeline.lua`：新增 `M.INTERMEDIATE_BACKUP_SUFFIXES` /
  `M.intermediate_backup_paths`，在 `finish_success` 清理 `.pre-pch.bak` / `.pre-unify.bak`；
  **只删 active CDB 派生的精确后缀**，不跨 platform 分片或 project bucket（K27/C5b）；
  **失败路径保留备份**以便诊断。

**Pitfalls**

- 我一度建议用户"再跑一次 `:UEPrepare`"和"手动跑 `:UEIndexFull`"，**两条都是错的**：
  prepare 昨天已成功（timings total=293s、active CDB 241MB），且 prepare 本就会触发 index。
  教训：**先读调用链再下结论**，"让用户重跑"是最容易掩盖真实缺陷的建议。
- 我还查错了 bucket/platform（看 `Android-Development`，实际是 `Android-Test`），
  结论虽巧合成立但依据是错的。多 bucket 场景必须先用 `target-selection.json` 确认 tuple。
- `ue.index` 子模块是 loader 风格 `return function(M, core)`，**不能直接 require 子模块**；
  测试须经 `require("ue.index")`。

**Validation**

- 分范围：`index_delivery` 25/25（新增）、`index_generation` 25/25、`cpp_semantic_index` 1/1、
  `cpp_semantic_context` 11/11、`ue_goto_behavior` 8/8、`clangd_commands` 5/5、`ue_api` 63/63、
  `ue_cdb` 31/31。
- **全量回归：`nvim --headless -l tests/run.lua` → 1175/1175 passed, 0 failed**。
- **按用户习惯路径验收**（未执行任何索引命令）：在真实 `VulkanResources.h:1167` 上，
  孤儿 running 复位为 `interrupted`、readiness=missing → `unavailable/index-provider-not-ready`、
  readiness=ready → 真歧义保留、**quickfix 条目数 before=0 after=0（无候选列表）**。
- 真实产物清理：手动回收既有 **1065MB** 陈旧 `.bak`，确认三个 active CDB 完好。
- spec 一致性：新增 change `deliver-semantic-index-from-prepare`，含
  `cpp-semantic-index-coverage`（交付可观测性 + 自愈 + 产物清理）与
  `cpp-contextual-definition-navigation`（readiness 不得伪装成 ambiguous、不得给假候选）
  两份 delta spec；`openspec validate --strict` 通过。

**Implemented（第二轮：收尾 5.1 / 5.3 / 6.1）**

- 新增 `lua/ue/index/_delivery.lua`（loader 风格，加载序 `_generation → _delivery`）：
  - `index_delivery_line(summary)` 给出单一交付判定 —— `ready` / `building` / `queued` /
    `failed` / `interrupted` / `pending`；**stale 或 missing 选择一律不得报 ready**
    （gate 会 defer，报 ready 即自相矛盾，K41）。
  - `prepare_delivery_suffix(ctx)` 供 prepare 汇报使用；状态不可读时降级为空串，
    **不得抛错打断 prepare**。
  - `stale_index_artifacts(ctx)` 报告"磁盘上存在但无法支撑当前 generation"的 controlled CDB
    （无 manifest / generation 不匹配 / 未注册）。**只报告不删除** —— 跨实例、跨 tuple 删除
    不安全（K27/C5b 失效矩阵、K43 多实例隔离），回收属于持 lease 的显式 prepare 步骤。
- `lua/ue.lua` `prepare_summary` 追加交付状态行 —— prepare **不再在 index 构建中/失败时
  暗示语义层已就绪**。façade 仅一行委派，`ue.lua` 保持 10562（ratchet 未上调）。
- `lua/ue/index/_generation.lua` 导出 `core.h.same_generation`，使**陈旧判定与选择逻辑
  共用同一谓词**，不各写一套。
- `lua/ue/index/AGENTS.md` 同步新模块与加载序，并把"交付可观测"写成硬约束。

**Pitfalls（第二轮）**

- 行数门禁两次拦住我：先是 `ue.lua` 超 ratchet，后是 `_generation.lua` 涨到 825 行（限 800）。
  两次都**没有上调基线**，而是把"交付判定"这一独立关注点抽成 `_delivery.lua`。
  门禁在这里起了正面作用：它逼出了正确的模块边界。
- `_delivery` 需要 `same_generation`，而它原先只是 `_generation` 的 chunk-local。
  跨子模块复用**必须经 `core.h` 导出**，不得复制一份判据。

**Validation（第二轮）**

- 分范围：`index_delivery` 38/38（新增 13 例）、`index_generation` 25/25、`stability` 10/10、
  `structure` 71/71、`ue_api` 63/63、`cpp_semantic_index` 1/1。
- **全量回归：1188/1188 passed, 0 failed**。
- `openspec validate --all` → **40 passed, 0 failed**；两份 delta spec 已 sync 进主 spec，
  change 归档为 `openspec/changes/archive/2026-08-26-deliver-semantic-index-from-prepare`。
- **严格按用户习惯路径验收**（脚本内禁止调用 `:UEIndexFull` 及任何索引 API）：
  ① prepare 汇报 `verdict=pending` + "not delivered yet"，**未谎称就绪**；
  ② 真实 `VulkanResources.h:1167` 上 `gd` 的 **quickfix before=0 after=0 —— 无候选列表**；
  ③ 孤儿 running（owner 已死）复位为 `interrupted`，**owner 存活时保持 running 不抢占**。

**Follow-ups**

- headless 冷起无 project selection，故 acceptance 脚本的 `[3]` 段拿不到 ctx
  （"No Unreal Engine root found"）—— 这是**验证脚手架的局限**，非本次回归；真机会话已选
  platform/project 时该路径可用。
- 旧 bucket 的 7/24 僵尸 `current.json`/`hot.json`（92MB，无 manifest）**故意保留**，
  作为 `stale_index_artifacts` 的真实验证素材；其物理回收待持 lease 的显式清理步骤。
- 当前 tuple 的 controlled index 仍未交付，故用户那次 `gd` 仍不会成功 —— 但现在它会
  **诚实报告 index 未就绪并给出补救动作**，而不是塞一堆假候选。
