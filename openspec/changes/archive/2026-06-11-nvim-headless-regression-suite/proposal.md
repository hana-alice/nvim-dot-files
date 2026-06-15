## Why

当前 nvim 配置（LazyVim + 自研 `ue` 模块 + 平台驱动 + DAP 工具链）的测试散落在 `scripts/` 与 `tools/` 下，命名不统一（`test_*.lua`、`headless_smoke.lua`、`*.ps1`），覆盖面零散，且 `run_all_tests.ps1` 只跑 `ue_goto` 相关子集，无法作为「每次开发完跑一遍」的回归基线。需要一套统一、可重复、能在 headless 模式下全面覆盖配置功能的回归测试套件，让每次改动后一条命令即可验证无回归。

## What Changes

- 新增统一的 headless 测试运行入口（单条命令跑全量），输出 PASS/FAIL 汇总与非零退出码，可直接用于回归与 CI。
- 新增轻量级 headless 测试框架（断言、describe/it 风格分组、错误捕获、汇总报告），所有测试用例复用同一框架，统一约定。
- 新增覆盖以下领域的测试用例集合：
  - **配置加载冒烟**：headless 启动加载 `init.lua` / 关键模块不报错（`ue`、平台驱动、`utils.*`）。
  - **平台驱动契约**：`utils.platform` 四个驱动（windows/macos/linux/stub）接口形状一致。
  - **`ue` 核心**：`ue.core.fs`、`ue.core.proc`、`ue.config` schema、`ue.cdb.*`、`ue.dap.*` 公共 API 冻结清单。
  - **DAP 平台注册**：`ue.dap.platforms` 注册/查找、各平台模块 `attach`/`launch` 导出、命令别名注册。
  - **工具函数**：`utils.code_search`、`utils.ue_goto`、`utils.log` 等可被 require 且关键函数存在。
- 收编现有零散测试：将 `scripts/headless_smoke.lua` 等可复用断言迁移/纳入新框架，旧脚本保留兼容但统一从新入口调度。
- 新增使用文档：如何运行全量回归、如何新增一个测试用例、退出码约定。

## Capabilities

### New Capabilities
- `headless-test-harness`: headless 模式下的测试框架与统一运行入口，提供断言、分组、汇总报告、退出码约定，作为所有回归测试的执行基座。
- `config-regression-suite`: 覆盖 nvim 配置各功能域（配置加载、平台驱动、`ue` 模块、DAP、工具函数）的回归测试用例集合及其组织约定。

### Modified Capabilities
<!-- 无既有 capability 的 spec 级需求发生变化 -->

## Impact

- 新增目录与文件（不改动现有运行时逻辑）：
  - `tests/`（新的测试根目录）：测试框架、用例、运行入口。
  - 统一运行脚本（替代/补充 `scripts/run_all_tests.ps1` 的全量编排）。
  - 回归测试使用文档（`docs/` 下）。
- 受影响代码：仅以「只读 require + 断言」方式访问现有模块（`lua/ue/**`、`lua/utils/**`、`init.lua`、`lua/config/**`、`lua/plugins/**`），不修改其行为。
- 依赖：不引入新第三方依赖，测试框架为纯 Lua 自研，运行依赖本地已安装的 `nvim`（headless）。
- 现有脚本：`scripts/headless_smoke.lua`、`scripts/test_*.lua` 保留，逐步纳入统一入口调度，不破坏旧用法。
