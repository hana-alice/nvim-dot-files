# lua/ue/index/ — clangd 离线索引子系统（前 ue.lua INDEX_FN/INDEX_RT）

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。
> 来历：F1 split phase-1（health-check 2026-07）——从 10k 行 ue.lua 机械切出的
> 2005–3302 index 块。**行为零变化**是本次切分的硬约束。

## 用途

current / hot / full 三相 clangd 离线索引：模块记录与 tier（`_state`）、
subset CDB + partition + phase build 调度（`_build`）、clangd 重启 /
active index promote / `.clangd` 双写同步（`_clangd`）。

## 结构契约

- `init.lua` 是唯一 require 入口；子模块是 loader 风格
  `return function(M, core)`——共享 `core.h`（helpers）/ `core.RT`（运行时）/
  `core.deps`（ue.lua 注入的闭包），不引全局。
- **`M.setup(deps)` 必须先于任何索引操作**（ue.lua 在原块位置调用）。deps 是
  对 ue.lua chunk-local 的 late-bound 闭包（scope resolvers / status_root_key /
  *_index_dirty / statusline 刷新 / read_all / write_all / core_rt）。新增依赖走 deps，
  不得反向 `require("ue")`（会循环）。
- `M._rt` 与 ue.lua 的 `INDEX_RT` 是**同一张表**（活引用）；:UESetProject
  清理、status cache 直接改它。别做防御性拷贝。
- 加载顺序 `_state → _clangd → _build`：`core.h.*` 在 `_state` 里定义，
  兄弟模块顶部 alias。新 helper 先落 `_state` 再消费。

## 宪法级坑（权威在 ../../../docs/CONSTRAINTS.md）

- `.clangd` 必须 engine + 引擎树外 project root **双写**（K41）。
- 索引 mtime 必须 ≥ compile_commands.json mtime 才可 attach（ghost 跳转）。
- partition 与 pipeline 串行（2026-06-25 撕裂）；build_phase 单 job（RT.job）。

## 改动 → 必跑回归

改 `index/**` → `ue_api` `ue_cdb` `smoke`；跨 ue.lua 接缝（setup deps /
re-export）→ 提交前全量。

## 先读

`../../../docs/health-check-2026-07.md`（F1 切分大纲）、
`../../../docs/architecture/overview.md`。
