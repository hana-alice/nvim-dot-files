# lua/workarounds/ — 上游 bug 隔离补丁注册表

> 继承 `../AGENTS.md`（lua 总规则）。只写增量。

## 用途

物理隔离的第三方 plugin / 上游 bug 补丁，按 `<scope>/<name>.lua` 组织，带可解析 frontmatter，
经 registry 发现 + `:WorkaroundList` / `:WorkaroundStatus` / `:WorkaroundEnable/Disable` 管理。

## 专属约定（权威 CONSTRAINTS C2 + README/TEMPLATE）

- **任何「因别人的 bug 才存在」的补丁必须进这里**，不写 inline monkey-patch。→ P4
- **frontmatter 必填**：`name` / `scope` / `issue` / `symptom` / `introduced` /
  `removal_condition` / `owner` / `enabled`；至少导出幂等 `M.apply()`，可选 `M.disable()`。
- **何时不该隔离**：修复本身是正解（非 workaround）放主逻辑配注释；用户明确「原地改」inline + `-- NOTE`。不确定就隔离。
- `name` 必须与模块路径一致（`<scope>.<name>`），否则 registry 告警。
- 有完整性回归（`tests/cases/workarounds_spec.lua`）：发现数 ≥ 文件数、无 error、frontmatter 齐全。

## 改动 → 必跑回归

`workarounds` `smoke`；新增 workaround 同步在 `../../docs/CONSTRAINTS.md §二` 加一行。

## 先读

`README.md`、`TEMPLATE.lua`（同目录）、`../../docs/CONSTRAINTS.md §三 C2`。
