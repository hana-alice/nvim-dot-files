# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)

## Unreleased

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


(empty — sliced into `docs/release_1.7.0.md` on 2026-08-25.)
