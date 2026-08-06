# Design: codebase-health-check

## Context

三个月高频迭代后的技术债盘点。已知信号（都来自事后追查，不是主动发现）：

- **K40**：liveness poller 在 timer 回调同步 `vim.fn.system(adb)`，全天 ~50 stalls/min。
  同一模式（timer/事件回调里同步 spawn）是否还有其他实例，从未系统扫过。
- **K42**：gitsigns watch_gitdir × git fsmonitor 自激，jit.profile 采样才定位。
  「插件 watcher 观察被自己触发的变化」是一类缺陷，不是一个。
- **约束自违反**：`lua/ue.lua` 10472 行（coding-style 约束 800 行封顶）；
  当前实际观测 `ue_watch` persistent_dirty **打满 cap=1000**（openexr/zlib 等
  ThirdParty 测试文件占大头），rg-on-dirty overlay 因此背着 1000 个几乎全是噪声
  的文件跑，且打满后丢增量**无告警**——freshness 语义静默退化。
- **workaround 从未复审**：9 个 workaround 全带 `removal_condition`，但没有任何
  机制或例行动作检查条件是否已满足（如 snacks/lazy 上游已修）。
- 27 个 spec 文件对 10 个子系统的覆盖不均（dap/csearch 厚，_progress/statusline/
  ue_watch 排程薄或零）。

约束：本 change 是**只读审计**——发现的问题记录成 finding，修复交给后续独立
change。这保持每个修复有自己的回归范围与 changelog（C6/C7），避免一个巨型
change 混杂十种改动。

## Goals / Non-Goals

**Goals:**
- 五维度系统扫描（P6 阻塞面 / 约束自违反 / workaround 存活 / 并发生命周期 /
  测试盲区），每个 finding 带证据（文件:行号或复现命令）与严重级。
- 产出 `docs/health-check-2026-07.md` 单一报告 + 高危项的后续 change 建议清单。
- 对「可机器检查」的项（行数上限、timer 回调内禁 `vim.fn.system`）评估是否
  值得固化成 lint/spec，防再犯。

**Non-Goals:**
- 不在本 change 内修任何 finding（包括看起来一行就能修的）。
- 不重构 ue.lua 拆文件（那是独立大 change，本次只量化现状与切分建议）。
- 不引入新工具/依赖（审计用 rg/现有 headless 测试设施完成）。

## Decisions

### D1 — 审计执行形态：脚本化扫描 + 人工判读，不做全自动
可机械化的（grep 模式、行数统计、frontmatter 解析）写成一次性脚本跑出候选清单；
每条候选必须人工判读定级（很多 `vim.fn.system` 在用户命令路径是合法的，只有
timer/autocmd/回调里的才是 P6 违例）。备选「纯人工通读」被否——10k+ 行通读的
遗漏率高于模式扫描。

### D2 — finding 证据标准：文件:行号 或 可复现命令，二选一必有
沿用本仓「出处优先」文化。「感觉这里不好」不收。每条 finding 格式：
`[严重级] 维度 | 一句话 | 证据 | 建议动作(修复/记坑/立change/忽略+理由)`。
严重级三档：HIGH（正确性或已知会再犯的性能坑）/ MED（约束违反但当前无症状）/
LOW（风格、可读性、待观察）。

### D3 — workaround 复审方法：上游版本对照，不做行为回归
逐个读 frontmatter 的 `issue` / `removal_condition`，对照当前锁定的插件版本
（lazy-lock.json）与上游 changelog/issue 状态。判定三态：可移除（条件已满足，
建议开移除 change 并跑对应回归）/ 保留（条件未满足）/ 条件失效需改写（上游
变化使条件无法再评估）。不在审计里直接禁用 workaround 试行为——那是移除
change 的事。

### D4 — dirty-set 噪声问题定级为 HIGH 并单独立 change
现场证据已足（cap=1000 打满、内容全是 ThirdParty 测试文件、打满丢增量无告警）。
根因候选两个方向：watcher blocklist 缺 ThirdParty 测试目录 vs 某次批量操作
（git/构建）触发的一次性洪水未被清理。审计只补齐证据链与根因判定，修复
（blocklist 扩展 / cap 打满告警 / overlay 降级策略）交后续 change。

### D5 — 报告落点：docs/health-check-2026-07.md，不进 CONSTRAINTS
CONSTRAINTS 是「已付出调试成本的坑」的索引；审计 finding 在被修复/证实前只是
候选。修复落地时才按 C7/维护契约升格为 K 条目。报告带日期后缀，作为一次性
快照存档，不承诺持续维护。

## Risks / Trade-offs

- [审计范围膨胀] 10k 行 ue.lua 逐行看会烧掉大量时间 → 模式扫描先行，人工判读
  只进候选集；单维度设时间盒，超时的记为「未覆盖区」如实写进报告。
- [只读原则被突破的诱惑] 一行修复很诱人 → 硬规则：本 change 的 tasks 里没有
  任何「修改 lua/」的任务；发现即记录。唯一例外：审计脚本自身放 tools/（新文件，
  不碰运行时）。
- [workaround 误判可移除] 上游 changelog 说修了 ≠ 本机组合下真修了 → 判定
  「可移除」只产出建议 change，移除 change 自己必须带禁用后的行为验证。
- [报告腐烂] 一次性快照三个月后失真 → 接受；报告头部写明快照日期与 HEAD commit，
  不承诺更新。

## Migration Plan

无迁移——只读审计。产出报告 + 后续 change 清单后本 change 即可 archive。
