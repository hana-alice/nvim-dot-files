# lua/trouble/ — 自定义 trouble source

> 继承 `../AGENTS.md`（lua 总规则）。只写增量。

## 用途

trouble.nvim 的自定义 source（`sources/ue_sidebar.lua`），把 UE sidebar 视图接进 trouble。

## 专属约定

- 只放**我方自定义 source**；不 fork / 不改 trouble 本体（本体走插件管理）。
- source 接口遵循 trouble 的 source 协议；新增 source 放 `sources/<name>.lua`。
- 若为绕 trouble 上游 bug，进 `../workarounds/`，不在此 inline。→ P4

## 改动 → 必跑回归

`smoke`（加载冒烟）。

## 先读

`../utils/sidebar.lua`（sidebar 实现）、`../../docs/architecture/overview.md`。

**治理 spec**：无对应 capability（本目录行为不由某个 `openspec/specs/` capability 治理）。
