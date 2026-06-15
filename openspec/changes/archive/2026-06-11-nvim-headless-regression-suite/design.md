## Context

当前仓库（`~/.claude/.../nvim`，LazyVim 基座 + 自研 `ue` 模块）已有的测试资产：

- `scripts/headless_smoke.lua`：质量最高，已用 `check(name, fn)` + pcall 收集结果、统一报告、`quit`/`cquit 1` 退出，覆盖平台驱动契约、`ue.core`、`ue.config`、`ue.cdb.*`、`ue.dap.*`、公共 API 冻结。**这是事实上的回归基线，应作为新框架的种子**。
- `scripts/test_*.lua`：一批针对 `ue_goto` 的单点用例，约定为打印 `PASS` 或报错。
- `scripts/run_all_tests.ps1`：PowerShell 编排器，但写死了 `ue_goto` 子集且依赖 `nvim.exe` 绝对路径与 `<LOCAL_APPDATA>` 占位符，不能直接当全量入口。
- `tools/*.lua`：DAP/e2e 相关，多数需要真机或 clangd，**不纳入默认回归**。

约束（来自 CLAUDE.md / openspec/config.yaml / docs/CONSTRAINTS.md）：

- 不改动现有运行时逻辑，测试仅以「只读 require + 断言」访问模块。
- 不引入新第三方依赖；测试框架纯 Lua。
- 平台为 Windows + Windows Terminal，但运行入口应跨平台（同一份 Lua 既能本机也能 CI）。
- 命令风格偏好单条直接命令，不用 `&&` 链式。

## Goals / Non-Goals

**Goals:**

- 提供单一 headless 入口，一条命令跑全量回归，输出 PASS/FAIL 汇总并以退出码反映结果（0/1）。
- 提供纯 Lua 轻量框架：断言集合、`describe`/`it` 分组、错误隔离、自动发现、runtimepath 自举。
- 全面覆盖配置功能域：配置加载冒烟、平台驱动契约、`ue` 公共 API 冻结、`ue.config` schema、`ue.cdb.*`、DAP 平台注册、`utils.*` 工具加载。
- 把 `headless_smoke.lua` 的现有断言无损迁移进新框架，避免覆盖回退。
- 提供使用文档：怎么跑、怎么加用例、退出码约定。

**Non-Goals:**

- 不做需要真机 / adb / 运行中 clangd / 网络的 e2e（保留在 `tools/` 手动运行）。
- 不替换 LazyVim 插件本身的测试，不测第三方插件内部行为，只测「我方配置是否能加载、是否注册预期命令」。
- 不追求行覆盖率数字（Lua headless 下无现成 coverage 工具且会引入依赖），以「功能域 + API 冻结」作为覆盖口径。
- 不删除现有 `scripts/test_*.lua`，仅纳入调度。

## Decisions

### 决策 1：测试根目录采用新建 `tests/`，而非塞进 `scripts/`

- 理由：`scripts/` 已混杂构建脚本（`.ps1`/`.py`）与一次性探针，语义不清。新建 `tests/` 作为唯一回归根，结构清晰、便于自动发现。
- 结构：
  - `tests/run.lua`：统一入口（`nvim -l tests/run.lua` 执行）。
  - `tests/harness/init.lua`：框架（断言 + `describe`/`it` + runner + 报告 + 自举）。
  - `tests/cases/*_spec.lua`：按功能域拆分的用例文件（高内聚、小文件，每个 < 400 行）。
- 备选：扩展 `run_all_tests.ps1` 维持现状 → 否决，PowerShell 编排不跨平台且写死路径。

### 决策 2：框架基于 `headless_smoke.lua` 的 `check + pcall + 汇总 + cquit` 模式演进

- 沿用其已验证的核心：`pcall` 捕获、收集 results、最后统一打印、`vim.cmd("quit")` / `vim.cmd("cquit 1")` 控制退出码。
- 升级点：把扁平 `check(name, fn)` 包装成 `describe`/`it`，名字拼成 `describe > it`；断言从裸 `assert` 扩展为 `assert_eq/assert_true/assert_type/assert_error`，失败信息携带 expected/actual。
- 理由：复用已被实践证明可在该 nvim headless 下稳定工作的模式，降低风险。

### 决策 3：自动发现用 `vim.fn.glob` 扫描 `tests/cases/*_spec.lua`

- 入口 `tests/run.lua` 自举 rtp 后，`glob` 出全部 `*_spec.lua`，逐个 `dofile`/`loadfile` 执行，用例文件内通过框架的 `describe`/`it` 注册。
- 理由：新增用例零改入口，满足「以后每次开发完跑回归」并持续扩充。
- 备选：手写文件清单 → 否决，违背自动发现要求、易漏登记。

### 决策 4：入口同时提供 Lua 与一层薄 PowerShell 包装

- 主入口为纯 Lua（`nvim -l tests/run.lua`），跨平台、可 CI。
- 额外提供 `scripts/run_regression.ps1`：定位 `nvim`、设置 `vim.g.started_with_stdin`、调用 Lua 入口、转发退出码——给 Windows 本机一键体验，复用现有 `run_all_tests.ps1` 的调用习惯。
- 理由：兼顾跨平台与本机便利；PowerShell 仅做转发，不承载测试逻辑。

### 决策 5：用例文件按功能域切分，覆盖映射到 spec

- `smoke_spec.lua` → 配置加载冒烟 + `ue.setup()` 命令注册。
- `platform_spec.lua` → 平台驱动契约 + 向后兼容标志。
- `ue_api_spec.lua` → `ue` 公共表/函数冻结。
- `ue_config_spec.lua` → `ue.config` schema 默认值/override/reset。
- `ue_cdb_spec.lua` → `ue.cdb.json/paths/shaders` 行为。
- `dap_spec.lua` → `ue.dap.platforms` 注册 + 各平台 `attach`/`launch` 导出。
- `utils_spec.lua` → `utils.code_search`/`ue_goto`/`log`/`ue_paths` 加载与关键导出。
- 理由：每个文件对应 spec 中一组 Requirement，便于审查覆盖完整性。

### 决策 6：迁移而非删除旧脚本

- `headless_smoke.lua` 的断言迁入 `tests/cases/*_spec.lua`；旧文件保留为兼容入口（可继续直接 `nvim -l`），避免破坏既有调用与 muscle memory。
- `scripts/test_*.lua`（`ue_goto`）：在 `tests/run.lua` 中以「旁路调度」方式可选执行（默认纳入能在纯 headless 跑通的子集，需要 clangd/socket 的标注跳过），与 `run_all_tests.ps1` 当前的排除逻辑保持一致。

## Risks / Trade-offs

- [部分模块 require 时有副作用（注册 autocmd/命令/读环境）] → 用例只 require + 断言，不触发真实 IO；对 `ue.setup()` 仅验证命令注册存在性，不进入交互流程。
- [`nvim -l` 与 `--headless -c luafile` 行为差异（如 `vim.g.started_with_stdin` 抑制插件）] → 入口显式设置 `started_with_stdin` 并自举 rtp，沿用 `headless_smoke.lua` 已验证路径。
- [自动发现执行顺序不确定导致用例间状态污染] → 每个用例在 `it` 内自洁；涉及全局状态的（`ue.config`、`ue.dap.platforms`）必须在用例尾部 `reset_for_test`/`_reset_for_test`。
- [覆盖口径是「API 冻结 + 加载冒烟」而非行覆盖] → 文档明确口径；新增功能时要求同步新增 `*_spec.lua`，把覆盖完整性变成开发约定而非工具强制。
- [Windows 路径分隔符/绝对路径写死] → 框架内统一用 `vim.fs.joinpath` 与 `vim.fn.stdpath("config")`，不写死盘符。
- [旧 `run_all_tests.ps1` 与新入口并存造成困惑] → 文档标注新入口为权威，旧脚本为遗留兼容。

## Migration Plan

1. 新增 `tests/harness/init.lua` 框架，先用其重写 `headless_smoke.lua` 等价断言，确认全绿。
2. 逐域补齐 `tests/cases/*_spec.lua`，每加一个域跑一次入口确认。
3. 新增 `tests/run.lua` 自动发现入口与 `scripts/run_regression.ps1` 包装。
4. 写 `docs/` 回归测试文档。
5. 旧 `headless_smoke.lua` 保留；`README`/`docs/TOOLING.md` 指向新入口。
- 回滚：删除 `tests/` 与 `scripts/run_regression.ps1` 即可，无运行时改动，零风险回退。

## Open Questions

- `scripts/test_*.lua`（`ue_goto`）是否全部迁入 `tests/cases/`，还是保持原地并由入口旁路调度？倾向「保持原地 + 旁路调度可跑通子集」，待 tasks 阶段确认具体清单。
- 是否需要一个 `--filter <pattern>` 只跑某域用例（开发中快速迭代）？倾向纳入但作为可选增强，不阻塞首版。
