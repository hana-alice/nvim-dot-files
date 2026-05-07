# Neovim + LazyVim Development Handbook

Covers Vim fundamentals → LazyVim workflows → UE/Android DAP, with the
keymap conventions used in **this** config.

> 浮窗版：`:UECheatsheet` （`<leader>?`） — 卡片式、可分类切换。
> 文档完整版（你现在看的）：`:UECheatsheetEdit` 或 `<leader>?` 后切到 Markdown。

---

## How to Re-Generate This Document

This file is **derived from code**, not the other way around. If you
edit any keymap, regenerate by:

1. Re-scan keymap-bearing files:
   - `lua/config/keymaps.lua` — the bulk of `<leader>` bindings
   - `lua/config/windows.lua` — `<leader>E / oe / tc / tp / te`
   - `lua/plugins/*.lua` — every `keys = { ... }` block
   - `lua/ue.lua` — every `vim.api.nvim_create_user_command("UE…")`
2. Cross-check **command** existence: a key that calls `<cmd>UEFoo<cr>`
   is dead if `UEFoo` isn't created anywhere. Use:

   ```bash
   grep -rE 'create_user_command\("(\w+)"' lua | \
     sed -E 's/.*"(\w+)".*/\1/' | sort -u
   ```
3. Update **both** this file AND `lua/utils/cheatsheet.lua` (the
   floating window). They are two surfaces over the same data.
4. The Git section lists **only** what really exists — there is
   **no lazygit** in this config; `<leader>gn` (Neogit) is the only
   git UI entry point.

## How to Use This Document

- `<leader>?` / `:UECheatsheet`         — open the floating cheatsheet
- `:UECheatsheetEdit`                   — edit this markdown file
- `:MarkdownPreview` / `:MarkdownPreviewToggle` — pretty render
- File: `docs/ue_lazyvim_cheatsheet.md`

## Start Here (the 8 keys you must know)
- `Space`                 → `<leader>` (hold to open which-key)
- `<leader>sk`            → search keymaps (best discovery)
- `<leader>sh`            → search help
- `<leader><space>`       → find files (workspace-aware)
- `<leader>/`             → grep project
- `gd` / `gr`             → goto definition / references
- `u` / `<C-r>`           → undo / redo
- `.`                     → repeat last change

---

## Keymap Conventions (this config)

The keymap surface follows a few rules so muscle memory stays cheap:

1. **LazyVim built-ins win ties.** When a custom map duplicates a stock
   LazyVim keybind, the custom one is removed. Example: terminal toggle
   is `<C-/>` (built-in), not `<leader>tt`.
2. **Avoid `<leader>` + mixed-case two-letter combos** (e.g. `<leader>fE`,
   `<leader>gP`) where possible — they kill muscle memory. Existing ones
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

## Vim Fundamentals — Modes

| Mode     | Enter              | Purpose                       |
|----------|--------------------|-------------------------------|
| Normal   | `<Esc>`            | Navigate, delete, copy, jump  |
| Insert   | `i` `a` `o` etc    | Type text                     |
| Visual   | `v` `V` `<C-v>`    | Select regions                |
| Command  | `:`                | Ex commands (`:w` `:q` `:s`)  |
| Terminal | `<C-/>` toggle     | Shell input, `<Esc>` to exit  |

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

## LSP Navigation

Source: `lua/plugins/ue.lua` (`gd`, `<leader>ch`),
`lua/config/keymaps.lua` (`gr`, `<leader>gP`, `<C-LeftMouse>`).

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `gd`             | Definition (LSP → GTAGS → rg fallback chain) |
| `gr`             | References (LSP → GTAGS fallback)       |
| `gD`             | Go to declaration (LazyVim)             |
| `gI`             | Go to implementation (LazyVim)          |
| `gy`             | Go to type definition (LazyVim)         |
| `K`              | Hover documentation (LazyVim)           |
| `gK`             | Signature help (LazyVim)                |
| `<C-k>` (insert) | Signature help in insert mode (LazyVim) |
| `<C-LeftMouse>`  | Smart jump: `gf` if file ref, else `gd` |
| `<leader>gP`     | Switch instant → precise definition     |
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

LSP fallback chain: LSP → GTAGS index → ripgrep word search.
Status: `:UEDefStatus`. Trace: `:UEDefTrace`. Self-test:
`:UEDefSelfTest`. Diag: `:UEDefDiag`. Reload: `:UEDefReload`.

`gd` overload disambiguation (since 2026-04 syntax-filter-v1):
treesitter parses cursor's call_expression for argument count K, then
for each candidate parses its function_declarator for params P/D/V.
Drops mismatched candidates pre-jump. Spinner tag indicates path:

  ⚡ ... (instant·syntax·pair_h_cpp, N→1) — pair_picker auto-picks `.cpp`
  ⚡ ... (instant·syntax·sole_cpp, N→1)  — N hdr + 1 cpp, jumps to cpp
  ⚡ ... (instant·syntax)  — ws/symbol + filter, single match → jumped
  ⚡ ... (instant)         — ws/symbol, filter inactive (cursor not in call)
  ✓ ... (precise·syntax)   — textDocument/definition + filter
  ✓ ... (N candidates, ...) — filter + pair_picker undecided → quickfix
  ⊘ ... — dependent-name early-bail (template parameter)
  ● already at ... — cursor IS the definition site

## Picker / Search (Snacks)

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
| `<C-p>` / `<C-n>`| Prev / next history                     |
| `<C-/>`          | Toggle help inside picker               |
| `<Tab>`          | Toggle focus list ↔ input               |
| `<CR>`           | Confirm                                 |
| `<Esc>` / `q`    | Close picker                            |

### Picker matcher (this config)

`<leader><leader>` and other pickers share these matcher options
(set in `lua/plugins/snacks.lua`):

- **smart-case**: lowercase query → ignore case; mixed case → exact
- **fzf-style fuzzy**: subsequence match, gap-penalised, boundary
  bonuses (camelCase, path separators, word starts)
- **filename bonus**: filename matches outrank path matches —
  typing `ui` puts `MyUI.cpp` above `src/ui-helpers/foo.cpp`

### Grep Tips

- Default is smart-case
- `<leader>sw` searches current word/selection directly
- `<leader>sy` prefills current word into live grep for further editing
- `<leader>sx` for whole-word, `<leader>sX` for case-sensitive
- In any Snacks picker: `<C-q>` sends results to quickfix (auto-opens sidebar)
- `<C-Space>` to multi-select, then `<C-q>` to pin filtered subset
- Append ripgrep args in live grep: `Foo -- --word-regexp --case-sensitive`
- After `<C-q>` pin, recover the picker with `<leader>s/`

## Trouble / Quickfix / Diagnostics

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

## Left Sidebar / Workbench

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

## Terminal / Shell

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

## Git

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
| `<leader>gP`       | LSP: switch to precise definition (re-uses `g`)  | (LSP) |

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

## UI / Toggles

Source: `lua/plugins/zen-mode.lua` (`<leader>z`),
`lua/config/keymaps.lua` (`<leader>ut`, `<leader>?`).

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>ut`     | Theme picker (`:ThemePicker`)           |
| `:Theme`         | Open theme picker                       |
| `:Theme <name>`  | Set and persist theme                   |
| `<leader>uf`     | Toggle format on save (LazyVim)         |
| `<leader>uF`     | Force format mode (LazyVim)             |
| `<leader>ud`     | Toggle diagnostics (LazyVim)            |
| `<leader>us`     | Toggle spelling (LazyVim)               |
| `<leader>uw`     | Toggle word wrap (LazyVim)              |
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

## Windows-only

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

## UE Workflow

Source: `lua/config/keymaps.lua` (static `<leader>uB / uc / uP`,
runtime `ub / ug / ui / ul / uL / uD / up`), `lua/plugins/snacks.lua`
(`<leader>uo / uO`), all `:UE*` user commands in `lua/ue.lua`.

| Key / Command             | Action                              |
|---------------------------|-------------------------------------|
| `<leader>uP`              | `:UESetProject` — set project root  |
| `:UESetPlatform`          | Interactive platform+config select  |
| `:UESetPlatform Win64 Development Editor` | Direct set         |
| `<leader>ub`              | `:UEBuild` (platform from `:UESetPlatform`) |
| `<leader>uB`              | `:UEPrepare` (symbols + compile_commands) |
| `<leader>uc`              | `:UEExportCompileCommands`          |
| `<leader>ul`              | `:UELaunch` (no debugger)           |
| `<leader>ui`              | `:UEInstallAndroid` (APK to device) |
| `<leader>ug`              | `:UELogToggle` (toggle app log)     |
| `<leader>uL`              | `:UELogToggle` (alias)              |
| `<leader>uD`              | `:UEDebugLogToggle` (Windows debug log) |
| `<leader>uo`              | UE: files in current module / plugin |
| `<leader>uO`              | UE: grep in current module / plugin  |
| `<leader>up`              | `:UEPaths` (show UE paths)          |
| `<leader>?`               | `:UECheatsheet` (open this cheatsheet) |

### Less-common UE commands

These exist (`grep create_user_command lua/ue.lua` to verify) but
have no key bound by default:

| Command                | Action                                  |
|------------------------|-----------------------------------------|
| `:UEPrepareReindex`    | Reindex without re-export ccjson        |
| `:UEPrepareSync`       | Synchronous prepare (debug)             |
| `:UEGenerateFromRSP`   | Re-export ccjson from cached `.rsp`     |
| `:UEBuildAndroid`      | Force Android build target              |
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
| `:UEDefStatus`         | Show LSP→GTAGS→rg fallback state        |
| `:UEDefTrace`          | Toggle goto-def tracing                 |
| `:UEDefSelfTest`       | Run goto-def self-test                  |
| `:UEDefDiag`           | Goto-def diagnostics dump               |
| `:UEDefReload`         | Reload goto-def module                  |

Typical Win64 workflow:

1. `:UESetPlatform Win64 Development Editor`
2. `<leader>uc` (`:UEExportCompileCommands`)
3. Open code, use `gd` / `gr` / `<leader>ss` / `<leader>/`

## DAP — Android (legacy keymap, still primary today)

Source: `lua/config/keymaps.lua` `<leader>d*` block + `<F5/F6/F9/F10>`.
All bound to `:UEAndroidDAP*` commands.

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>da`     | Attach to Android process               |
| `<leader>dl`     | Launch debug (auto-attach)              |
| `<leader>db`     | Toggle hardware breakpoint              |
| `<leader>dc`     | Continue                                |
| `<leader>dp`     | Pause                                   |
| `<leader>dn`     | Step over                               |
| `<leader>di`     | Step in                                 |
| `<leader>do`     | Step out                                |
| `<leader>du`     | Toggle DAP UI                           |
| `<leader>dr`     | Toggle REPL                             |
| `<leader>dx`     | Reset DAP layout                        |
| `<F5>`           | Continue                                |
| `<F6>`           | Pause                                   |
| `<F9>`           | Toggle hardware breakpoint              |
| `<F10>`          | Step over                               |

Quick reference (all lowercase, in order):
- `Space ub` build → `Space ui` install → `Space da` attach
- `Space dl` launch debug
- `Space dc` continue, `Space dp` pause
- `Space dn` step over, `Space di` step in, `Space do` step out
- `Space db` breakpoint, `Space du` DAP UI, `Space dr` REPL,
  `Space dx` reset

`:qa` auto-cleans DAP session.

## DAP — Platform-neutral (newer commands, no key by default)

Source: `lua/ue.lua` `UEDAP*` user commands (since 2026-05 multi-platform
foundation). Use these in scripts or bind your own keys when working on
Win64 / macOS / Linux / iOS rather than Android.

| Command                       | Action                          |
|-------------------------------|---------------------------------|
| `:UEDAPAttach`                | Attach (platform-aware)         |
| `:UEDAPLaunch`                | Launch debug (platform-aware)   |
| `:UEDAPContinue`              | Continue                        |
| `:UEDAPPause`                 | Pause                           |
| `:UEDAPToggleBreakpoint`      | Toggle breakpoint               |
| `:UEDAPStepOver`              | Step over                       |
| `:UEDAPStepIn`                | Step in                         |
| `:UEDAPStepOut`               | Step out                        |
| `:UEDAPToggleUI`              | Toggle DAP UI                   |
| `:UEDAPREPL`                  | Toggle REPL                     |
| `:UEDAPDiag`                  | Dump DAP diagnostics            |

The Android `<leader>d*` keys above will eventually migrate to call
the platform-neutral `UEDAP*` commands. Until then, they remain
hardcoded to `UEAndroidDAP*`.

---

## Logs & Workarounds

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
- `lazy.float_vimresized_invalid_buf` — Lazy.nvim float resize guard
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
| `q` / `<Esc>`        | Close          |
| `<Tab>` / `<S-Tab>`  | Next / prev category tab |
| `1` … `9`            | Jump to tab N  |
| `j` / `k`            | Move           |
| `<C-f>` / `<C-b>`    | Page down / up |
| `gg` / `G`           | Top / bottom   |

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
