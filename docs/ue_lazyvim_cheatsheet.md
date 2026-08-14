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
| `<leader>vg`     | Git modified files / status             |
| `<leader>vb`     | Open buffers                            |
| `<leader>vs`     | File symbols                            |
| `<leader>vd`     | Diagnostics                             |
| `<leader>vq`     | Pinned quickfix results                 |
| `<leader>vl`     | Location list                           |
| `<leader>vt`     | TODO / FIXME                            |

Views share the same left panel. Switching `v?` replaces content.

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

Source: `lua/plugins/diffview.lua`, `lua/plugins/neogit.lua`,
`lua/plugins/fugitive.lua`, `lua/plugins/gitsigns.lua`,
`lua/plugins/snacks.lua`. There is **no lazygit** — full git UI is
**Neogit**, diffs are **diffview**, blame and history quickfix are
**fugitive**, advanced search is **advanced_git_search**.

### Cheat-by-scenario (the four scenarios this stack solves)

| 你想做什么 | 怎么做 |
|---|---|
| **看某个 commit 改了哪些文件 + diff** | `<leader>gM`（branch history picker）→ `<cr>` 选 commit → diffview tab 列文件树 + 双栏 diff |
| **同上但只想看一个具体 hash** | `<leader>gk` → 输入 hash（默认 `HEAD`） → diffview 直接打开 `<rev>^!` |
| **单文件随时间的变化轨迹** | `<leader>gm`（this file history）→ 上下选 commit 看每个 commit 对此文件的 diff |
| **任意两个 ref / 分支间 diff** | `<leader>gr` → 输入 `main..feature` 或 `HEAD~3..HEAD` → diffview 完整 PR 视图 |
| **Blame 当前行（GitLens 风格）** | 默认开启：行尾虚拟文本显示 `author · time · summary`（200ms 延迟），`<leader>uG` toggle |
| **Blame 整个文件（可滚动）** | `<leader>gB`（fugitive `:Git blame`）→ 在 blame 窗口里 `o` 预览 commit、`<cr>` 打开 |
| **找哪个 commit 引入了某行代码** | `<leader>gh`（按内容搜 commit） / `<leader>gH`（限定当前文件）|
| **看当前文件历史 → 选 commit 比 diff** | `<leader>gX`（当前文件 vs 选中的 commit） |
| **完整状态面板 / 提交 / push** | `<leader>gn`（Neogit） |

### 全部按键

| Key                | Action                                           | Source |
|--------------------|--------------------------------------------------|--------|
| `]h` / `[h`        | Next / previous hunk                             | gitsigns |
| `]H` / `[H`        | Last / first hunk                                | LazyVim |
| `<leader>gb`       | Blame current line (popup)                       | LazyVim |
| `<leader>gB`       | **Full-file blame view (scrollable)**            | fugitive |
| `<leader>gd`       | Preview diff hunk                                | LazyVim |
| `<leader>gv`       | Diffview: working tree                           | diffview |
| `<leader>gV`       | Diffview: close                                  | diffview |
| `<leader>gm`       | Diffview: this file history                      | diffview |
| `<leader>gM`       | Diffview: branch history (commit picker)         | diffview |
| `<leader>gv` (v)   | Diffview: selection history                      | diffview |
| `<leader>gr`       | **Diffview: arbitrary range** (prompts ref)      | diffview |
| `<leader>gk`       | **Diffview: single commit** (prompts hash)       | diffview |
| `<leader>gn`       | **Neogit** status panel (one-stop)               | neogit |
| `<leader>gs`       | Git status picker (snacks)                       | LazyVim |
| `<leader>gc`       | Commits picker (snacks)                          | LazyVim |
| `<leader>gh`       | **Git: search commits by content**               | adv-git-search |
| `<leader>gH`       | **Git: search commits by content (this file)**   | adv-git-search |
| `<leader>gx`       | **Git: diff this file against a branch**         | adv-git-search |
| `<leader>gX`       | **Git: diff this file against a commit**         | adv-git-search |
| `<leader>gC`       | **Git: checkout from reflog**                    | adv-git-search |
| `<leader>gA`       | **Git: advanced search palette (all actions)**   | adv-git-search |
| `<leader>g0`       | **Open `:0` (staged) version of current file**   | fugitive |
| `<leader>gl`       | Commits touching this file → quickfix            | fugitive |
| `<leader>gL`       | All commits → quickfix                           | fugitive |

### Inside Neogit status (`<leader>gn`)

每个动作都是单字母：`s`/`u`/`x` stage/unstage/discard、`c` commit、
`P` push、`p` pull、`b` branch、`Z` stash、`l` log、`<tab>` 折叠 section、
`?` help、`q`/`<Esc>` 关闭。

### Inside diffview

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

Branch diff or any ad-hoc ref pair: `:DiffviewOpen main..feature` (or
use `<leader>gr` for prompt).

This config uses `[h` / `]h` for hunk nav, **not** `[c` / `]c` —
`[c` is treesitter context jump.

### Inline blame (GitLens-style)

Gitsigns shows `<author>, <time> · <summary>` at end of line with 200ms
delay. Toggle: `<leader>uG`. Disable globally: in
`lua/plugins/gitsigns.lua` set `current_line_blame = false`.

### Why every `<leader>g*` shows a placeholder window first

All git **and UE prepare/index** keys go through
`lua/utils/async_launcher.lua` (formerly `git_async`, kept as a
forwarder). The contract:

1. **Placeholder window appears immediately** (centered float with
   action name + spinner) — the editor is never frozen waiting for
   git or UBT.
2. **Right-bottom progress** via fidget (same corner as LSP progress)
   so it's familiar across subsystems.
3. **Real command runs in `vim.schedule` + `vim.defer_fn(0)`**, after
   the placeholder has composited — the heavy work (lazy-loading
   diffview, spawning `git log` / `UnrealBuildTool` / `cindex`)
   cannot block the UI thread.
4. **`run` gets a `report(msg)` callback.** Phase progress (e.g.
   "S2: UHT done, starting cindex") flows to **both** the placeholder
   sub-line and the fidget message — no extra `vim.notify` floats.
5. **Press `q`** in the placeholder to dismiss the indicator early
   (the underlying job keeps running — this just hides the popup).
6. **Auto-cleanup** when the picker / diffview tab opens, with a
   minimum visible time of 250 ms so you can read the title even on
   instant returns.

Affected commands today:

| Command                | Why it needs the launcher |
|------------------------|---------------------------|
| All `<leader>g*` (diffview / fugitive / neogit / advanced_git_search) | First-press lazy load + git spawn |
| `:UEPrepare`           | ueprepare init + first UBT/cindex spawn |
| `:UEPrepareReindex`    | Same + forced csearch full rebuild |
| `:UEIndexHot`          | Schedule hot+full GTAGS passes |
| `:UEIndexFull`         | Schedule full GTAGS pass |

**Not** wrapped (intentionally):

| Command            | Why no placeholder |
|--------------------|--------------------|
| `:UEIndexNow`      | Single buffer; usually <100ms — placeholder would just flash |
| `<leader>gV`       | Closing diffview is instant |
| `:UEPrepareSync`   | Synchronous escape hatch by design (debug only); emits a WARN before blocking |

If you want to disable the placeholder for a specific key, replace
the `function() require("utils.async_launcher").launch{...} end`
wrapper with the plain `<cmd>...<cr>` form.

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
| `:UECompileForNvim`       | Build current target, generate tuple-scoped IOS CDB evidence when RSP is absent, then prepare clangd semantics |
| `:UEBuildIOS`             | Build IOS C++ through native macOS UBT; safely reuse unchanged AOT outputs and defer dSYM |
| `:UEPackageIOS`           | Reuse existing cooked data, then stage/package IOS; never build, cook, archive, deploy, or run |
| `:UEIOSSymbols`           | Generate the current IOS binary's dSYM on demand and verify Mach-O UUIDs; no ZIP |
| `:UESetIOSDevice`         | Select an available physical iOS device from CoreDevice JSON |
| `:UEInstallIOS`           | Install the current package task's `.app`; does not launch |
| `<leader>us`              | `:UEBuildAndroidSO` — export + execute UBT compile/link actions (no Deploy/Gradle/APK) |
| `<leader>uq`              | `:UEDeployAndroidSO` — strip, push, atomically replace and verify `libUE4.so`; leaves the app stopped |
| `<leader>uB`              | `:UEPrepare` (symbols + compile_commands) |
| `<leader>uc`              | `:UEExportCompileCommands`          |
| `<leader>ul`              | `:UELaunch` (no debugger)           |
| `<leader>ui`              | `:UEInstallAndroid` (APK to selected device via `adb -s`; does not launch) |
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

iOS 的设备、artifact、bundle id 与 process 状态保存于 IOS-scoped runtime state，
不与 Android 或 Mac target 共用。C++ 日常迭代顺序是 `:UEBuildIOS` → `:UEPackageIOS` → `:UESetIOSDevice` →
`:UEInstallIOS` → `:UELaunch`。package/install 需要有效签名；无签名或无可用真机时会在只读
preflight 失败，不会回退到 UE legacy fastlane/ideviceinstaller/instruments。

`:UEBuildIOS` 的第一次构建（或 AOT 输入、工具链、SDK、framework 产物发生变化后）仍执行完整 AOT；
只有输入指纹相同且上次成功构建记录的 framework 路径与内容 hash 全部匹配时，Nvim 才注入
`bSkipAOTProcess=true`。日常构建固定以命令行 INI override 关闭自动 dSYM；需要调试/符号化时再执行
`:UEIOSSymbols`，避免每次编译都支付 `dsymutil` 与 ZIP 的时间和磁盘成本。

### Less-common UE commands

These exist (`grep create_user_command lua/ue.lua` to verify) but
have no key bound by default:

| Command                | Action                                  |
|------------------------|-----------------------------------------|
| `:UEPrepareReindex`    | Reindex without re-export ccjson        |
| `:UEPrepareIncremental`| Prepare only dirty files (fast refresh) |
| `:UEPrepareSync`       | Synchronous prepare (debug)             |
| `:UEGenerateFromRSP`   | Re-export ccjson from cached `.rsp`     |
| `:UEBuildAndroid`      | Force Android build target              |
| `:UEBuildIOS`          | Build only the IOS target                |
| `:UECompileForNvim`    | Build + RSP/CDB semantic prepare         |
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

1. `:UESetProject` — bind project + engine root (persisted)
2. `:UESetPlatform Win64 Development Editor`
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
`lua/ue.lua`. `:UEDAPAttach android` dispatches to the Android handler; on
Win64 the same commands target the local debugger. (The older
`UEAndroidDAP*` route is gone — do not look for it.)

The `<F5/F6/F9/F10/F11/S-F11>` set is bound in **n / i / t / v** modes
(important: `dap-repl` is a prompt buffer; normal-only bindings would type a
literal `<F5>` in insert mode).

### Session control

| Key | Command | Action |
|---|---|---|
| `<leader>da` | `:UEDAPAttach android` | Attach to the Android process |
| `<leader>dl` | `:UEDAPLaunch android` | Launch + auto-attach |
| `<leader>dc` / `F5` | `:UEDAPContinue` | Continue |
| `<leader>dp` / `F6` | `:UEDAPPause` | Pause |
| `<leader>dn` / `F10` | `:UEDAPStepOver` | Step over |
| `<leader>di` / `F11` | `:UEDAPStepIn` | Step in (Neovide may steal F11 — see note) |
| `<leader>do` / `S-F11` | `:UEDAPStepOut` | Step out |

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
Module: `lua/ue/dap/_persist_bp.lua`. In-session, breakpoints are planted live
via the lldb-dap evaluate channel (no reattach needed).

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
| `<leader>d4` | `:UEDAPTab logcat` | Focus Logcat tab |
| `<leader>d]` / `<leader>d[` | `:UEDAPNextTab` / `:UEDAPPrevTab` | Cycle DAP tabs |

Other commands (no default key): `:UEDAPStatus`, `:UEDAPDiag`,
`:UEDAPHover`, `:UEDAPListBreakpoints`, `:UEDAPReattach`, `:UEDAPRestartFrame`.

**Note (Neovide 0.16+)**: F11 defaults to fullscreen. If `F11` toggles
fullscreen instead of stepping in, set `vim.g.neovide_fullscreen = false`.

`:qa` triggers `VimLeavePre`, which flushes any pending breakpoint save and
auto-cleans the DAP session.

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
