# lua/utils/platform/ — OS 分支唯一收口

> 继承 `../AGENTS.md`（utils）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

平台驱动注册表：`init`（id / is_windows|mac|linux / driver() / 兼容标志）+ 四个具体驱动
`windows` `macos` `linux` `stub`，统一接口。**这是全仓唯一允许做 OS 分支的地方。**

## 专属约定 / 接口契约

- **四驱动同形状**：每个驱动 `id` 与模块名一致，且实现 `shell` / `open_path` / `reveal_file` /
  `cmd_quote` / `default_clangd_candidates` / `default_lldb_dap_paths` / `default_lldb_server_paths`
  （有契约回归 `tests/cases/platform_spec.lua`）。
- **其余代码不做 OS 分支**：读 `platform.is_*` 或调 `platform.driver()`，新增 OS 差异**只在此扩**。
- 向后兼容标志 `is_windows/is_mac/is_linux` 为 boolean，`id` 为非空 string——勿改类型。
- 新增驱动方法 → 四个驱动同步实现（含 `stub`），否则破契约回归。

## 改动 → 必跑回归

`platform`；因被 DAP/CDB 等广泛依赖，**提交前全量**。

## 先读

`../../../docs/plans/2026-05-06-multi-platform-foundation.md`（Phase A 驱动拆分）。
