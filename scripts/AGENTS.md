# scripts/ — 安装 / profiling / lint / 测试编排脚本

> 继承 `../AGENTS.md`（根强制入口）。非 Lua 运行时代码，同样遵守可发现/可记录纪律。

## 用途

开发者侧脚本：Windows 安装（`install_windows.ps1`）、回归编排（`run_regression.ps1`、
`run_all_tests.ps1`）、lint（`lint_no_bare_globals.*`）、profiling（`profile_startup_quick.sh`、
`mem_top.ps1`）、CDB/PCH 流水线 runner（`run_*.ps1`），及历史 `test_*.lua`（ue_goto 子集）。

## 什么属于这里 / 不属于这里

- **属于**：脱离单次编辑、面向开发者工作流的脚本（安装/编排/lint/profiling）。
- **不属于**：纯工具/索引器（→ `../tools/`）、回归用例本体（→ `../tests/cases/`）。

## 专属约定

- **`run_regression.ps1` 是本机一键回归入口**（转发 `nvim -l tests/run.lua` + 退出码），不在此放测试逻辑。
- 历史 `test_*.lua`（ue_goto）：稳定子集经 `tests/run.lua` 的 legacy 旁路 fork 调度；需 clangd/socket 的已排除。
- `headless_smoke.lua` 保留为兼容入口，断言已等价迁入 `../tests/cases/`。
- 公开镜像安全：脚本不得硬编码 secret；已公开的工具路径除外。

## 改动 → 必跑回归

改 `run_regression.ps1` / `run.lua` 编排 → 跑全量 `nvim -l tests/run.lua` 确认入口/退出码无回归。

## 先读

`../docs/testing-regression.md`（权威回归入口与分范围映射）、`../tests/AGENTS.md`。
