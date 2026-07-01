# lua/ue/cdb/ — compile_commands.json 流水线

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

把 UE 编译参数加工成 clangd 能用的 `compile_commands.json`：
`json`（条目模板/program 提取）、`paths`（targets/candidates）、`shaders`（.usf/.ush 增广）、
`pipeline`（slim/裁剪）、`header_inject` / `pch_fi_inject`（.h 反查 + force-include）、`shards`。

## 专属约定

- **纯函数优先**：`template_entry` / `program` / `targets` / `augment` / `make_entry` 等是纯函数，
  有行为回归（`tests/cases/ue_cdb_spec.lua`）——改契约前先看断言。
- **skip-if-unchanged 是硬约定**：任何生成/裁剪写盘前比对，未变更不写（保护 PCH / clangd cache）。→ C4.6
- `.h` CDB inject 的双 donor 路径与 8 个坑见 `../../../docs/plans/2026-05-08-h-inject-cdb.md`（权威）。
- 子进程调用走 `ue/core/proc` 与 platform 驱动，不直接拼 OS 专属命令。

## 改动 → 必跑回归

改 `cdb/**` → `ue_cdb`；若动到被 `ue.lua` 引用的公共面 → 另跑 `ue_api` `smoke`。

## 先读

`../../../docs/plans/2026-05-07-cdb-pipeline-split.md`、`2026-05-08-h-inject-cdb.md`。
