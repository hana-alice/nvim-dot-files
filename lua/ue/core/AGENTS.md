# lua/ue/core/ — 纯函数核心（fs / proc）

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

从 `ue.lua` 抽出的**纯路径/进程工具**：`fs`（norm/join/relative_to/is_absolute_path/
common_ancestor/...）、`proc`（first_executable）。被全仓复用。

## 专属约定

- **零副作用、零全局状态**：每个函数对相同输入返回相同输出，可直接 headless 断言
  （`tests/cases/fs_proc_spec.lua`）。
- **不改签名、不改可观察行为**：这是被广泛 alias 的底座，行为变更属于 BREAKING——
  改前确认调用点，并升级到全量回归。
- 路径一律 `norm`（折叠反斜杠 + 去尾斜杠），Windows/Unix 统一用 `/`。

## 改动 → 必跑回归

改 `core/**` → `fs_proc`；因被广泛复用，**提交前跑全量**（属「公共 helper」类，按政策升级范围）。

## 先读

`../../../docs/plans/2026-05-06-multi-platform-foundation.md`（Phase B 抽取）。

**治理 spec**：无对应 capability（本目录是被广泛复用的公共 helper 层；
行为契约随调用方的 capability 一起被治理，见 `../AGENTS.md`）。
