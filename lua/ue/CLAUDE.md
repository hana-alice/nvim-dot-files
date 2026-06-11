# lua/ue/ — UE 引擎中枢

> 继承 `../CLAUDE.md`（lua 总规则）。本文件只写增量。

## 用途

UE5 集成中枢：索引 / CDB / DAP / 命令注册。`ue.lua` 是故意 monolithic 的单文件巨模块；
子能力拆到 `cdb/`（CDB 流水线）、`core/`（fs/proc 纯函数）、`dap/`（调试）、`config.lua`（schema）。

## 专属约定

- **命令在 `ue.setup()` 注册**，且 `ue.setup()` 幂等（`CORE_RT.setup_done` 守卫）——重复调用安全，但
  注意：被 `_reset_for_test` 清空注册表后，再调 `setup()` **不会**重放注册（见 `tests/cases/dap_spec.lua` 的处理）。
- **公共 API 冻结**：`ue.*` 的公共表/函数有回归守护（`tests/cases/ue_api_spec.lua`），删改前先看冻结清单。
- **生成器 skip-if-unchanged**：CDB/PCH/.clangd 写前比对，避免使下游 cache 失效。→ C4.6
- `ue.config` 改动走 `config.lua` schema，勿散落硬编码默认值。

## 改动 → 必跑回归

- 改 `ue.lua` 公共 API / 命令 → `commands` `ue_api` `smoke`
- 改 `config.lua` → `ue_config` `smoke`
- 改 `cdb/**` → `ue_cdb`（另见 `cdb/CLAUDE.md`）
- 改 `dap/**` → `dap` `platform`（另见 `dap/CLAUDE.md`）

## 先读

`../../docs/architecture/overview.md` §1、`../../docs/CONSTRAINTS.md`、`../../docs/plans/`（ADR）。
