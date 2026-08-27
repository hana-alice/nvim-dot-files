# lua/plugins/ — per-plugin setup

> 继承 `../AGENTS.md`（lua 总规则）。只写增量。

## 用途

每个插件一份 spec（snacks/treesitter/dap/blink/gitsigns/statusline/sidebar/... ），在 LazyVim
之上分层覆盖。LazyVim 当库用，这里是「导入 + 覆写」。

## 专属约定（权威 CONSTRAINTS §一）

- **picker 只用 snacks.picker**，不引 telescope（两套抽象互相打架）。→ P1
- **不做 mason auto-install**：工具链版本钉死，用 winget/scoop。→ P2
- **不集成 copilot/codeium**：推理交给外部 CLI，编辑器保持是编辑器。→ P10
- **不用 which-key 自动 cheatsheet**（泄漏未绑定键位）→ 自渲染 `:UECheatsheet`。→ P9
- 插件接线若为绕上游 bug，进 `../workarounds/`，不 inline。→ P4

## 改动 → 必跑回归

`smoke`（加载冒烟）；若动到命令/键位接线 → 另跑 `commands` `keymaps`。

## 先读

`../../docs/architecture-vs-lazyvim.md`（相对 LazyVim 的增量与「刻意不做」清单）。

**治理 spec**：无对应 capability（本目录行为不由某个 `openspec/specs/` capability 治理）。
