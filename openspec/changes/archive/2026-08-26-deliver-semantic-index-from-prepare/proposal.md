## Why

**用户的实际习惯链路是** `set platform → set project → 编译 → :UEPrepare`。这条链路走完，
C++ `gd` 就应该可用。它现在不可用，而且**系统不告诉用户为什么**。

用户报告 `VulkanResources.h:1167` 的 `WrapAroundAllocateMemory` 跳转"等一会出来几个 unity cpp
然后让我选"。该符号在整个模块内**只有一个定义**，是 C5 契约里最干净的情形：

```
VulkanResources.h:1206   声明
VulkanRHI.cpp:3594       唯一 out-of-line 定义（FVulkanRingBuffer::）
VulkanResources.h:1167   调用点（用户光标处）
```

它本该确定性 resolve，却退化成候选列表。探针在故障当时就记下了原因
（`ue_probes.json`，`cpp-semantic-navigation`）：

```
ambiguous-context | stage=context | reason=semantic-tu-unavailable | generation_class=missing
```

**根因不是用户漏跑命令。** `lua/ue.lua` 的三条 prepare 完成路径（fast-path 8234 / cold 8357 /
pipeline 8692）**全都**调用了
`INDEX_FN.schedule_index_refresh(ctx, {current=true, hot=true, full=true})`。
所以 prepare 确实会间接触发 controlled index —— 用户的判断是对的，不需要手动 `:UEIndexFull`。

问题在**交付链路**：实测驱动一次 `full` 阶段可以正常产出
`cdb/index/<platform>/compile_commands/full.json`（273MB / 16363 entries），但 manifest 写入、
`stats` 计数、active index promotion **全部位于 `vim.system` 的完成回调内部**
（`lua/ue/index/_build.lua:504-560`）。这条链路缺少三样东西：

| 缺失 | 代码事实 | 后果 |
|---|---|---|
| 失败/中断可见性 | 失败分支只写 `status="error"`，**无 notify、无日志** | 用户完全无从得知 |
| 跨会话恢复 | 无 `VimLeave`/`ExitPre`/resume；启动不检测遗留 `running` | 关窗口=白跑，且状态永久卡住 |
| 完成语义覆盖 index | prepare 在 CDB 生成后即宣告完成，把分钟级重活丢给静默后台 | 用户合理认为"齐活了" |

磁盘证据正是这个形态（当前 tuple，`Android-Test`）：

```
prepare_timings   total=293s（8/25 17:55 成功）    ← prepare 确实跑过
active CDB        241MB（8/25 17:54）             ← 产物齐全
cdb/index/<plat>/ queue.json=[]  无 compile_commands/
                  stats={current_runs:0, hot_runs:0, full_runs:0}   ← 一次成功都没记录过
                  build.status="running", finished_at=0             ← 永久卡在 running
全仓 build_clangd_index / build_full_cdb 日志：0 条                 ← 从未产生过任何日志
```

`full_runs:0` + 零日志 + `status` 永久 `running` 共同证明：**它被调度过、跑过、但从未成功交付，
且整个过程对用户静默。**

第二个独立缺陷：即使 `full.json` 落盘，**manifest 缺失时 gate 仍判 not ready**（K41 要求 gate
消费持久化 tuple artifact readiness），`gd` 继续静默退化。

第三个缺陷（用户提出）：**prepare 不清理陈旧产物**。本机现状 ——
`active/` 下 `.pre-pch.bak` + `.pre-unify.bak` 共 **492MB** 从不清理；旧 bucket 的
`current.json`/`hot.json` 仍是 **7/24** 的僵尸（92MB，无 manifest、无人失效）。
C4-6 只约束"未变更时跳过写入"，**没有对应的"陈旧产物必须失效或清除"契约**。

第四个缺陷：C++ `gd` 语义失败后**给出候选列表**，直接违背 **P12**
（"C++ `gd` 禁止自动 csearch / GTAGS fallback；Clang 语义失败必须诚实失败"）。
文本搜索分不清重载/同名/namespace，把它伪装成定位答案比诚实报错有害得多 —— 用户被迫在假
选项里挑，且无从判断哪个是对的。

**Why now**：这四条叠加的净效果是**把系统缺陷转嫁为用户心智负担** —— 用户被要求记住并手动执行
一个平台专属命令（`:UEIndexFull`），才能让"跑完 prepare"名副其实。用户明确指出这不合理，
且"记不住所有平台的这种命令"。设计目标应是 prepare 一步交付，而非增加第五个命令。

## What Changes

- **prepare 的完成语义覆盖到 index 就绪**：controlled index 构建成为 prepare 的可观测阶段，
  而非完成后静默 fire-and-forget。prepare 的进度与终态 SHALL 反映 index readiness。
- **后台索引任务提供进度指示**（用户要求）：`current`/`hot`/`full` 构建期间通过既有
  `utils.async_launcher` / fidget 进度通道显示阶段与进展，遵守 P5（不做周期 ticker 刷屏：
  至多 start + 中段更新，成功后自然消退）。
- **index 构建失败/中断必须可见**：失败 SHALL notify 并落 `utils.log`（含 phase、exit code、
  stderr 尾部），不得静默。
- **跨会话遗留状态可自愈**：启动/首次索引操作时检测上次遗留的 `running`（owner 进程已死），
  SHALL 复位并重新调度或明确告知，不得永久卡死。
- **交付不完整即为失败**：`full.json` 存在但 manifest/selection 缺失 SHALL 记为 error 并可见，
  不得让 gate 静默 defer。
- **prepare 清理陈旧产物**：`.pre-*.bak` 中间备份在成功后清理；不同 generation 的陈旧
  controlled CDB 失效或清除。
- **C++ `gd` 语义失败诚实失败（P12）**：语义终态为 `unavailable`/`ambiguous-context` 时
  MUST NOT 提供 csearch/GTAGS 候选列表；SHALL 明确告知原因与补救动作。

## Impact

- Specs: `cpp-semantic-index-coverage`（新增 index 交付可观测性与自愈契约）、
  `cpp-contextual-definition-navigation`（明确 P12 终态：不得给假候选）
- Code: `lua/ue/index/_build.lua`（进度/日志/失败可见/自愈）、`lua/ue.lua`
  （prepare 完成语义与产物清理）、`lua/utils/ue_goto/`（P12 终态）
- 回归: `index_generation` `cpp_semantic_index` `clangd_commands` `ue_api`
  `cpp_semantic_context` `ue_goto_behavior`；跨 ue.lua 接缝 → 提交前全量
- **验证纪律**：用户明确要求"一切验证都只能按照我的操作习惯来"。所有验收 MUST 沿
  `set platform → set project → 编译 → :UEPrepare` 路径进行，MUST NOT 依赖用户手动执行
  `:UEIndexFull` 或其他平台专属命令。
- 风险：`ue.lua` 处于单调下降 ratchet（当前 10562 上限），新增逻辑须落在 `lua/ue/index/`
  或新模块，不得抬高 ue.lua 行数。
