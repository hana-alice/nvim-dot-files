# Proposal: codebase-health-check

## Why

近三个月高频迭代（Android DAP 路线三次重写、csearch 单写者/指纹/增量三连改、
K40/K42 两次「自己写的代码是卡顿元凶」）暴露出一个模式：**问题都是事后靠 stall_probe /
jit.profile / 真机日志抓出来的，没有一次主动体检把它们提前找到**。当前 `lua/ue.lua`
已 10472 行（约束是 800 行/文件），坑清单积到 K42，workaround 9 个（每个都有
removal_condition 但从未复查过是否可移除），值得做一次系统性 health check，把
「设计缺陷 / 违反自身约束 / 潜在 K43 候选」在爆发前清点出来。

## What Changes

- 执行一次**只读审计**（本 change 的 apply 阶段不做行为修复，只产出报告 + 后续
  change 清单），覆盖五个维度：
  1. **P6 阻塞面扫描** — 全仓 timer/autocmd/事件回调里的同步 spawn、`vim.wait`、
     大文件同步 IO（K40/K42 的模式化复查，而非个案）。
  2. **约束自违反** — 文件行数（ue.lua 10472 vs 约束 800）、禁止项 P1–P17 的
     源码级复核、C4 六约定抽查。
  3. **workaround 存活审查** — 9 个 workaround 逐一对照 frontmatter 的
     `removal_condition`：上游已修的标记可移除，条件已失效的更新。
  4. **并发/生命周期缺陷** — timer/job/watcher 的 stop 路径完整性（K40 的
     「adapter 死了 poller 不停」这类），dirty set 封顶行为（现观测到 cap=1000
     打满，overlay 语义退化未告警）。
  5. **测试盲区** — 27 个 spec 对照子系统清单找零覆盖区（如 `_progress`、
     `ue_watch` flush 排程、statusline timer）。
- 产出物：`docs/health-check-2026-07.md` 审计报告（每项 finding 带严重级 /
  出处 / 建议动作），高危项各自开独立 change，不在本 change 内修。

## Capabilities

### New Capabilities
- `codebase-health-audit`: 定义一次性健康审计的执行要求——五维度覆盖、finding
  的证据标准（必须有文件:行号或复现命令，不收「感觉不好」）、报告格式、
  与后续修复 change 的交接契约。

### Modified Capabilities

（无——本 change 不改任何现有行为规格；修复类动作全部交给后续独立 change。）

## Impact

- 只读审计：不改运行时代码；仅新增 `docs/health-check-2026-07.md` 与（若发现
  失效 workaround）对应的移除建议清单。
- 涉及阅读面：`lua/ue.lua`、`lua/ue/dap/*`、`lua/utils/*`、`lua/workarounds/*/*`、
  `tests/cases/*`、`docs/CONSTRAINTS.md`（P1–P17 / C1–C8 / K1–K42 对照源）。
- 后续影响：审计产出的高危 finding 将各自立 change（预期 2–5 个），按仓库
  规范走各自的回归与 changelog。
