# docs/ — 文档层

> 继承 `../CLAUDE.md`（根强制入口）。只写增量。

## 用途

仓库全部长期文档：`CONSTRAINTS.md`（禁止/坑/约束权威索引）、`architecture/`（总览）、
`architecture-*.md`（符号解析 / vs-LazyVim 深度专题）、`plans/`（ADR + 迭代日志）、
`skills/`（端到端配方）、`testing-regression.md`（回归政策）、`changelog.md` + `release_*.md`（变更记录）、
`TOOLING.md`（工具链钉死）、`ue_lazyvim_cheatsheet.md`。

## 文档分类约定

| 类型 | 放哪 | 特征 |
|---|---|---|
| 禁止/坑/约束 | `CONSTRAINTS.md` | 索引型，指回出处，不复制原文 |
| 架构总览 | `architecture/overview.md` | 全景 + 归属边界 |
| 子系统深度 | `architecture-*.md` | 单主题深挖 |
| 架构决策(ADR) | `plans/*.md` | 为什么这样设计（`decisions/` 索引指回这里） |
| 端到端配方 | `skills/*.md` | 可执行 + 可校验数字 |
| 回归政策 | `testing-regression.md` | 分范围映射 + 操作细则 |
| 变更记录 | `changelog.md` → `release_*.md` | 每次改动追加，攒够切片归档 |

## 专属约定

- **出处优先**：索引型文档（CONSTRAINTS / decisions / lessons）指回权威出处，不整段复制。
- **公开镜像安全**：本仓镜像到公开 GitHub，文档不得含 secret 或新私有专属路径。
- 改约束/版本钉死/启动顺序 → 同步 `CONSTRAINTS.md` §三并保持出处链接。
- 文档结构（CLAUDE.md 存在性 / 知识库根 / 内链不悬空 / 政策可发现）有回归守护（`../tests/cases/structure_spec.lua`）。

## 改动 → 必跑回归

改文档/规则/知识库结构 → `structure`。

## 先读

`CONSTRAINTS.md §四 维护契约`、`../memory/project_overview.md`。
