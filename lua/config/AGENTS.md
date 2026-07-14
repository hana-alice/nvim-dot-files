# lua/config/ — 配置层（keymaps / options / autocmds / lazy）

> 继承 `../AGENTS.md`（lua 总规则）。只写增量。

## 用途

LazyVim 约定的配置入口：`options`（缩进/行号/cindent/filetype）、`keymaps`（DAP 功能键/leader/Win 粘贴）、
`autocmds`（混行尾 reload / commentstring 回退）、`lazy`（bootstrap）、`neovide`/`windows`/`snacks_global`。

## 专属约定

- **不在 `init.lua` 重复 require** `options`/`autocmds`/`keymaps`：LazyVim 自动加载
  （options 在 lazy.setup 前、autocmds+keymaps 在 VeryLazy），重复 require 会双执行。→ P15
- **启动顺序固定**，改动前理解依赖链。→ C3（见 `../../docs/CONSTRAINTS.md §三 C3` 与 `../../init.lua`）
- **DAP F-key 四模式绑定**（n/i/t/v），否则 dap-repl 里打出字面 `<F5>`。→ K6
- keymap 有回归（`tests/cases/keymaps_spec.lua`）：headless 下需先设 leader + `ue.setup()` + `dofile(keymaps)` 才生效。
- 新命令需同步 `tests/cases/commands_spec.lua` 的冻结清单。

## 改动 → 必跑回归

- 改 `keymaps.lua` / 命令 → `keymaps` `commands`
- 改 `options.lua` / `autocmds.lua` → `options` `autocmds`

## 先读

`../../docs/CONSTRAINTS.md §三 C3`、`../../init.lua`、`../../docs/testing-regression.md`。
