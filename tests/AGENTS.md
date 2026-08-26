# tests/ — headless 回归套件

> 继承 `../AGENTS.md`（根强制入口）。本目录承载「改动后回归」纪律的**速查映射**。
> 权威操作细节在 `../docs/testing-regression.md`；完成的硬标准在根 `AGENTS.md` DoD。

## 用途

纯 Lua headless 回归框架：`run.lua`（统一入口，自动发现 `cases/*_spec.lua`）、
`harness/init.lua`（断言 + describe/it + 报告 + 退出码）、`cases/*_spec.lua`（各域用例）。

## 怎么跑

```
nvim --headless -l tests/run.lua            # 全量
nvim --headless -l tests/run.lua <filter>   # 只跑文件名含 <filter> 的 *_spec.lua
pwsh -File scripts/run_regression.ps1       # 本机一键（转发 + 退出码）
```

退出码：0 全绿 / 1 任意失败。带 filter 时不触发 legacy 旁路。

## 改动 → 必跑 spec 范围（CHANGE-TO-FILTER MAP）

> 这是「分范围回归」的速查表。最小必跑范围如下；与 `../docs/testing-regression.md` 同步。
> **同源对齐**：本表的 filter 列与 `../memory/project_overview.md` 子系统速查表的「治理 spec」列
> 指向同一改动分类——找 filter 看本表，找治理该改动的 spec 看那张表；任一侧新增/重命名需两处
> 同步（`capability 覆盖映射回归` 守护两侧名称可解析）。

| 改动位置 | 最小必跑 filter |
|---|---|
| `lua/config/keymaps.lua` / 命令定义 | `keymaps` `commands` |
| `lua/utils/window_title.lua` | `window_title` `keymaps` `commands` `cheatsheet` |
| `lua/utils/android_device.lua` / Android ADB device 路由 | `android_device` `dap` `ue_context` |
| `lua/ue/config.lua`（schema） | `ue_config` `smoke` |
| `lua/ue.lua` 项目选择 / context 解析 / workflow dispatch | `ue_project_context` `ue_api` `smoke` `ue_platform_boundary` |
| `lua/ue/project_state.lua` / `lua/ue/file_lock.lua` / 共享持久状态 | `multi_instance_state` |
| `lua/ue/cdb/**` | `ue_cdb` |
| `lua/ue/dap/**` / `lua/utils/platform/**` | `dap` `platform` `ue_platform_boundary` |
| `lua/ue/index/**` / `lua/ue/clangd_commands.lua` / controlled CDB generators | `index_generation` `cpp_semantic_index` `clangd_commands` `ue_api` `ue_platform_boundary` |
| `lua/ue/targets/**` / `lua/ue/workflows/**` / `lua/ue/target_tasks.lua` | `ue_target_drivers` `ue_target_integration` `ue_target_tasks` `ue_workflows` `ue_platform_boundary` `platform` `commands` `stability` |
| `lua/utils/ue_goto/**` / C++ `gd` / semantic sidecar | `cpp_semantic_context` `cpp_semantic_client` `cpp_semantic_sidecar` `ue_goto_behavior` `utils` `ue_platform_boundary` |
| `lua/utils/code_search/**` / `ue_paths.lua` | `ue_goto_behavior` `ue_paths` `utils` `ue_platform_boundary` |
| `lua/config/options.lua` / `autocmds.lua` | `options` `autocmds` |
| `lua/theme.lua` / `lua/highlights.lua` / `colors/**` | `theme` `smoke` |
| `lua/utils/cheatsheet.lua` / `docs/ue_lazyvim_cheatsheet.md` | `cheatsheet` |
| `lua/utils/stall_probe.lua` | `stall_probe` |
| `lua/config/ui_responsiveness.lua` / `lua/ue/clangd_jobs.lua` / clangd `-j` / 主循环余量 | `ui_responsiveness` `core_health` `ue_api` `stability` |
| `lua/utils/core_health*.lua` / `scripts/nvim_core_health.lua` | `core_health` |
| `lua/workarounds/**` | `workarounds` `smoke` |
| `lua/ue.lua` façade / workflow 边界 | `ue_platform_boundary` `structure` |
| 文档 / 规则 / 知识库 / `openspec/specs/**` 结构 | `structure` |
| **跨子系统 / 公共 helper / 重构 / 拿不准** | **全量（不带 filter）** |

**升级原则**：① 提交/合并前必跑**全量**；② 影响面不确定就升级到全量，**不猜窄 filter**；
③ **全量回归存在任何 FAIL 时，先处置该失败（修复 / 立 change / 记录不处理理由），再推进无关新工作**；
④ 宿主（host）相关失败按**宿主能力守卫**用例（不具备该能力的宿主不执行该断言，或改断其 fail-closed
语义），**禁止注入假可执行文件/假宿主让断言「碰巧通过」**。

## 怎么加用例

1. `cases/<域>_spec.lua`（必须 `_spec.lua` 结尾，自动发现）。
2. 顶部 `local t = require("tests.harness"); t.bootstrap()`。
3. `describe`/`it` + `assert_*` 组织。详见 `../docs/testing-regression.md`。
4. **新增功能必须补对应用例**；冻结清单类（`commands_spec` 的 `UE_COMMANDS`）随命令变化同步。

## 先读

`../docs/testing-regression.md`（权威）、根 `AGENTS.md` 的 Definition of Done、
`../openspec/specs/headless-test-harness/spec.md`、`../openspec/specs/test-regression-policy/spec.md`、
`../openspec/specs/structure-discoverability-regression/spec.md`、
`../openspec/specs/config-regression-suite/spec.md`（治理本目录的 capability）。
