# lua/ue/core/ — 无状态核心（fs / proc / scan_roots）

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

从 `ue.lua` 抽出的**无状态基础能力**：`fs`（norm/join/relative_to/is_absolute_path/
common_ancestor/...）、`proc`（first_executable）、`scan_roots`（从 UE 构建元数据推导项目
扫描根）。被全仓复用。

## 专属约定

- **零全局状态、无隐藏依赖**：不持有模块级可变状态、不回读 `ue.lua`；需要的策略输入
  （如 excludes 清单）必须由调用方**显式传参**。缓存与失效属于调用方（`ue.lua`）职责。
- `fs`/`proc` 是**纯函数**（同输入同输出）；`scan_roots` 读文件系统，因此以
  tempdir fixture 断言（`tests/cases/ue_api_spec.lua` 的扫描根用例），仍要求
  「同一磁盘状态 → 同一结果」的确定性。
- **不改签名、不改可观察行为**：这是被广泛 alias 的底座，行为变更属于 BREAKING——
  改前确认调用点，并升级到全量回归。
- 路径一律 `norm`（折叠反斜杠 + 去尾斜杠），Windows/Unix 统一用 `/`。

## 改动 → 必跑回归

改 `core/**` → `fs_proc`；改 `scan_roots` 另跑 `ue_api`（扫描根用例）+ `csearch_build_guard`。
因被广泛复用，**提交前跑全量**（属「公共 helper」类，按政策升级范围）。

## 先读

`../../../docs/plans/2026-05-06-multi-platform-foundation.md`（Phase B 抽取）。

**治理 spec**：`../../../openspec/specs/project-scan-root-discovery/spec.md`（`scan_roots`）。
`fs`/`proc` 无对应 capability——它们的行为契约随调用方的 capability 一起被治理，见 `../AGENTS.md`。
