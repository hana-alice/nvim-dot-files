# lua/ue/ — UE 引擎中枢

> 继承 `../AGENTS.md`（lua 总规则）。本文件只写增量。

## 用途

UE5 集成中枢：索引 / CDB / DAP / 命令注册。`ue.lua` 是公共 facade 与命令入口，不再承载
target-specific workflow policy；`targets/` 只保留 pure plan/parser/policy contract，`workflows/` 才拥有
设备 I/O、签名、install、launch、rollback 与 UI 决策。子能力拆到 `cdb/`（CDB 流水线）、`core/`
（fs/proc 纯函数）、`dap/`（调试）、`config.lua`（schema）、`project_state.lua` / `file_lock.lua`
（多实例状态边界与跨进程 writer lease）。

## 专属约定

- **命令在 `ue.setup()` 注册**，且 `ue.setup()` 幂等（`CORE_RT.setup_done` 守卫）——重复调用安全，但
  注意：被 `_reset_for_test` 清空注册表后，再调 `setup()` **不会**重放注册（见 `tests/cases/dap_spec.lua` 的处理）。
- **公共 API 冻结**：`ue.*` 的公共表/函数有回归守护（`tests/cases/ue_api_spec.lua`），删改前先看冻结清单。
- **Facade / workflow 边界**：`ue.lua` 只做公共上下文解析、registry 查询与命令入口；`targets/<target>.lua`
  只返回 pure plan / parser / policy contract，不执行命令或 UI；`workflows/<target>/` 才拥有设备选择、
  签名、安装、launch、rollback 与异步状态机。generic 层不得靠 target literal 重建策略。
- **生成器 skip-if-unchanged**：CDB/manifest/PCH 写前比对，避免使下游 cache 失效。→ C4.6
- `ue.config` 改动走 `config.lua` schema，勿散落硬编码默认值。
- **状态 scope 必须显式**：live project/target 归当前 Neovim 进程；持久数据先按 canonical project
  path 分桶，平台相关工件再分 platform；共享集合必须 atomic per-key 或 lease+merge，禁止无锁共享 JSON RMW。
- **破坏性 artifact writer 必须跨进程单写**：进程内 running flag 不足以保护两个 Neovim，
  prepare/CDB/csearch/controlled-index 路径必须持 filesystem lease 到最终 publish 完成。

## 改动 → 必跑回归

- 改 `ue.lua` 公共 API / 命令 / workflow dispatch → `commands` `ue_api` `smoke` `ue_platform_boundary`
- 改 `config.lua` → `ue_config` `smoke`
- 改 `cdb/**` → `ue_cdb`（另见 `cdb/AGENTS.md`）
- 改 `dap/**` → `dap` `platform`（另见 `dap/AGENTS.md`）
- 改 `workflows/**` → `ue_workflows` `ue_platform_boundary` `stability`
- 改 `project_state.lua` / `file_lock.lua` / shared cache writer → `multi_instance_state`

## 先读

`../../docs/architecture/overview.md` §1、`../../docs/CONSTRAINTS.md`、`../../docs/plans/`（ADR）。
