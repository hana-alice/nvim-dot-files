# Neovim + LazyVim Development Handbook

> Vim fundamentals → LazyVim workflows → UE / Android DAP, with the keymap
> conventions used in **this** config.

**Two surfaces, one source of truth:**

- 🪟 **Floating cheatsheet** — `<leader>?` / `:UECheatsheet` (searchable, classified cards).
- 📄 **This document** — `:UECheatsheetEdit`, the full reference.

Both are tested: `tests/cases/cheatsheet_spec.lua` fails if a command listed
here or in `lua/utils/cheatsheet.lua` no longer exists in `lua/`, or if the two
surfaces drift apart.

---

## Contents

- [🚦 Start here](#-start-here-the-8-keys-you-must-know)
- [📐 Keymap conventions](#-keymap-conventions-this-config)
- [⌨️ Vim fundamentals](#️-vim-fundamentals--modes)
- [🧭 LSP navigation](#-lsp-navigation)
- [🔍 Picker / search](#-picker--search-snacks)
- [🩺 Trouble / diagnostics](#-trouble--quickfix--diagnostics)
- [🗂️ Sidebar / buffers / windows](#️-left-sidebar--workbench)
- [💻 Terminal](#-terminal--shell)
- [🌳 Git](#-git)
- [🎨 UI / toggles](#-ui--toggles)
- [🪟 Windows-only](#-windows-only)
- [🎮 UE workflow](#-ue-workflow)
- [⏵ Background tasks](#-background-tasks-list--stop-any-job)
- [🐞 DAP debugging](#-dap--unified-uedap-commands)
- [📝 Logs / workarounds / markdown](#-logs--workarounds)

---

## 🔄 How this document is maintained

This file is **derived from code**. After editing any keymap or command:

1. Re-scan the keymap-bearing files:
   - `lua/config/keymaps.lua` — the bulk of `<leader>` and DAP bindings
   - `lua/config/windows.lua` — `<leader>E / oe / tc / tp / te`
   - `lua/plugins/*.lua` — every `keys = { ... }` block
   - `lua/ue.lua` — every `nvim_create_user_command("UE…")`
2. Verify command existence (a key calling `<cmd>UEFoo<cr>` is dead if `UEFoo`
   is never created):

   ```bash
   grep -rE 'create_user_command\("(\w+)"' lua | sed -E 's/.*"(\w+)".*/\1/' | sort -u
   ```
3. Update **both** this file **and** `lua/utils/cheatsheet.lua` — they are two
   surfaces over the same data.
4. Run the guard: `nvim --headless -l tests/run.lua cheatsheet`.

---

## 🚦 Start Here (the 8 keys you must know)

- `Space`                 → `<leader>`
- `<leader>sk`            → search keymaps (best discovery)
- `<leader>sh`            → search help
- `<leader><space>`       → find files (workspace-aware)
- `<leader>/`             → grep project (Engine + Project)
- `gd` / `gr`             → goto definition / references
- `u` / `<C-r>`           → undo / redo
- `.`                     → repeat last change

---

## 📐 Keymap Conventions (this config)

The keymap surface follows a few rules so muscle memory stays cheap:

1. **LazyVim built-ins win ties.** When a custom map duplicates a stock
   LazyVim keybind, the custom one is removed. Example: terminal toggle
   is `<C-/>` (built-in), not `<leader>tt`.
2. **Avoid `<leader>` + mixed-case two-letter combos** (e.g. `<leader>fE`,
   `<leader>gA`) where possible — they kill muscle memory. Existing ones
   are kept for backwards compat but new keys should be lowercase pairs
   or single-letter under a clear prefix.
3. **Prefix groups:** `b` buffer, `c` code/LSP, `d` debug/DAP, `f` files,
   `g` git/goto, `s` search, `t` terminal, `u` UI **and** UE-runtime,
   `v` left-sidebar **v**iews, `w` window, `x` trouble/diagnostics.
4. **`<leader>u…` is shared** between LazyVim toggles and UE runtime
   commands. UE wins via `nowait=true` after VeryLazy.

If you hit a duplicate or a key that doesn't follow these rules, fix it
and update **both** this doc and `lua/utils/cheatsheet.lua`.

---

## ⌨️ Vim Fundamentals — Modes

| Mode     | Enter              | Purpose                       |
|----------|--------------------|-------------------------------|
| Normal   | `<Esc>`            | Navigate, delete, copy, jump  |
| Insert   | `i` `a` `o` etc    | Type text                     |
| Visual   | `v` `V` `<C-v>`    | Select regions                |
| Command  | `:`                | Ex commands (`:w` `:q` `:s`)  |
| Terminal | `<C-/>` toggle     | Shell input, `<Esc>` to exit  |

Common insert-entry pairs: `i` / `I` insert before the cursor / at line start;
`a` / `A` insert after the cursor / at line end. In the floating cheatsheet,
search `aA` to find that pair directly.

## Vim Fundamentals — Motions

| Key                    | Action                              |
|------------------------|-------------------------------------|
| `h` `j` `k` `l`       | Left / Down / Up / Right            |
| `w` / `W`              | Next word / WORD start              |
| `b` / `B`              | Previous word / WORD start          |
| `e` / `E`              | End of word / WORD                  |
| `0` / `^` / `$`        | Line start / first char / line end  |
| `gg` / `G`             | File start / file end               |
| `42G` / `:42`          | Go to line 42                       |
| `{` / `}`              | Previous / next paragraph           |
| `(` / `)`              | Previous / next sentence            |
| `%`                    | Jump to matching bracket/tag        |
| `f{c}` / `F{c}`       | Find char forward / backward        |
| `t{c}` / `T{c}`       | Till char forward / backward        |
| `;` / `,`              | Repeat f/F/t/T forward / backward   |
| `<C-d>` / `<C-u>`     | Half page down / up                 |
| `<C-f>` / `<C-b>`     | Full page down / up                 |
| `H` / `M` / `L`       | Screen top / middle / bottom        |
| `zz` / `zt` / `zb`    | Center / top / bottom cursor line   |
| `<C-o>` / `<C-i>`     | Jump back / forward in jump list    |
| `[c`                   | Jump up to treesitter-context       |

## Vim Fundamentals — Editing

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `i` / `a`        | Insert before / after cursor            |
| `I` / `A`        | Insert at line start / end              |
| `o` / `O`        | New line below / above                  |
| `x` / `X`        | Delete char forward / backward          |
| `r{c}` / `R`     | Replace char / enter replace mode       |
| `s` / `S`        | Substitute char / line                  |
| `c{motion}`      | Change (delete + insert)                |
| `cc` / `C`       | Change whole line / to end              |
| `d{motion}`      | Delete                                  |
| `dd` / `D`       | Delete whole line / to end              |
| `y{motion}`      | Yank (copy)                             |
| `yy` / `Y`       | Yank whole line                         |
| `p` / `P`        | Paste after / before                    |
| `J`              | Join line below                         |
| `~`              | Toggle case                             |
| `gu` / `gU`      | Lowercase / uppercase (+ motion)        |
| `>>` / `<<`      | Indent / unindent                       |
| `<A-j>` / `<A-k>`| Move line / selection up / down         |
| `.`              | Repeat last change                      |
| `u` / `<C-r>`    | Undo / redo                             |
| `<C-s>`          | Save file                               |

## Vim Fundamentals — Text Objects

Use with `c`, `d`, `y`, `v`: `{operator}{a/i}{object}`

| Object           | Description                             |
|------------------|-----------------------------------------|
| `iw` / `aw`      | Inner / a word                          |
| `iW` / `aW`      | Inner / a WORD                          |
| `is` / `as`      | Inner / a sentence                      |
| `ip` / `ap`      | Inner / a paragraph                     |
| `i"` / `a"`      | Inner / a double-quoted string          |
| `i'` / `a'`      | Inner / a single-quoted string          |
| `i)` / `a)`      | Inner / a parenthesized block           |
| `i]` / `a]`      | Inner / a bracketed block               |
| `i}` / `a}`      | Inner / a braced block                  |
| `it` / `at`      | Inner / a tag block (HTML/XML)          |
| `igc` / `agc`    | Inner / a comment block                 |

## Vim Fundamentals — Visual Mode

| Key                     | Action                             |
|-------------------------|------------------------------------|
| `v`                     | Character-wise visual              |
| `V`                     | Line-wise visual                   |
| `<C-v>`                 | Block visual (column select)       |
| `gv`                    | Reselect last visual               |
| `o`                     | Jump to other end of selection     |
| `>` / `<`               | Indent / unindent selection        |
| `=`                     | Auto-indent selection              |
| `:'<,'>s/old/new/g`     | Substitute in visual selection     |

## Vim Fundamentals — Search & Replace

| Key                     | Action                             |
|-------------------------|------------------------------------|
| `/{pat}` / `?{pat}`     | Search forward / backward          |
| `n` / `N`               | Next / previous match              |
| `*` / `#`               | Search word under cursor fwd / bwd |
| `g*` / `g#`             | Same but partial-match             |
| `:s/old/new/g`          | Replace in current line            |
| `:%s/old/new/gc`        | Replace all in file with confirm   |
| `:%s/\<Name\>/New/gc`   | Replace exact word                 |
| `<leader>sr`            | Cross-file find/replace tool       |
| `:noh`                  | Clear search highlight             |

## Vim Fundamentals — Marks & Jumps

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `m{a-z}`         | Set local mark                          |
| `m{A-Z}`         | Set global mark (cross-file)            |
| `` `{mark} ``    | Jump to mark (exact position)           |
| `'{mark}`        | Jump to mark (line start)               |
| `` `` ``         | Jump to last position before jump       |
| `<C-o>` / `<C-i>`| Jump back / forward in jump list        |
| `gi`             | Go to last insert position and insert   |
| `gv`             | Reselect last visual selection          |
| `:marks`         | List marks                              |
| `:jumps`         | List jump history                       |

## Vim Fundamentals — Registers & Macros

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `"{reg}y`        | Yank into register                      |
| `"{reg}p`        | Paste from register                     |
| `"0p`            | Paste last yank (not delete)            |
| `"+y` / `"+p`    | System clipboard yank / paste           |
| `"_d`            | Delete without polluting register       |
| `:reg`           | Show all registers                      |
| `q{a-z}`         | Start recording macro                   |
| `q`              | Stop recording                          |
| `@{a-z}`         | Play macro                              |
| `@@`             | Repeat last macro                       |
| `{n}@{a-z}`      | Play macro N times                      |

SSH / Zellij TUI 会强制用 OSC 52 把 `y` / `"+y` 穿透到宿主终端剪贴板；即使持久 Zellij session
没有 `SSH_TTY`，`ZELLIJ` 也会启用该路径。OSC 52 paste 被刻意禁用，避免终端拒绝剪贴板读取时卡顿；
Windows → 远程 Nvim 请在 insert 模式使用 Rio 的终端粘贴（默认 `<C-S-v>`），由 bracketed paste
直接送入 Nvim。原生 Windows 与 Neovide 保持各自的剪贴板 provider。

## Vim Fundamentals — Folds

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `zc` / `zo`      | Close / open fold                       |
| `za`             | Toggle fold                             |
| `zC` / `zO`      | Close / open recursively                |
| `zA`             | Toggle recursively                      |
| `zM` / `zR`      | Close all / open all                    |
| `zm` / `zr`      | Increase / decrease fold level          |
| `zj` / `zk`      | Next / previous fold                    |
| `zf{motion}`     | Create manual fold                      |
| `zd` / `zE`      | Delete fold / delete all manual folds   |

Reading large files: `zM` to collapse, `zj`/`zk` to jump between
functions, `zo` to open the section you want, `zR` to reset.

## Vim Fundamentals — Misc

| Key                    | Action                              |
|------------------------|-------------------------------------|
| `<C-a>` / `<C-x>`     | Increment / decrement number        |
| `gf`                   | Go to file under cursor             |
| `gx`                   | Open URL under cursor               |
| `ga`                   | Show char code under cursor         |
| `<C-g>`                | Show file info                      |
| `:!{cmd}`              | Run shell command                   |
| `:r !{cmd}`            | Insert shell command output         |
| `ZZ`                   | Save and quit                       |
| `ZQ`                   | Quit without saving                 |

---

## 🧭 LSP Navigation

Source: `lua/plugins/ue.lua` (`gd`, `<leader>ch`),
`lua/config/keymaps.lua` (`gr`, `<C-LeftMouse>`).

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `gd`             | Definition (contextual C++ / non-C++ fallback) |
| `gr`             | References (LSP → GTAGS fallback)       |
| `gD`             | Go to declaration (LazyVim)             |
| `gI`             | Go to implementation (LazyVim)          |
| `gy`             | Go to type definition (LazyVim)         |
| `K`              | Hover documentation (LazyVim)           |
| `gK`             | Signature help (LazyVim)                |
| `<C-k>` (insert) | Signature help in insert mode (LazyVim) |
| `<C-LeftMouse>`  | Smart jump: `gf` if file ref, else `gd` |
| `<leader>ch`     | Switch source / header (clangd, UE)     |
| `<leader>ca`     | Code action (LazyVim)                   |
| `<leader>cr`     | Rename symbol (LazyVim)                 |
| `<leader>cf`     | Format buffer or selection (LazyVim)    |
| `<leader>cd`     | Line diagnostics (LazyVim)              |
| `<leader>cl`     | LSP info (LazyVim)                      |
| `<leader>ss`     | Document symbols (LSP/treesitter)       |
| `<leader>sS`     | Workspace symbols (LSP)                 |
| `<leader>sr`     | Search & replace word in buffer (or sel) |
| `gc` / `gcc`     | Comment operator / current line         |
| `gco` / `gcO`    | Insert comment line below / above       |

C++ `gd` uses compiler identity only. Source files require an active CDB entry and
clangd's exact-cursor USR; headers run in a proven origin TU reconstructed from
compiler-emitted dependency evidence. No symbol cache, arity filter, workspace-symbol,
csearch or GTAGS fallback is allowed to choose a C++ target. A non-resolved semantic
state keeps the cursor in place. Non-C++ files and explicit search/reference commands
retain their existing LSP/csearch/GTAGS behavior.

Status: `:UEDefStatus`. Trace: `:UEDefTrace`. Cancel the current UI action with
`:UEDefCancel`; clear inherited header contexts with `:UEDefContextClear`.

## 🔍 Picker / Search (Snacks)

Source: `lua/plugins/snacks.lua` (`<leader>;` / `fe` / `e` / `/` /
`s*` / `<space>` / `f*` / `uo` / `uO`), `lua/config/keymaps.lua`
(`sx` / `sX` / `sy` / `sY` / `sr` / `ss` / `sS`).

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader><space>`| Find workspace files                    |
| `<leader>;`      | Commands palette                        |
| `<leader>fe`     | File tree browser (snacks explorer)     |
| `<leader>e`      | Yazi (current file)                     |
| `<leader>ff`     | Find project files                      |
| `<leader>fF`     | Find workspace code files (C++/shader)  |
| `<leader>fa`     | Find project code files (C++/shader)    |
| `<leader>fg`     | Find git files (UE-aware)               |
| `<leader>fC`     | Clear file picker history               |
| `<leader>,`      | Buffers (LazyVim)                       |
| `<leader>:`      | Command history (LazyVim)               |
| `<leader>fr/fR`  | Recent files (LazyVim)                  |
| `<leader>/`      | Grep all code (engine + project)        |
| `<leader>sg`     | Grep workspace code (C++/shader)        |
| `<leader>sG`     | Grep workspace all files                |
| `<leader>sw/sW`  | Search current word/selection (LazyVim) |
| `<leader>sy/sY`  | Live grep with current word prefilled   |
| `<leader>sx`     | Grep whole word match                   |
| `<leader>sX`     | Grep case-sensitive                     |
| `<leader>sH`     | Grep history                            |
| `<leader>sC`     | Clear grep/files history                |
| `<leader>sR`     | Resume last picker (LazyVim)            |
| `<leader>s/`     | Resume last grep                        |
| `<leader>sk`     | Keymaps (LazyVim)                       |
| `<leader>sh`     | Help tags (LazyVim)                     |
| `<leader>sm`     | Marks (LazyVim)                         |

### Inside a Snacks Picker

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<C-q>`          | Send results to quickfix (auto sidebar) |
| `<C-Space>`      | Multi-select toggle                     |
| `<C-j>` / `<C-k>`| Down / up                               |
| `<C-d>` / `<C-u>`| Half page down / up                     |
| `<C-f>` / `<C-b>`| Preview scroll down / up                |
| `<C-p>` / `<C-n>`| Prev / next history                     |
| `<C-/>`          | Toggle help inside picker               |
| `<Tab>` / `<S-Tab>` | Toggle focus list ↔ input            |
| `<C-s>`          | Open in split / send selection          |
| `<C-v>`          | Open in vertical split                  |
| `<C-t>`          | Open in new tab                         |
| `<CR>`           | Confirm                                 |
| `<Esc>` / `q`    | Close picker                            |

### Refining a grep — whole-word, case, regex, scope (read this)

**`<leader>/` is csearch-only** (sub-second trigram index; never falls back to
rg). It does **not** use ` -- ` rg flags — instead it has **visual toggles** you
press inside the picker (the active ones show as icons in the title):

| Key | Toggle |
|---|---|
| `<a-r>` / `<a-g>` | regex on/off — default literal shows **L**, regex shows **R** |
| `<a-w>` / `<a-x>` | whole-word — shows **W** |
| `<a-c>` | case-sensitive (default ignore-case) — shows **C** |
| `<a-s>` | restrict to current module/plugin **scope** — shows **S** |

Literal mode is exact: characters such as `.`, `/`, `[`, and `(` are searched
as themselves. A single punctuation character is allowed; a one-character
identifier and a one-character regex stay gated to avoid unbounded result sets.
Results are grouped as `Project` / `Engine` / `Workspace`; the first real hit
shows the relative path and per-file count, and every row previews and opens its
actual match location.

If there's no csearch index, `<leader>/` shows an error telling you to run
`:UEPrepare` (it will NOT silently fall back to a slow rg search).

**`<leader>sg` / `<leader>sG` are the explicit rg entries** — these open a
**live grep** that pipes your input to ripgrep, controlled two ways:

1. **Inline rg flags** — type your pattern, then ` -- ` (space-dash-dash-space),
   then any ripgrep flags. The text before `--` is the pattern, the rest are
   flags:

   | You type in the grep box | Effect |
   |---|---|
   | `FRDGBuilder` | smart-case substring (default) |
   | `FRDGBuilder -- --word-regexp` | whole-word match (capital `W` boundary) |
   | `FRDGBuilder -- -w` | whole-word (short flag) |
   | `FRDGBuilder -- --case-sensitive` | force case-sensitive |
   | `FRDGBuilder -- -s` | case-sensitive (short flag) |
   | `FRDGBuilder -- -w -s` | whole-word **and** case-sensitive |
   | `F.*Builder -- ` | pattern is already regex (rg is regex by default) |
   | `Foo\(` / `a\|b` | escape regex metachars, or use them — rg regex syntax |
   | `foo -- -g '*.cpp'` | restrict to a glob |
   | `foo -- -F` | fixed-string (treat pattern literally, no regex) |

2. **Dedicated launch keys** — start the grep already in that mode:

   | Key | Mode it launches in |
   |---|---|
   | `<leader>sx` | whole-word (`--word-regexp`) grep |
   | `<leader>sX` | case-sensitive grep |
   | `<leader>sw` / `<leader>sW` | grep current word / WORD immediately |
   | `<leader>sy` / `<leader>sY` | live grep with current word **prefilled** (then edit + add `-- flags`) |
   | `<leader>sg` / `<leader>sG` | grep workspace code / all files |

So the answer to "Space `/` then whole-word capital" is: open `<leader>/`, type
the literal pattern, then press `<a-w>` for whole-word and `<a-c>` for
case-sensitive. Inline `--` flags belong only to the explicit rg pickers.

### Picker matcher (this config)

`<leader><leader>` and other pickers share these matcher options
(set in `lua/plugins/snacks.lua`):

- **smart-case**: lowercase query → ignore case; mixed case → exact
- **fzf-style fuzzy**: subsequence match, gap-penalised, boundary
  bonuses (camelCase, path separators, word starts)
- **filename bonus**: filename matches outrank path matches —
  typing `ui` puts `MyUI.cpp` above `src/ui-helpers/foo.cpp`

### Grep Tips

- Default is smart-case; type a capital to force case on that token
- `<leader>sw` searches current word/selection directly
- `<leader>sy` prefills current word into live grep for further editing
- `<leader>sx` for whole-word, `<leader>sX` for case-sensitive
- Inline flags after ` -- `: `Foo -- --word-regexp --case-sensitive`
- In any Snacks picker: `<C-q>` sends results to quickfix (auto-opens sidebar)
- `<C-Space>` to multi-select, then `<C-q>` to pin filtered subset
- After `<C-q>` pin, recover the picker with `<leader>s/`

## 🩺 Trouble / Quickfix / Diagnostics

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>xx`     | Open diagnostics (Trouble, LazyVim)     |
| `<leader>xX`     | Buffer diagnostics (LazyVim)            |
| `<leader>xQ`     | Quickfix list (LazyVim)                 |
| `<leader>xL`     | Location list (LazyVim)                 |
| `[d` / `]d`      | Previous / next diagnostic (LazyVim)    |
| `[e` / `]e`      | Previous / next error (LazyVim)         |
| `[w` / `]w`      | Previous / next warning (LazyVim)       |
| `<leader>cd`     | Line diagnostics (LazyVim)              |
| `:copen` / `:cclose` | Open / close quickfix              |
| `:cnext` / `:cprev` | Navigate quickfix                   |
| `:cdo {cmd}`     | Run cmd on every quickfix entry         |

## 🗂️ Left Sidebar / Workbench

Source: `lua/config/keymaps.lua` (`<leader>v*`).

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>va`     | Sidebar view picker (1-7 / j-k + Enter) |
| `<leader>vv`     | Toggle last sidebar view                |
| `<leader>vg`     | Open / focus CodeDiff review workspace  |
| `<leader>vb`     | Open buffers                            |
| `<leader>vs`     | File symbols                            |
| `<leader>vd`     | Diagnostics                             |
| `<leader>vq`     | Pinned quickfix results                 |
| `<leader>vl`     | Location list                           |
| `<leader>vt`     | TODO / FIXME                            |

The six sidebar views share the same left panel. The Git menu item and
`<leader>vg` open CodeDiff separately; Git is no longer a Trouble sidebar mode.

## Buffers / Windows / Tabs

| Key                   | Action                               |
|-----------------------|--------------------------------------|
| `<S-h>` / `<S-l>`    | Previous / next buffer (LazyVim)     |
| `<leader>bb`          | Switch to other buffer (LazyVim)     |
| `<leader>bn`          | New empty buffer                     |
| `<leader>bd`          | Delete buffer (LazyVim)              |
| `<leader>bo`          | Delete other buffers (LazyVim)       |
| `<leader>bp`          | Toggle pin buffer (LazyVim)          |
| `<leader>bD`          | Delete buffer and window (LazyVim)   |
| `<leader>bc`          | Smart close: window/buffer/float     |
| `<leader>-`           | Horizontal split (LazyVim)           |
| `<leader>\|`          | Vertical split (LazyVim)             |
| `<C-h/j/k/l>`         | Move between windows (LazyVim)       |
| `<leader>wd`          | Delete window (LazyVim)              |
| `<leader>wm`          | Maximize / restore window (LazyVim)  |
| `<leader><tab><tab>`  | New tab (LazyVim)                    |
| `<leader><tab>[/]`    | Previous / next tab (LazyVim)        |
| `<leader><tab>d`      | Close tab (LazyVim)                  |
| `<leader><tab>o`      | Close other tabs (LazyVim)           |

## 💻 Terminal / Shell

Source: `lua/config/windows.lua` (`<leader>tc / tp / te`,
`<Esc>` in terminal mode).

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<C-/>` / `<C-_>`| Toggle root terminal (LazyVim built-in) |
| `<leader>ft`     | Float terminal at root (LazyVim)        |
| `<leader>fT`     | Float terminal at cwd (LazyVim)         |
| `<leader>tc`     | Open bottom term + cd to current file dir |
| `<leader>tp`     | Open bottom term + cd to UE project root  |
| `<leader>te`     | Open bottom term + cd to UE engine root   |
| `<Esc>` (term)   | Exit terminal mode → Normal             |

`<leader>tc/tp/te` differ from `<C-/>`: they spawn a controlled bottom
terminal so the config can inject `cd ...` into it. `<C-/>` is for a
fast scratch shell.

## 🌳 Git

Source: `lua/utils/git_review.lua`, `lua/plugins/codediff.lua`,
`lua/plugins/diffview.lua`, `lua/plugins/neogit.lua`,
`lua/plugins/fugitive.lua`, `lua/plugins/gitsigns.lua`.

**CodeDiff** is the default full-file review workspace: two panes, the complete
file context, and separate Changes / Staged / Conflicts groups. **Diffview**
remains available on demand. **Neogit** handles commit, push/pull, branch, stash,
rebase and reflog; its diff actions use CodeDiff and its pickers use Snacks.
**Fugitive** keeps revision buffers, full-file blame and quickfix history.
**Gitsigns** owns normal editing buffers; CodeDiff owns review-buffer hunk actions.
The default Git keys do not launch Lazygit. The host CLI remains available.

### Cheat-by-scenario

| 你想做什么 | 怎么做 |
|---|---|
| **审阅当前仓库改动** | `<leader>gg`（当前文件所属仓库，回落 cwd）或 `<leader>gG`（cwd 仓库）；`<leader>vg` 是默认审阅别名 |
| **看某个 commit 改了哪些文件 + diff** | `<leader>gc` 选择提交 → CodeDiff；`<leader>gM` 浏览仓库历史 |
| **只看一个具体 hash** | `<leader>gk` → 输入 hash（默认 `HEAD`）；merge commit 明确选择父版本 |
| **单文件随时间的变化轨迹** | `<leader>gm` → CodeDiff 文件历史 |
| **任意两个 ref / 分支间 diff** | `<leader>gr` → `main..feature` 两版本比较，或 `main...feature` merge-base 比较 |
| **沿用熟悉的 Diffview** | `<leader>gv` 打开，`<leader>gV` 关闭；Visual `<leader>gv` 保留选中行历史 |
| **Blame 当前行（GitLens 风格）** | 行尾虚拟文本显示 `author · time · summary`（500ms 延迟）；`:Gitsigns toggle_current_line_blame` 切换 |
| **Blame 整个文件（可滚动）** | `<leader>gB`（fugitive `:Git blame`）→ 在 blame 窗口里 `o` 预览 commit、`<cr>` 打开 |
| **找哪些 commit 修改了某段代码** | `<leader>gh` / `<leader>gH` 搜修改内容（`git log -G` 正则，仓库 / 当前文件）；确认结果进入 CodeDiff |
| **看当前文件历史 → 选 commit 比 diff** | `<leader>gX`（当前文件 vs 选中的 commit） |
| **完整状态面板 / 提交 / push** | `<leader>gn`（Neogit） |

### 全部按键

| Key                | Action                                           | Source |
|--------------------|--------------------------------------------------|--------|
| `]h` / `[h`        | Next / previous hunk in normal editing buffers   | gitsigns |
| `<leader>gb`       | Line history picker; confirm → CodeDiff          | Snacks |
| `<leader>hb`       | Blame current line (popup)                       | gitsigns |
| `<leader>hB`       | Full-file blame                                 | gitsigns |
| `<leader>hp`       | Preview hunk while editing                      | gitsigns |
| `<leader>gB`       | **Full-file blame view (scrollable)**            | fugitive |
| `<leader>gg`       | Review current file repository (fallback: cwd)  | CodeDiff |
| `<leader>gG`       | Review cwd repository                           | CodeDiff |
| `<leader>vg`       | Open / focus review workspace                   | CodeDiff |
| `<leader>gv`       | Diffview: working tree                           | diffview |
| `<leader>gV`       | Diffview: close                                  | diffview |
| `<leader>gm`       | This file history                               | CodeDiff |
| `<leader>gM`       | Repository history                              | CodeDiff |
| `<leader>gv` (v)   | Diffview: selection history                      | diffview |
| `<leader>gr`       | Arbitrary refs / range (prompt)                  | CodeDiff |
| `<leader>gk`       | Single commit (prompt)                           | CodeDiff |
| `<leader>gn`       | **Neogit** status panel (one-stop)               | neogit |
| `<leader>gs`       | Status picker; confirm → CodeDiff               | Snacks |
| `<leader>gc`       | Commits picker; confirm → CodeDiff              | Snacks |
| `<leader>gh`       | Search changed content (`-G` regex)             | Snacks → CodeDiff |
| `<leader>gH`       | Search changed content (`-G`, current file)     | Snacks → CodeDiff |
| `<leader>gx`       | Current file vs selected branch                 | Snacks → CodeDiff |
| `<leader>gX`       | Current file vs selected commit                 | Snacks → CodeDiff |
| `<leader>gC`       | Reflog; opening the list does not checkout      | Neogit |
| `<leader>gA`       | Git actions                                     | Git review router |
| `<leader>g0`       | **Open `:0` (staged) version of current file**   | fugitive |
| `<leader>gl`       | Commits touching this file → quickfix            | fugitive |
| `<leader>gL`       | All commits → quickfix                           | fugitive |

Content search preserves `-G <pattern> --pickaxe-all`; it is not commit-message
`--grep` or occurrence-count `-S` search. File-scoped search follows renames.

### Hunk actions: normal editing and CodeDiff

| Key | Normal editing buffer | CodeDiff review |
|---|---|---|
| `<leader>hs` | Stage current hunk | Stage current hunk in Changes |
| `<leader>hu` | Open staged review to choose what to unstage | Unstage current hunk in Staged |
| `<leader>hr` | Discard current hunk with confirmation | Discard Changes hunk with confirmation |
| `<leader>hS` | Stage current file | Stage / unstage current file |

`hu` means **unstage**, not “undo the last stage action”. Ref/history review is
read-only; actions that do not apply to that comparison are unavailable. These
bindings replace the inherited `<leader>gh*` hunk prefix, leaving `gh/gH` for
content search. A stage action must not implicitly save a dirty buffer.

### Inside CodeDiff

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous hunk, continuing across files |
| `<Tab>` / `<S-Tab>` | Next / previous file |
| `gS` | Switch staged / unstaged view |
| `<localleader>c` | Open Neogit commit flow, then return to review |
| `q` | Close CodeDiff |

Full-file context is shown by default (`side-by-side`, `compact=false`).
For explicit line history, select lines and run `:'<,'>CodeDiff history`.

### Inside Neogit status (`<leader>gn`)

每个动作都是单字母：`s`/`u`/`x` stage/unstage/discard、`c` commit、
`P` push、`p` pull、`b` branch、`Z` stash、`r` rebase、`l` log、`<tab>` 折叠 section、
`?` help、`q`/`<Esc>` 关闭。

### Inside Diffview (on demand)

| Key                  | Action                                  |
|----------------------|-----------------------------------------|
| `<tab>` / `<s-tab>`  | Next / prev file                        |
| `j` / `k` (file panel) | Next / prev entry without opening     |
| `]c` / `[c`          | Next / prev hunk in current file        |
| `]h` / `[h`          | Next / prev hunk, **cross file**        |
| `]x` / `[x`          | Next / prev merge conflict              |
| `<cr>`               | Open file / commit                      |
| `s` (file panel)     | Toggle stage / unstage file             |
| `R` (file panel)     | Refresh files                           |
| `y` (history panel)  | Yank commit hash to system clipboard    |
| `q`                  | Close diffview                          |

For an explicit Diffview ref comparison use `:DiffviewOpen main..feature`;
`<leader>gr` opens the default CodeDiff workflow. Closing either tool does not
close the other tool's independently opened workspace.

### Inline blame (GitLens-style)

Gitsigns shows `<author>, <time> · <summary>` at end of line with 500ms
delay. Toggle: `:Gitsigns toggle_current_line_blame`; `<leader>uG` toggles signs.
Disable blame globally: in
`lua/plugins/gitsigns.lua` set `current_line_blame = false`.

### Progress and responsiveness

Some existing commands, including the retained Diffview and Fugitive entries,
use `lua/utils/async_launcher.lua` through the `git_async` forwarder. Its popup
and progress indicator report startup; pressing `q` hides the indicator without
cancelling the underlying work. Default Git routing lives in `utils.git_review`;
not every Git key uses this launcher.

Scheduling a callback is not proof that the callback or plugin is nonblocking.
Startup, file switching and hunk navigation performance must be measured for the
installed versions and repository; this key reference makes no speed guarantee.

## 🎨 UI / Toggles

Source: `lua/plugins/zen-mode.lua` (`<leader>z`),
`lua/config/keymaps.lua` (`<leader>ut`, `<leader>uC`, `<leader>uW`, `<leader>?`).

Theme picker、命令补全和直接设置统一只暴露以下 6 个 canonical name：
`monokai_ristretto`、`rider-light`、`ubuntu-terminal`、`unokai`、`catppuccin`、
`sonokai-espresso`。最后一项固定加载 `sainnhe/sonokai` 的 Espresso variant，
不会暴露其他 Sonokai variants。

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>ut`     | Theme picker (`:ThemePicker`)           |
| `<leader>uC`     | 同一个受限 theme picker（覆盖上游入口） |
| `:Theme`         | Open theme picker                       |
| `:Theme <name>`  | Set and persist one of the six themes   |
| `<leader>uf`     | Toggle format on save (LazyVim)         |
| `<leader>uF`     | Force format mode (LazyVim)             |
| `<leader>ud`     | Toggle diagnostics (LazyVim)            |
| `<leader>us`     | Toggle spelling (LazyVim)               |
| `<leader>uw`     | Toggle word wrap (LazyVim)              |
| `<leader>uW`     | Name this Neovim/Neovide system window  |
| `:WindowTitle [name]` | Prompt for / directly set the window title |
| `:WindowTitle!` / `:WindowTitleReset` | Restore Neovim's automatic title |
| `<leader>uh`     | Toggle inlay hints (LazyVim)            |
| `<leader>uG`     | Toggle git signs (LazyVim)              |
| `<leader>uT`     | Toggle treesitter (LazyVim)             |
| `<leader>z`      | Zen mode toggle                         |
| `<leader>ur`     | Redraw + clear search highlight (LazyVim) |
| `<leader>un`     | Dismiss notifications (LazyVim)         |
| `<leader>?`      | Open this cheatsheet (`:UECheatsheet`)  |

Note: some `<leader>u…` keys are **overridden** by UE/Android workflow
(`ub` / `ui` / `ul` / `uL` / `uD` / `up` / `ug`) via `nowait=true`
after VeryLazy.

## 🪟 Windows-only

Source: `lua/config/windows.lua`.

| Key                  | Action                                  |
|----------------------|-----------------------------------------|
| `<leader>E`          | Reveal current file in Explorer         |
| `<leader>oe`         | Same as above                           |
| `:RevealInExplorer`  | Direct command                          |
| `:NeovideZoomIn`     | Neovide zoom in                         |
| `:NeovideZoomOut`    | Neovide zoom out                        |
| `:NeovideZoomReset`  | Neovide reset zoom                      |

## Restart Neovim

Source: `lua/utils/restart.lua`, command in `lua/config/keymaps.lua`.

| Key / Command       | Action                                              |
|---------------------|-----------------------------------------------------|
| `<leader>qr`        | Restart Neovim in current cwd (`:confirm qa` first) |
| `:Restart`          | Same                                                |
| `:Restart!`         | Force restart, skip unsaved-buffer prompt (`qa!`)   |
| `:RestartDetect`    | Dry-run: print which client/cmd will be used        |

Cwd is `vim.fn.getcwd()` of the current tab. Client detection order:

1. **Neovide** (`vim.g.neovide` set) → `neovide --multigrid <cwd>`
2. **WezTerm** (`$WEZTERM_PANE` set) → `wezterm cli spawn --cwd <cwd> -- nvim`
3. **Windows fallback** → `cmd /C start "" nvim` (in cwd)
4. **macOS fallback** → `$TERMINAL -e nvim` then `kitty --directory <cwd> nvim`
5. **Linux fallback** → `$TERMINAL` → kitty → alacritty → wezterm → foot → xterm

The new process is spawned **first** so the old one stays alive to
display errors if anything goes wrong. After spawn we issue
`:confirm qa` (or `qa!` with `:Restart!`) so unsaved buffers can be
saved/aborted before the old session exits.

---

## 🩺 Core Functionality Health

| Command | Action |
|---|---|
| `:NvimCoreHealth` | Run the read-only startup/editor/Tree-sitter/search/clangd/UE capability audit asynchronously |

The headless equivalent is
`nvim --headless -l scripts/nvim_core_health.lua [--json] [--filter <prefix>] [--live]`.
`DEGRADED` means deterministic editor checks passed while an external backend
such as csearch or clangd 22.1.x is blocked. See `docs/core-health.md`.

---

## 🎮 UE Workflow

Source: `lua/config/keymaps.lua` (static `<leader>uB / uc / uP`,
runtime `uA / ub / us / uq / ug / ui / ul / uL / uD / up`), `lua/plugins/snacks.lua`
(`<leader>uo / uO`), all `:UE*` user commands in `lua/ue.lua`.

| Key / Command             | Action                              |
|---------------------------|-------------------------------------|
| `<leader>uP`              | `:UESetProject` — set project root  |
| `<leader>uA`              | `:UESetAndroidDevice` — select Android device (name + serial) for this Neovim session |
| `:UESetPlatform`          | Interactive platform+config select  |
| `:UESetPlatform Win64 Development Editor` | Direct set         |
| `<leader>ub`              | `:UEBuild` (platform from `:UESetPlatform`); on macOS, silent stages show a process-tree heartbeat in the same terminal |
| `:UECompileForNvim`       | Compatibility entry: build current target, then delegate to the normal `UEPrepare` path |
| `:UEBuildIOS`             | Build IOS C++ through native macOS UBT; safely reuse unchanged AOT outputs and defer dSYM |
| `:UEIOSSetup`             | Optional explicit rerun of IOS prepared identity/private-key/device setup |
| `:UESetIOSSigningCertificate` | Import this workspace's prepared debug identity when present, otherwise select one; exact name/SHA-1 supported, `!` clears |
| `:UEPackageIOS`           | Reuse existing cooked data, then stage/package IOS; never build, cook, archive, deploy, or run |
| `:UEIOSSymbols`           | Generate the current IOS binary's dSYM on demand and verify Mach-O UUIDs; no ZIP |
| `:UESetIOSDevice`         | Merge live CoreDevice/USB/Wi-Fi candidates and open a picker; saved offline devices are labeled and never auto-substituted |
| `:UEInstallIOS`           | CoreDevice: install current packaged `.app`; pre-iOS17: stream signing/upload/Upgrade progress through prepared `InstallIOSClient.sh`; never uninstall or launch |
| `<leader>us`              | `:UEBuildAndroidSO` — export + execute UBT compile/link actions (no Deploy/Gradle/APK) |
| `<leader>uq`              | `:UEDeployAndroidSO` — strip, push, atomically replace and verify `libUE4.so`; leaves the app stopped |
| `<leader>uB`              | `:UEPrepare`; IOS on macOS also generates its semantic CDB and auto-runs first-use setup |
| `<leader>uc`              | `:UEExportCompileCommands`          |
| `<leader>ul`              | `:UELaunch` (no debugger)           |
| `<leader>ui`              | `:UEInstall` (active Android → `adb install -r`; active IOS → signed staged `.app` in-place update; neither launches) |
| `<leader>ug`              | `:UELogToggle` (toggle app log)     |
| `<leader>uL`              | `:UELogToggle` (alias)              |
| `<leader>uD`              | `:UEDebugLogToggle` (Windows debug log) |
| `<leader>uo`              | UE: files in current module / plugin |
| `<leader>uO`              | UE: grep in current module / plugin  |
| `<leader>up`              | `:UEPaths` (show UE paths)          |
| `<leader>?`               | `:UECheatsheet` (open this cheatsheet) |

Android 选择写入当前 Neovim **进程内**的全局变量
`vim.g.ue_android_device_serial`。APK install、launch、logcat 与 DAP 随后都显式使用
`adb -s <serial>`；切换设备时再次执行 `<leader>uA`。该值既不会跨 Neovim 重启持久化，
也不会影响同时运行的另一个 Neovim 实例。

iOS 首次 `:UEPrepare` 会自动完成原 `:UEIOSSetup` 的职责：读取 `PrepareIOSQADebug.sh` 生成的
`Saved/IOSQADebug/signing.json`，用临时复制的 `/usr/bin/true` 做一次真实 `codesign`（退出时无条件
删除），并在只连接一台可用设备时自动保存 identifier/backend；legacy 设备还会验证 branch 对应
`InstallIOSClient.sh`。`:UEIOSSetup` 保留为显式重跑/诊断入口。证书可被
`security find-identity` 枚举并不代表私钥可用，因此 setup 和后续签名 preflight 都会在克隆/重签大型
app 之前执行这个快速探针；它不读取或保存 keychain 密码。Setup 不会在缺少 prepared manifest 时退回
人工 picker，异步期间切换 project 或 project-state 写入失败也会中止而不是误报 ready。

完整流程是 `:UESetProject <workspace>` 与 `:UESetPlatform IOS` 任意顺序 → `<leader>ub` →
`:UEPrepare` → `<leader>ui`。`UEPrepare` 不触发编译；它依赖前一步 build 的稳定产物，并为 IOS
补充 tuple-scoped semantic CDB 后建立 clangd/CDB/index 环境。若该次 build 早于 Nvim build marker
功能，`UEPrepare` 会从精确匹配 tuple 且 launch product 存在的 UBT `.target` receipt 迁移证据，不要求
重复 build；生成 semantic CDB 时会仅对该子进程跳过工程 Build.cs 的 AOT 副作用。同一 build 已发布且
文件签名未变时，后续 `UEPrepare` 直接复用 semantic source，不再启动 `Build.sh`/UBT。UE 工程的 clangd
LSP 会验证当前 tuple 持久化的 selection/manifest/controlled CDB 与源 CDB 签名；这些工件仍为 ready 时，
重启 Neovim 后直接由原生 `FileType` 事件启动，不要求重复 `UEPrepare`。只有工件缺失、stale 或 tuple/build
evidence 变化时才继续 defer，避免按旧/空 CDB 扫描数千文件；普通非 UE C++ 工程仍按原规则自动启动 clangd。

iOS 签名 identity 也可通过 `:UESetIOSSigningCertificate` 单独设置。无参数时，如果
`PrepareIOSQADebug.sh` 已在标准项目或 `workspace/Source/SampleGame` 布局写入
`Saved/IOSQADebug/signing.json`，命令会先验证 debug/profile 存在性/Bundle/Team 契约，再按 SHA-1 和显示名
精确复验 keychain 并导入；没有 manifest 时才显示异步 picker。也可以显式传入精确证书名或 SHA-1；
选择按 project 保存，`:UESetIOSSigningCertificate!` 清除。manifest 存在但损坏或 stale 时不会回退
到其他证书。纯 `:UEBuildIOS` 在未选证书时仍可 compile/link；`:UEPackageIOS` / `:UEInstallIOS` 必须
精确复验已选 identity，不会使用 keychain 中“第一张有效证书”。设备、artifact、bundle id 与 process
状态保存于 IOS-scoped runtime state，不与 Android 或 Mac target 共用。CoreDevice 日常顺序是
`:UEBuildIOS` → `:UEPackageIOS` → `:UESetIOSDevice` → `:UEInstallIOS` → `:UELaunch`；pre-iOS17 legacy
设备可在 `:UEBuildIOS` 后直接安装当前 tuple app，但必须存在匹配的 `Saved/IOSQADebug/signing.json`
和 `~/Documents/temp/<branch>/InstallIOSClient.sh`。helper 只克隆/重签、封装临时 IPA 并原地更新，
不会修改源 app、卸载旧 app 或启动进程；设备发现和安装都使用持续更新的进度句柄，legacy usbmux
失联会先调用同目录 `ResetIOSUSB.sh` 软件恢复再重新探测；picker 中选择 `saved, offline` 的 USB 设备也会
以该精确 UDID 尝试刷新路由并始终重新探测，不会改选其他设备。目标不在 IOKit、无法物理恢复时只记录
warning；单次重新探测后仍离线便结束当前操作，不会重复弹出相同 picker。legacy `:UELaunch` 会复用 manifest 中的
prepared signed app；若保存的设备不在实时 USB/Wi-Fi/CoreDevice 结果中，会先弹 picker 而不是改选唯一
候选。确认选择后以对应 transport 执行 `ios-deploy --noinstall --justlaunch` 并复查 PID；Nvim 重启后
也不要求重新 package/install，且不会触发 codesign 私钥探测或 DAP。

`:UEBuildIOS` 的第一次构建（或 AOT 输入、工具链、SDK、framework 产物发生变化后）仍执行完整 AOT；
只有输入指纹相同且上次成功构建记录的 framework 路径与内容 hash 全部匹配时，Nvim 才注入
`bSkipAOTProcess=true`。日常构建固定以命令行 INI override 关闭自动 dSYM；需要调试/符号化时再执行
`:UEIOSSymbols`，避免每次编译都支付 `dsymutil` 与 ZIP 的时间和磁盘成本。AOT 输入的 content hash
另有 path/device/inode/size/纳秒 mtime/ctime metadata cache；metadata 全同才复用摘要，任何变化都会
重新 hash，framework output 始终逐个校验。Build.sh 本身始终执行，由 UBT action graph 跳过未变化的
C++ compile/link action；`:UEBuildIOS` 不使用 `-SkipBuild`。

### Less-common UE commands

These exist (`grep create_user_command lua/ue.lua` to verify) but
have no key bound by default:

| Command                | Action                                  |
|------------------------|-----------------------------------------|
| `:UEBuildCsearch`      | Rescan and fully rebuild only csearch; no UBT/CDB/GTAGS |
| `:UEPrepareReindex`    | Normal prepare + forced csearch rebuild |
| `:UEPrepareIncremental`| Append watcher dirty files to csearch only |
| `:UEPrepareSync`       | Synchronous prepare (debug)             |
| `:UEGenerateFromRSP`   | Re-export ccjson from cached `.rsp`     |
| `:UEBuildAndroid`      | Force Android build target              |
| `:UEBuildIOS`          | Build only the IOS target                |
| `:UEIOSSetup`          | Explicitly rerun IOS signing/private-key/device setup |
| `:UESetIOSSigningCertificate` | Select/clear project IOS signing identity |
| `:UECompileForNvim`    | Compatibility: build then normal prepare |
| `:UEPackageIOS`        | Stage/package existing IOS cooked data   |
| `:UEIOSSymbols`        | Generate + UUID-check IOS dSYM on demand |
| `:UESetIOSDevice`      | Select physical IOS device               |
| `:UEInstallIOS`        | Install current tuple's packaged app     |
| `:UEBuildPCH`          | Build PCH only                          |
| `:UEDirtyStatus`       | Show files awaiting reindex             |
| `:UEDirtyClear`        | Clear dirty file set                    |
| `:UEWatchStatus`       | Show file watcher state                 |
| `:UEWatchStop`         | Stop file watcher                       |
| `:UEWatchFlush`        | Flush pending watcher changes           |
| `:UEIndexStatus`       | Show GTAGS index status                 |
| `:UEIndexNow`          | Index current buffer now                |
| `:UEIndexHot`          | Hot-list reindex                        |
| `:UEIndexFull`         | Full GTAGS reindex                      |
| `:UEIndexTimings`      | Last index timings                      |
| `:UECachePaths`        | Show cache directory paths              |
| `:UEClearCache`        | Clear nvim-ue + clangd caches           |
| `:UEClearCache!`       | Above + rm `compile_commands.json` + restart clangd |
| `:UEGrepGroupingToggle`| Toggle grep result grouping             |
| `:UEGrepTraceToggle`   | Toggle grep trace logging               |
| `:UEGrepTraceShow`     | Show last grep trace                    |
| `:UEGrepDiagDump`      | Dump grep diagnostics                   |
| `:UEResetLayout`       | Reset window layout (DAP or default)    |
| `:UESetAndroidPackage` | Set Android attach package name         |
| `:UECheatsheetEdit`    | Edit this markdown file                 |
| `:UEDefStatus`         | Show semantic sidecar + compatibility state |
| `:UEDefTrace`          | Toggle goto-def tracing                 |
| `:UEDefSelfTest`       | Run goto-def self-test                  |
| `:UEDefDiag`           | Goto-def diagnostics dump               |
| `:UEDefReload`         | Reload goto-def module                  |
| `:UEDefCacheClear`     | Clear non-C++ goto-def cache            |
| `:UEDefCancel`         | Cancel current semantic UI action       |
| `:UEDefContextClear`   | Clear inherited header TU contexts      |

Typical first-run workflow (see the README for the full step list):

1. `:UESetProject` and `:UESetPlatform Win64 Development Editor` — either order
2. Confirm both project and target selections
3. Build once for the platform (`<leader>ub` / `:UEBuild`) — `:UEPrepare`
   derives its compile flags from a real platform build
4. `:UEPrepare` — CDB pipeline + csearch index + clangd reload
5. Open code, use `gd` / `gr` / `<leader>ss` / `<leader>/`

## ⏵ Background Tasks (list / stop any job)

Generic, **not UE-specific** — lists and cancels any background job this config
spawns (build terminal, `:UEPrepare` index/ccjson, `:UELaunch` / `:UEInstallAndroid`,
logcat, log streams). Backed by `lua/utils/task_registry.lua`, whose task state is
**derived live** from each job handle (no stored state machine → no cancel/exit
race). Source: `lua/config/keymaps.lua` (`<leader>X*` block), commands in `lua/ue.lua`.

| Key / Command     | Action                                            |
|-------------------|---------------------------------------------------|
| `<leader>X`       | `:Tasks` — list tasks; select one to stop         |
| `<leader>Xs`      | `:TaskStop` — stop one (auto if single, else pick) |
| `<leader>XA`      | `:TaskStopAll` — stop all (confirms first)         |
| `:TaskStop <id>`  | Stop a specific task by id                         |
| statusline `⏵N`   | Shown when N background jobs are running (hidden at 0) |

Notes:

- **Stopping one task does not confirm** (re-runnable, so confirmation is noise);
  `:TaskStopAll` confirms once (`停掉 N 个任务？`).
- On the `:UEPrepare` progress float, `<C-c>` truly cancels the underlying jobs;
  `q` only hides the indicator (legacy behaviour preserved).
- Android **DAP debug sessions are never listed/killed here** (that would SIGKILL
  the on-device game — K5). Stop a debug session with `:UEDAPStop` instead.

## 🐞 DAP — unified `UEDAP*` commands

Source: `lua/config/keymaps.lua` (`<leader>d*` block + `dap_fkeys` table). All
keys call the **platform-neutral `:UEDAP*` user commands** defined in
`lua/ue.lua`. With no argument they dispatch to the active target; explicit
arguments such as `:UEDAPAttach android` still force one handler. IOS uses its
own physical-device handler, while Win64 targets the local debugger. (The older
`UEAndroidDAP*` route is gone — do not look for it.)

The `<F5/F6/F9/F10/F11/S-F11>` set is bound in **n / i / t / v** modes
(important: `dap-repl` is a prompt buffer; normal-only bindings would type a
literal `<F5>` in insert mode).

### Session control

| Key | Command | Action |
|---|---|---|
| `<leader>da` | `:UEDAPAttach` | Attach to the active target process |
| `<leader>dl` | `:UEDAPLaunch` | Launch active target + auto-attach |
| `<leader>dc` / `F5` | `:UEDAPContinue` | Continue |
| `<leader>dp` / `F6` | `:UEDAPPause` | Pause |
| `<leader>dn` / `F10` | `:UEDAPStepOver` | Step over |
| `<leader>di` / `F11` | `:UEDAPStepIn` | Step in (Neovide may steal F11 — see note) |
| `<leader>do` / `S-F11` | `:UEDAPStepOut` | Step out |
| — | `:UEDAPStop` | Stop through the frozen session owner (iOS launch stops its process; attach preserves it) |

### Breakpoints

| Key | Command | Action |
|---|---|---|
| `<leader>db` / `F9` | `:UEDAPToggleBreakpoint` | Toggle breakpoint (persisted, see below) |
| `<leader>dB` | `:UEDAPCondBreakpoint` | Conditional breakpoint (prompt) |
| `<leader>dL` | `:UEDAPLogpoint` | Logpoint (prompt) |
| `<leader>dC` | `:UEDAPClearBreakpoints` | Clear all breakpoints |

**Persistent breakpoints**: `F9` / `<leader>db` write to
`<engine_root>/.cache/nvim-ue/breakpoints/<project>.json`, survive nvim
restarts, and lazy-restore on `BufReadPost`. Saves are debounced 250ms.
Module: `lua/ue/dap/_persist_bp.lua`. In-session, iOS uses nvim-dap's source
breakpoint requests; Android plants live breakpoints via the lldb-dap evaluate
channel. Neither requires reattach for ordinary breakpoint changes.

### Inspect / evaluate / navigate

| Key | Command | Action |
|---|---|---|
| `<leader>de` | `:UEDAPEval` | Evaluate expression (prompt) |
| `<leader>dh` | `:UEDAPHover` | Hover-eval `<cword>` (visual: selection) |
| `<leader>dw` | `:UEDAPWatchAdd` | Add `<cword>` / selection to Watches |
| `<leader>dW` | `:UEDAPWatchUE` | UE-aware watch picker (fname/uobject/actor/tarray/raw) |
| `<leader>dt` | `:UEDAPRunToCursor` | Run to cursor (ephemeral bp + continue) |
| `<leader>dk` | `:UEDAPFrameUp` | Stack frame up |
| `<leader>dj` | `:UEDAPFrameDown` | Stack frame down |
| `<leader>dR` | `:UEDAPRestartFrame` | Restart current frame |

### UI / tabs

| Key | Command | Action |
|---|---|---|
| `<leader>du` | `:UEDAPToggleUI` | Toggle DAP UI |
| `<leader>dr` | `:UEDAPREPL` | Toggle REPL |
| `<leader>dx` | `:UEResetLayout` | Reset DAP layout |
| `<leader>d1` | `:UEDAPTab repl` | Focus REPL tab |
| `<leader>d2` | `:UEDAPTab console` | Focus Console tab |
| `<leader>d3` | `:UEDAPTab breakpoints` | Focus Breakpoints tab |
| `<leader>d4` | `:UEDAPTab log` | Focus target logs: iOS Logs on IOS, Logcat on Android |
| `<leader>d]` / `<leader>d[` | `:UEDAPNextTab` / `:UEDAPPrevTab` | Cycle DAP tabs |

Other commands (no default key): `:UEDAPStatus`, `:UEDAPDiag`,
`:UEDAPHover`, `:UEDAPListBreakpoints`, `:UEDAPReattach`, `:UEDAPRestartFrame`.
`:UEDAPTab logcat` remains a compatibility alias for the fourth, target-specific log tab.

**Note (Neovide 0.16+)**: F11 defaults to fullscreen. If `F11` toggles
fullscreen instead of stepping in, set `vim.g.neovide_fullscreen = false`.

`:qa` triggers `VimLeavePre`, which flushes any pending breakpoint save and
auto-cleans the DAP session.

### iOS 真机调试操作手册（macOS 本机）

本流程假定 Neovim、Xcode、本地 UE 工程与物理 iPhone/iPad 在同一台 Mac 上。iOS 17+ 使用
CoreDevice；pre-iOS17 使用独立的 legacy MobileDevice/debugserver 路线。设备选择决定 backend，
失败不会自动换设备、换 backend 或改成 Mac 进程 attach。

#### 1. 准备当前构建、符号与已安装应用

1. 用 `:UESetProject <workspace>` 选择工程，`:UESetPlatform IOS` 选择 IOS 配置，
   `:UESetIOSDevice` 选择实际连接的真机。设备需启用 Developer Mode、完成信任配对，并能被当前
   Xcode 访问；debug provisioning profile 必须包含该设备且允许 `get-task-allow`。
2. 若已在 Neovim 中编译当前 target/configuration，可以复用该次构建；否则执行 `:UEBuildIOS`。
   Build 只 compile/link，日常构建不会自动生成 dSYM。
3. 执行 `:UEIOSSymbols` 为**刚才的 binary**生成符号，等任务成功后再启动调试。默认工件为
   `<project_dir>/Binaries/IOS/<target>` 与同路径的 `<target>.dSYM`。
4. CoreDevice 首次安装或 binary 已更新时，执行 `:UEPackageIOS` → `:UEInstallIOS`。
   Package 复用已有 cooked data，只 stage/package；Install 原地安装且不启动应用。
   signing identity 可用 `:UESetIOSSigningCertificate` 从本工程 prepared manifest 导入或显式选择。
   符号生成不会把新 binary 安装到设备；仅更新 dSYM 也不会更新已安装的 app。

`:UEIOSSymbols` 调用仓内 `scripts/ue_ios_cpp_iteration.zsh`，由 `xcrun` 使用当前 Xcode 的
`dsymutil --linker parallel --verify-dwarf=output` 生成 `<binary>.dSYM`，随后比较 binary 与 dSYM
UUID，不生成 ZIP。CoreDevice DAP 默认用 `xcrun --find lldb-dap` 解析 Apple adapter；缺少时会
明确失败，不会静默改用 Homebrew LLVM。

#### 2. 从启动时调试（Launch）

1. 打开**对应构建的本地源码**，在希望首次执行时停下的位置按 `F9`。例如某次构建曾在
   `Engine/Source/Runtime/Launch/Private/IOS/LaunchIOS.cpp:555` 的 `main` 命中；这只是操作示例，
   文件行号与可停位置会随源码、配置和优化改变，应以当前源码及当前 frame 为准。
2. 执行 `:UEDAPLaunch ios` 或 `<leader>dl`。CoreDevice 路线以 `--start-stopped` 启动当前 bundle，
   捕获并复验其 PID，再连接 Apple lldb-dap。该命令使用 `--terminate-existing`，会替换该 bundle
   已有进程；需要保留现有运行状态时使用下一节的 Attach。
3. 等待 attach、loaded executable UUID 与断点 resolved 的证据。初始暂停允许在首次继续前添加
   源码断点；`F5` 继续后，应收到真正的 `breakpoint` stop 并跳到预期本地文件/行。
   只有断点标记、attach response 或 DAP UI 出现，都不足以证明断点已命中。
4. 暂停后用 `F10` / `F11` / `S-F11` 单步，`<leader>dk` / `<leader>dj` 切换 stack frame。
   `:UEDAPEval` 可先输入 `1+2` 检查 evaluate 通道；复杂 C++/UE 表达式是否可用取决于当前
   Apple LLDB、符号和 frame。表达式失败或 adapter 退出时应保留诊断，不要把简单表达式成功
   当成所有 UE 对象求值已验证。

普通 `:UELaunch` 保持非调试启动语义，不会 start-stopped；它与 `:UEDAPLaunch ios` 分开。

#### 3. 附加已运行应用（Attach）

1. 先以普通 `:UELaunch` 或设备端启动**已安装的当前 bundle**。
2. 在接下来会执行的源码位置按 `F9`，执行 `:UEDAPAttach ios` 或 `<leader>da`。
   handler 查询当前设备进程并复验 bundle/PID，不把上次普通 launch 返回的 PID 当成当前真相。
   应用未运行、PID 消失、同号 PID 已属其他 app 或进程无法唯一确定时会失败。
3. Attach 完成并通过 UUID gate 后，按 `F5` 继续，让目标走到断点。已经执行过的一次性启动代码
   不会因 attach 重新执行；此时应选择后续路径，或改用 Debug Launch。

两种入口都冻结当次 project、device/backend、bundle、PID、binary/dSYM 与 adapter。
会话中切换 `:UESetProject`、`:UESetPlatform` 或 `:UESetIOSDevice` 不会更改该会话的调试与清理归属。

#### 4. iOS Logs、Console 与调试诊断

| 入口 | 内容 |
|---|---|
| `<leader>d4` / `:UEDAPTab log` | **iOS Logs**：通过已有 `idevicesyslog` 读取冻结设备上该会话 PID 的设备日志 |
| `<leader>d1` / `:UEDAPTab repl` | **REPL**：DAP adapter 的 output event、连接/UUID 消息与表达式交互输出 |
| `<leader>d2` / `:UEDAPTab console` | **Console**：adapter 请求 `runInTerminal` 时使用的集成终端；iOS attach 不保证请求或输出，不等同于设备 syslog |
| `:UEDAPStatus` | 当前冻结 iOS owner、operation 与会话状态 |
| `:DapShowLog` | nvim-dap 的 adapter/protocol 诊断日志（插件加载后可用） |
| `:NvimLog` / `:NvimLogPath` | 本配置的错误记录与当前记录文件路径 |

iOS Logs 会按 session 的 CoreDevice identifier 查询其 hardware UDID，再按冻结 PID 过滤；
不会选择“第一台设备”，不会混入 Android `adb logcat`。reader 在 DAP initialized 时自动启动，
切到第四页后保留该 reader 已收到的最近 12,000 行，不需要等第一次打开日志页才开始收集。
日志读取不会 continue、detach 或重新启动正在暂停的 app。日志页没内容可能是该 PID 此时没有
新输出；暂停会话不会持续产生游戏日志，也不会把上次运行的历史输出补成当前日志。
`:Tasks` 可查看该日志 reader，`:TaskStop <id>` 只停止 reader，不结束 debugger 或改变暂停状态。

`idevicesyslog` 是可选的已有宿主工具。缺失或该设备日志连接失败时，日志页明确显示原因，
不自动安装依赖，DAP 本身仍可调试。旧命令 `:UEDAPTab logcat` 兼容为同一日志页。
普通 UE app log（`:UELogToggle`）的 IOS 主日志策略目前仍未支持；查看 iOS DAP 日志请使用第四页。

#### 5. UUID、dSYM 与连接失败排错

| 症状 / 归属 | 核对与处置 |
|---|---|
| L0：缺少 Apple lldb-dap / Xcode tool | 核对当前选定的 Xcode 能否提供 `xcrun --find lldb-dap`；CoreDevice 不换成其他平台 adapter |
| L1/L2：设备连接、信任、Developer Mode 或 debug entitlement 拒绝 | 核对冻结设备的连接与实际拒绝证据，再处理配对、Developer Mode 或匹配的 development profile |
| L4：本地 binary/dSYM UUID 不同 | 重新对当前 binary 执行 `:UEIOSSymbols`；不要使用另一构建的符号 |
| L4：DWARF verification 失败 | 重新生成通过结构验证的 dSYM；`dwarfdump --uuid` 相同本身不能证明 DWARF 可用 |
| L4：loaded executable UUID mismatch | 确认设备安装的是本次构建，重新 package/install 后再调试；不要关闭 gate 或改用旧 app |
| L3：Apple lldb-dap 退出、evaluate 无响应 | 记录 adapter 日志与具体请求；EOF cleanup 会释放本仓会话状态，不代表 LLDB 引擎问题已经修复 |

手动核对符号时，以下路径替换为当前 `<project_dir>/Binaries/IOS/<target>`；它们只读取本地
工件，不会继续或停止设备进程：

```sh
xcrun dwarfdump --uuid "/path/to/Binaries/IOS/SampleGame"
xcrun dwarfdump --uuid "/path/to/Binaries/IOS/SampleGame.dSYM"
xcrun dwarfdump --verify --quiet "/path/to/Binaries/IOS/SampleGame.dSYM"
```

**UUID 与 DWARF verification 通过仍不等于 LLDB evaluate 安全。**2026-10-09 的真机排查中，
默认 Apple parallel `dsymutil` 生成的一个大型 UE dSYM 通过了这两项检查，但 C++ evaluate 仍让
Apple LLDB stack overflow；使用宿主上**已有的 LLVM 23.1.3 `dsymutil`**，以
`--linker parallel --verify-dwarf=output` 重新生成后才通过该构建的真机验证。这是当前构建的实证，
不是所有 Apple 产物或所有新版 LLVM 都有同样结论；默认 `:UEIOSSymbols` helper 仍使用当前
Xcode 的工具，没有自动切换到 LLVM 23，也不会安装依赖。

若默认 helper 的产物复现该问题，先保存 adapter crash/request 证据并备份原 dSYM，再用已存在且
经验证的 `dsymutil` 输出到**新的临时 bundle**，例如：

```sh
"/path/to/existing/dsymutil" --linker parallel --verify-dwarf=output \
  "/path/to/Binaries/IOS/SampleGame" \
  -o "/path/to/Binaries/IOS/SampleGame.candidate.dSYM"
xcrun dwarfdump --uuid "/path/to/Binaries/IOS/SampleGame.candidate.dSYM"
xcrun dwarfdump --verify --quiet "/path/to/Binaries/IOS/SampleGame.candidate.dSYM"
```

在结束原调试会话后，以 candidate 作为新会话显式指定的 dSYM（`ue.dap.ios.launch/attach` 的
`dsym` 选项），复验同一 binary 的 UUID、DWARF、设备 loaded-image UUID、真实源码断点/frame
以及曾失败的 evaluate；全部证据通过后才替换默认 `<binary>.dSYM`，并保留原备份。
只换工具版本、生成成功或简单表达式成功，都不能替代这组验收。

CoreDevice 在 attach 前设置 `plugin.process.gdb-remote.packet-timeout 60`，保留传入的其他 init
commands。实测 start-stopped 初始连接的 `qProcessInfo` 曾需约 20 秒；LLDB 默认 5 秒会先超时，
断开的通道随后还可能表现为 loaded UUID mismatch。60 秒是远端包等待上限，不会主动 continue，
不会取消 binary/dSYM/loaded-image UUID 检查，也不会让真实不匹配通过。再次出现 mismatch 时，
应结合 adapter 日志判断是否先发生传输超时，再处理实际的工件不一致。

#### 6. 停止与清理归属

使用 `:UEDAPStop` 结束会话。**Debug Launch 创建的 PID**由该 owner 停止并复验退出；
**Attach 接入的已有 PID**只 detach 并复验进程保留。协议退出、adapter EOF、用户 Stop 与 Neovim
退出沿用同一 owner cleanup；重复事件不会重复执行有副作用的 teardown，旧会话晚到的回调也不会
清理新会话的 PID。日志 reader 可以单独停止；停止 reader 不等于停止 debugger。

---

## 📝 Logs & Workarounds

| Command                        | Action                                                                 |
|--------------------------------|------------------------------------------------------------------------|
| `:NvimLog`                     | Open the current debug log in a new tab                                |
| `:NvimLogPath`                 | Echo + yank the absolute path of the active log file                   |
| `:NvimLogClear`                | Truncate + rotate (keeps `.1`–`.5` backups)                            |
| `:NvimLogLevel <lvl>`          | Set global threshold: `trace`/`debug`/`info`/`warn`/`error` (default `warn`) |
| `:NvimLogScope <scope> <lvl>`  | Per-scope override (use `clear` to remove); no args = list overrides   |
| `:WorkaroundList`              | List all known workarounds + state                                     |
| `:WorkaroundStatus <name>`     | Show one workaround's metadata                                         |
| `:WorkaroundEnable <name>`     | Enable a workaround at runtime                                         |
| `:WorkaroundDisable <name>`    | Disable a workaround at runtime                                        |

Active workarounds (see `lua/workarounds/`):
- `lazyvim.close_with_q_invalid_buf` — guards LazyVim's `q` autocmd
- `neovide.exit_with_gui` — clean Neovide exit on `:qa`
- **`clangd.non_file_uri_detach`** — clangd attaches to git/diff/oil
  buffers (e.g. `fugitive://...`, `diffview://...`) and floods the
  notification area with `-32602 clangd only supports file:// URIs`
  on every cursor hold. This workaround detaches clangd as soon as
  it attaches to any non-`file://` URI buffer. Disable via
  `:WorkaroundDisable clangd.non_file_uri_detach` if you ever need
  the raw behaviour.

Debug log details:

- File: `stdpath('log')/nvim/nvim-debug.log` →
  `C:\Users\<USER>\AppData\Local\nvim-data\nvim\nvim-debug.log` on this box
- Rotation: per-file cap **2 MB**, keeps **5** rolling backups
- Default level **WARN**: only `warn` / `error` land on disk
- Format: `ISO-time LEVEL [scope] message [k=v ...] | short_src:line`
- Scopes: `ue` / `ue.build` / `ue.prepare` / `ue.android` / `ue.pch` /
  `ue.io` / `dap` / `dap.bp` / `dap.pause` / `dap.aslr` / `yazi` /
  `theme` / `workarounds` / `sidebar` / `snacks` / `windows` /
  `ue_logs` / `ue_launch` / `smoke`
- Tail it: `tail -f "$LOCALAPPDATA/nvim-data/nvim/nvim-debug.log"`

Lua module authors: prefer
`local L = require("utils.log").scoped("my.scope")` then `L.error(...)`
/ `L.error_ctx("msg", {k=v})` / `L.notify_error("...")` /
`L.wrap_job{cmd=...}`. Fast-event safe.

## Markdown

Source: `lua/plugins/markdown.lua`.

| Command                   | Action                            |
|---------------------------|-----------------------------------|
| `:MarkdownPreview`        | Browser-side live preview         |
| `:MarkdownPreviewToggle`  | Toggle preview                    |
| `:MarkdownEdit`           | Open this cheatsheet for editing  |

## Cheatsheet Float Window

Source: `lua/utils/cheatsheet.lua` (set when `:UECheatsheet` opens).

| Key                  | Action         |
|----------------------|----------------|
| `q`                  | Close          |
| `<Esc>`              | Clear an active search; otherwise close |
| `/`                  | Live-search every shortcut and description |
| `<C-l>`              | Clear the search and return to the active category |
| `<Tab>` / `<S-Tab>`  | Next / prev category tab |
| `1` … `9`            | Jump to tab N  |
| `j` / `k`            | Move           |
| `<C-f>` / `<C-b>`    | Page down / up |
| `gg` / `G`           | Top / bottom   |

Search results keep their original `Tab › Section` classification instead of
becoming a flat list. Display separators are ignored for exact key lookup, so
`wW` immediately finds `Basics › Motions` → `w / W`, and `aA` finds
`Basics › Modes` → `a / A`. Matching is case-insensitive.

---

## When Stuck
- `<leader>sk` — search keymaps for the action you want
- `<leader>sh` — search help
- `<leader>?`  — open this cheatsheet floating
- `:help motion.txt`
- `:help usr_28`
- `:help folds`
- `:help quickfix`

## Productivity Habits
- Before editing: `*` search current word, then `gr` to check references
- For repetitive edits: record a macro instead of doing it 3 times manually
- For structural changes: use text objects (`ci(`, `da{`, `viw`)
- For bulk rename: prefer `gr` → `<leader>ss` → `<leader>sS` → `<leader>sr`
- For large files: marks + jumps + folds (`ma` to mark, `<C-o>` to return,
  `zM` / `zo` / `zc`)
- To avoid polluting register: `"_d`
- After each small edit: `.` to repeat quickly
- Lost a picker after `<C-q>`? `<leader>s/` brings it back

## Essential Builtins to Memorize
- `u` / `<C-r>` — undo / redo
- `.` — repeat last change
- `*` / `#` — search current word
- `%` — matching bracket
- `ma` / `'a` / `` `a `` — marks
- `qa` / `@a` — macros
- `zc` / `zo` / `za` — fold single
- `zM` / `zR` — fold all / open all
- `<C-o>` / `<C-i>` — jump back / forward
