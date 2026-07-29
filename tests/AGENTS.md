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

| 改动位置 | 最小必跑 filter |
|---|---|
| `lua/config/keymaps.lua` / 命令定义 | `keymaps` `commands` |
| `lua/utils/android_device.lua` / Android ADB device 路由 | `android_device` `dap` `ue_context` |
| `lua/ue/config.lua`（schema） | `ue_config` `smoke` |
| `lua/ue.lua` 项目选择 / context 解析 | `ue_project_context` `ue_api` `smoke` |
| `lua/ue/cdb/**` | `ue_cdb` |
| `lua/ue/dap/**` / `lua/utils/platform/**` | `dap` `platform` |
| `lua/utils/ue_goto/**` / `code_search/**` / `ue_paths.lua` | `ue_goto_behavior` `ue_paths` `utils` |
| `lua/config/options.lua` / `autocmds.lua` | `options` `autocmds` |
| `lua/theme.lua` / `lua/highlights.lua` / `colors/**` | `theme` `smoke` |
| `lua/utils/cheatsheet.lua` / `docs/ue_lazyvim_cheatsheet.md` | `cheatsheet` |
| `lua/utils/stall_probe.lua` | `stall_probe` |
| `lua/workarounds/**` | `workarounds` `smoke` |
| 文档 / 规则 / 知识库结构 | `structure` |
| **跨子系统 / 公共 helper / 重构 / 拿不准** | **全量（不带 filter）** |

**升级原则**：① 提交/合并前必跑**全量**；② 影响面不确定就升级到全量，**不猜窄 filter**。

## 怎么加用例

1. `cases/<域>_spec.lua`（必须 `_spec.lua` 结尾，自动发现）。
2. 顶部 `local t = require("tests.harness"); t.bootstrap()`。
3. `describe`/`it` + `assert_*` 组织。详见 `../docs/testing-regression.md`。
4. **新增功能必须补对应用例**；冻结清单类（`commands_spec` 的 `UE_COMMANDS`）随命令变化同步。

## 先读

`../docs/testing-regression.md`（权威）、根 `AGENTS.md` 的 Definition of Done。
