# Tasks — architecture-boundary-regression

> **DRAFT / 阻塞中。** 所有任务在 design.md 决策甲/乙/丙拍板前不得开始。
> 本文件仅记录「若决定落地」的拆解，供未来拿起。

## Phase 0 — 决策（阻塞，仓主拍板）

- [ ] 决策甲：cdb/pipeline.lua OS 分支 → 收口 / 白名单
- [ ] 决策乙：core 零依赖 → 升格承重 / 仅观测
- [ ] 决策丙：go/no-go 引入 AST 源码扫描器（否则本 change 保持 draft 归档）

## Phase 1 — 扫描器与用例（决策丙 = go 后）

- [ ] 在 `tests/harness` 或 spec 内封装一个 treesitter lua 扫描 helper：
      给定 glob + query，返回 `{file, line, node_text}` 列表（跳过注释/字符串）
- [ ] `tests/cases/boundaries_spec.lua`：规则常量表（带 CONSTRAINTS 条目号注释）
- [ ] 实现 P3（vim.lsp.handlers 赋值检测）
- [ ] 实现 R5（core/ require 目标白名单）
- [ ] 实现 DI seam 锚定（三文件无 load-time require("ue")）
- [ ] 实现 R1（OS 探测调用点 + 白名单），按决策甲处理 pipeline 命中

## Phase 2 — 文档同步（DoD）

- [ ] `openspec/specs/architecture-boundary-regression/spec.md`（从本 change 提升）
- [ ] `tests/CLAUDE.md`：CHANGE-TO-FILTER MAP 加 `boundaries` 行
- [ ] `docs/CONSTRAINTS.md`：§三加 C9，§五可发现性登记
- [ ] `tests/cases/structure_spec.lua`：如把 spec 纳入可发现性校验则同步
- [ ] `docs/changelog.md`：Unreleased 追加一条，Validation 写所跑 filter

## Phase 3 — 验证（DoD C6）

- [ ] `nvim --headless -l tests/run.lua boundaries` 全绿（含决策甲处理后无误报）
- [ ] `nvim --headless -l tests/run.lua structure`（若动了文档/规则）
- [ ] 提交前全量 `nvim --headless -l tests/run.lua`
- [ ] 自检：故意在 core/ 插一条 `require("snacks")` 应使用例变红（哨兵有效性验证）
