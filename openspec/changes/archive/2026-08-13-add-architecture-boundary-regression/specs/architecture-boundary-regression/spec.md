# architecture-boundary-regression Specification (DRAFT delta)

> 探索归档草案。落地前须解决 design.md 决策甲/乙/丙。格式沿用
> `openspec/specs/structure-discoverability-regression/spec.md`。

## Purpose

把 `docs/CONSTRAINTS.md` 若干「禁止 import / 边界归属」承诺，从靠人/AI 阅读
文档执行，升级为可执行的回归红线。守护对象是**已经达成的干净依赖边界**——存量
违规近乎为 0，本规格价值在**防回归**：未来某个 agent 改坏边界时让回归变红，与
`structure-discoverability-regression` 同血统。

铁律（来自探索 A1 实读教训）：必须用 treesitter AST 解析 `require(...)` 与函数
调用，**不得用正则/grep**——否则会把 `ue/config.lua`、`ue/cdb/pipeline.lua`、
`ue/dap/platforms.lua` 文件头注释里的 `require("ue")` 字符串误报为违规（这三处
是模范 DI 解耦的文档说明，非违规）。此铁律即仓库约定 C4「AST 优先于 regex」。
只锁 CONSTRAINTS/overview **已明确声明**的边界，不发明新规则。

## Requirements

### Requirement: LSP handler 全局覆盖禁令回归（P3）

回归套件 SHALL 验证没有任何运行时 `.lua` 文件对 `vim.lsp.handlers[...]` 做全局
赋值，`lua/utils/lsp_fallback.lua` 与 `lua/workarounds/clangd/**` 为白名单例外。

#### Scenario: 扫描 vim.lsp.handlers 赋值点

- **WHEN** 边界回归用例运行
- **THEN** 用 treesitter 解析 `lua/**/*.lua`，定位对 `vim.lsp.handlers` 的下标
  **赋值**（assignment_statement 的 LHS，而非读取）
- **AND** 命中文件不在白名单则用例 FAIL 并打印 文件:行
- **AND** 注释、字符串字面量中的同形文本不算违规

### Requirement: OS 分支收口回归（R1 / overview §5）

回归套件 SHALL 验证 OS 分支判定（`vim.fn.has("win32"/"win64"/…)`、
`vim.loop/vim.uv.os_uname`、`jit.os` 比较）只出现在 `lua/utils/platform/**`，
其余代码读 `platform.is_*` 或调驱动。

#### Scenario: 扫描 OS 探测调用点

- **WHEN** 边界回归用例运行
- **THEN** 用 treesitter 定位上述 OS 探测的**代码节点**
- **AND** 出现在 `lua/utils/platform/**` 之外的运行时文件则 FAIL 并打印位置
- **AND** 维护已知例外白名单；白名单内命中打印为信息不 FAIL，白名单外新增命中 FAIL

> 现状例外（探索实测）：`lua/ue/cdb/pipeline.lua` 的 `python_exe()`/`copy_file()`
> 含 `vim.fn.has("win32")`。落地前由 design.md 决策甲决定「收口进驱动」或「列入
> 白名单 + NOTE 注释」。

### Requirement: core 层零上层依赖回归（R5 / overview §1）

回归套件 SHALL 验证 `lua/ue/core/**` 不在 load 时 `require` 任何上层模块
（`ue`、`ue.*`〔除 `ue.core.*`〕、`utils.*`、`snacks` 等），保持「core/ 纯函数、
无副作用」。

#### Scenario: 扫描 core/ 的 require 目标

- **WHEN** 边界回归用例运行
- **THEN** 用 treesitter 提取 `lua/ue/core/**` 每文件的 `require("…")` 字面量目标
- **AND** 目标前缀不在允许集 `{ "ue.core.", "bit", 标准库 }` 则 FAIL 并打印
  文件 → 违规目标
- **AND** 仅统计 string-literal 形参的 require；动态 require 与注释忽略

### Requirement: DI 解耦 seam 正向锚定

回归套件 SHALL 验证 `ue/config.lua`、`ue/cdb/pipeline.lua`、`ue/dap/platforms.lua`
保持「不在 load 时反向 `require("ue")`」契约（通过 literal defaults / `set_runtime`
注入 / `register_*` 注册表解耦）。

#### Scenario: 解耦模块不得 load-time require 中枢

- **WHEN** 边界回归用例运行
- **THEN** 对这三个文件，用 treesitter 确认无 chunk 顶层对 `"ue"` 的 `require`
- **AND** 函数体内 `pcall(require, "ue.config")` 一类同层、被保护的调用允许存在
- **AND** 出现顶层 `require("ue")` 则 FAIL，提示「应改用 set_runtime / register_*
  注入，见文件头 design notes」

### Requirement: 边界规则表与文档同源

回归套件维护的边界规则表 SHALL 与 `docs/CONSTRAINTS.md` 对应条目交叉引用，任一
增删须同步两处，防止 spec 与文档漂移。

#### Scenario: 规则表可发现性

- **WHEN** 边界回归用例运行
- **THEN** spec/用例的规则常量表含指回 CONSTRAINTS 条目号（P3/R1/R5）的注释
- **AND** `docs/CONSTRAINTS.md` 含可被发现的「架构边界回归」条目（如 C9）指向本
  spec 与 `tests/cases/boundaries_spec.lua`
