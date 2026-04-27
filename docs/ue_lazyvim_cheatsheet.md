# Neovim + LazyVim Development Handbook

Covers Vim fundamentals → LazyVim workflows → UE/Android DAP, with the
keymap conventions used in this config.

> 浮窗版：`:UECheatsheet` （`<leader>?`） — 卡片式、可分类切换。
> 文档完整版（你现在看的）：`:UECheatsheetEdit` 或 `<leader>?` 后切到 Markdown。

---

## How to Use This Document
- `<leader>?` / `:UECheatsheet`         — open the floating cheatsheet
- `:UECheatsheetEdit`                   — edit this markdown file
- `:MarkdownPreview` / `:MarkdownPreviewToggle` — pretty render
- File: `docs/ue_lazyvim_cheatsheet.md`
- Source of truth: keep this file in sync whenever keymaps change

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

Enable folds first if needed:
- `zi` toggle fold on/off
- `:setlocal foldenable` enable for current buffer
- `:setlocal foldmethod=indent` quick indent-based folds

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

Reading large files:
1. `zM` to collapse everything, see structure only
2. `zj` / `zk` to jump between functions
3. `zo` to open interesting sections
4. `zc` to close when done
5. `zM` or `zR` to reset

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

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `gd`             | Go to definition (TS overload filter → LSP → GTAGS → rg) |
| `gr`             | References (LSP → GTAGS fallback)       |
| `gD`             | Go to declaration                       |
| `gI`             | Go to implementation                    |
| `gy`             | Go to type definition                   |
| `gai` / `gao`    | Incoming / outgoing calls               |
| `K`              | Hover documentation                     |
| `gK`             | Signature help                          |
| `<C-k>` (insert) | Signature help in insert mode           |
| `<C-LeftMouse>`  | Smart jump: `gf` if file ref, else `gd` |
| `<leader>gP`     | Switch instant→precise definition       |
| `<leader>ca`     | Code action                             |
| `<leader>cr`     | Rename symbol                           |
| `<leader>cf`     | Format buffer or selection              |
| `<leader>cd`     | Line diagnostics                        |
| `<leader>cl`     | LSP info                                |
| `<leader>ss`     | Document symbols                        |
| `<leader>sS`     | Workspace symbols                       |
| `<leader>sr`     | Search & replace tool (cross-file)      |
| `gc` / `gcc`     | Comment operator / current line         |
| `gco` / `gcO`    | Insert comment line below / above       |

LSP fallback chain (gd / gr): LSP → GTAGS index → ripgrep word search.
Status: `:UEDefStatus`. Used heavily for huge UE codebases where clangd
is still loading.

`gd` overload disambiguation (since 2026-04 syntax-filter-v1):
treesitter parses cursor's call_expression for argument count K, then
for each candidate parses its function_declarator for params P/D/V.
Drops mismatched candidates pre-jump. Spinner tag indicates path:
  ⚡ ... (instant·syntax·pair_h_cpp, N→1) — pair_picker 自动选 .cpp
  ⚡ ... (instant·syntax·sole_cpp, N→1)  — N hdr + 1 cpp, 跳 cpp
  ⚡ ... (instant·syntax)  — ws/symbol + filter, single match → jumped
  ⚡ ... (instant)         — ws/symbol, filter inactive (cursor not in call)
  ✓ ... (precise·syntax)   — textDocument/definition + filter
  ✓ ... (N candidates, ...) — filter + pair_picker 都没敲定 → quickfix
  ⊘ ... — dependent-name early-bail (template parameter)
  ● already at ... — cursor IS the definition site
Trace: `:UEDefTrace`. Self-test: `:UEDefSelfTest`.

## Picker / Search (Snacks)

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader><space>`| Find workspace files                    |
| `<leader>fe`     | File tree browser (project, snacks explorer) |
| `<leader>ff`     | Find project files                      |
| `<leader>fF`     | Find workspace code files               |
| `<leader>fa`     | Find project code files                 |
| `<leader>fg`     | Find git files (UE-aware)               |
| `<leader>,`      | Buffers                                 |
| `<leader>;`      | All commands (Enter to execute)         |
| `<leader>:`      | Command history                         |
| `<leader>fr/fR`  | Recent files                            |
| `<leader>fC`     | Clear file picker history               |
| `<leader>/`      | Grep project code                       |
| `<leader>sg`     | Grep workspace code                     |
| `<leader>sG`     | Grep workspace all files                |
| `<leader>sw/sW`  | Search current word or selection        |
| `<leader>sy/sY`  | Live grep with current word prefilled   |
| `<leader>sx`     | Grep whole word match                   |
| `<leader>sX`     | Grep case-sensitive                     |
| `<leader>sH`     | Grep history                            |
| `<leader>sC`     | Clear grep/files history                |
| `<leader>sR`     | Resume last picker (any kind)           |
| `<leader>s/`     | Resume last grep (works after `<C-q>` pin) |
| `<leader>sk`     | Keymaps                                 |
| `<leader>sh`     | Help tags                               |
| `<leader>sm`     | Marks                                   |

## Inside a Snacks Picker

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

## Grep Tips
- Default is smart-case: `foo` is case-insensitive, `Foo` is case-sensitive
- `<leader>sw` searches current word/selection directly
- `<leader>sy` prefills current word into live grep for further editing
- `<leader>sx` for whole-word, `<leader>sX` for case-sensitive
- In any Snacks picker: `<C-q>` sends results to quickfix (auto-opens sidebar)
- `<C-Space>` to multi-select, then `<C-q>` to pin filtered subset
- Append ripgrep args in live grep: `Foo -- --word-regexp --case-sensitive`
- After `<C-q>` pin, recover the picker with `<leader>s/` (csearch → rg)

## Trouble / Quickfix / Diagnostics

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>xx`     | Open diagnostics (Trouble)              |
| `<leader>xX`     | Buffer diagnostics                      |
| `<leader>xQ`     | Quickfix list                           |
| `<leader>xL`     | Location list                           |
| `[d` / `]d`      | Previous / next diagnostic              |
| `[e` / `]e`      | Previous / next error                   |
| `[w` / `]w`      | Previous / next warning                 |
| `<leader>cd`     | Line diagnostics                        |
| `:copen` / `:cclose` | Open / close quickfix              |
| `:cnext` / `:cprev` | Navigate quickfix                   |
| `:cdo {cmd}`     | Run cmd on every quickfix entry         |

## Left Sidebar / Workbench

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
| `<S-h>` / `<S-l>`    | Previous / next buffer               |
| `<leader>bb`          | Switch to other buffer               |
| `<leader>bn`          | New empty buffer                     |
| `<leader>bd`          | Delete buffer                        |
| `<leader>bo`          | Delete other buffers                 |
| `<leader>bp`          | Toggle pin buffer                    |
| `<leader>bD`          | Delete buffer and window             |
| `<leader>bc`          | Smart close: window/buffer/float     |
| `<leader>-`           | Horizontal split                     |
| `<leader>\|`          | Vertical split                       |
| `<C-h/j/k/l>`         | Move between windows                 |
| `<leader>wd`          | Delete window                        |
| `<leader>wm`          | Maximize / restore window            |
| `<leader><tab><tab>`  | New tab                              |
| `<leader><tab>[/]`    | Previous / next tab                  |
| `<leader><tab>d`      | Close tab                            |
| `<leader><tab>o`      | Close other tabs                     |

## Terminal / Shell

Single source of truth: **LazyVim built-in** `<C-/>`.

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<C-/>` / `<C-_>`| Toggle root terminal (LazyVim built-in) |
| `<leader>ft`     | Float terminal at root                  |
| `<leader>fT`     | Float terminal at cwd                   |
| `<leader>tc`     | Open bottom term + cd to current file dir |
| `<leader>tp`     | Open bottom term + cd to UE project root  |
| `<leader>te`     | Open bottom term + cd to UE engine root   |
| `<Esc>`          | Exit terminal mode → Normal             |

`<leader>tc/tp/te` are different from `<C-/>`: they spawn a controlled
bottom-split terminal so the config can inject a `cd ...` command into
it. `<C-/>` is for a fast scratch shell.

## Git

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `]h` / `[h`      | Next / previous hunk                   |
| `]H` / `[H`      | Last / first hunk                      |
| `<leader>gg/gG`  | Lazygit                                |
| `<leader>gb`     | Git blame line                          |
| `<leader>gf`     | Git file history                        |
| `<leader>gl/gL`  | Git log                                |
| `<leader>gs`     | Git status                              |
| `<leader>gS`     | Git stash                               |
| `<leader>gd`     | Diff hunks                              |
| `<leader>gD`     | Diff against origin                     |
| `<leader>gv/gV`  | Diffview open / close                   |
| `<leader>gvf`    | Diffview: this file history             |
| `<leader>gvb`    | Diffview: branch history                |
| `<leader>gvc`    | Diffview: last commit (HEAD~1)          |
| `<leader>gvm`    | Diffview: vs origin/HEAD                |
| `]c` / `[c`      | (in diff) Next/prev hunk in current file|
| `]h` / `[h`      | (in diff) Next/prev hunk, cross file    |
| `]x` / `[x`      | (in diff) Next/prev merge conflict      |
| `<tab>` / `<s-tab>` | (in diff) Next/prev file             |
| `<leader>gB`     | Open file in browser                    |
| `<leader>gY`     | Copy repo URL                           |

This config uses `[h` / `]h` for hunk nav, **not** `[c` / `]c` — `[c` is
treesitter context jump.

## UI / Toggles

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>ut`     | Theme picker                            |
| `:Theme`         | Open theme picker                       |
| `:Theme <name>`  | Set and persist theme                   |
| `<leader>uf`     | Toggle format on save                   |
| `<leader>uF`     | Force format mode                       |
| `<leader>ud`     | Toggle diagnostics                      |
| `<leader>us`     | Toggle spelling                         |
| `<leader>uw`     | Toggle word wrap                        |
| `<leader>uh`     | Toggle inlay hints                      |
| `<leader>uG`     | Toggle git signs                        |
| `<leader>uT`     | Toggle treesitter                       |
| `<leader>uz`     | Zen mode                                |
| `<leader>ur`     | Redraw + clear search highlight         |
| `<leader>un`     | Dismiss notifications                   |

Note: some `u` prefix keys are overridden by UE/Android workflow
(`ub`/`ui`/`ul`/`uL`/`uD`/`up`).

## Windows Custom

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>E`      | Reveal current file in Explorer         |
| `<leader>oe`     | Same as above                           |
| `:RevealInExplorer` | Direct command                       |

---

## UE Workflow

| Key / Command             | Action                              |
|---------------------------|-------------------------------------|
| `<leader>uj`              | Set project root / `.uproject`      |
| `<leader>uP`              | Same (legacy key)                   |
| `:UESetPlatform`           | Interactive platform+config select |
| `:UESetPlatform Win64 Development Editor` | Direct set          |
| `<leader>ub`              | Build (platform from :UESetPlatform) |
| `<leader>ue`              | Run UEPrepare (index + cc)          |
| `<leader>uB`              | Same (legacy key)                   |
| `<leader>uc`              | Export compile_commands.json        |
| `<leader>ul`              | Launch app (no debugger)            |
| `<leader>ui`              | Install APK to device               |
| `<leader>ug`              | Toggle app log                      |
| `<leader>uv`              | Toggle Windows debug log            |
| `<leader>uo` / `<leader>uO` | Find file / grep in current module |
| `<leader>up`              | Show current UE paths               |
| `<leader>?`               | Open this cheatsheet                |
| `:UEClearCache`            | Clear nvim-ue + clangd caches      |
| `:UEClearCache!`           | Above + rm compile_commands + restart clangd |
| `:UECheatsheetEdit`        | Edit this markdown file            |
| `:UEDefStatus`             | Show LSP→GTAGS→rg fallback state   |

Typical Win64 workflow:
1. `:UESetPlatform Win64 Development Editor`
2. `:UEExportCompileCommands` (or `<leader>uc`)
3. Open code, use `gd` / `gr` / `<leader>ss` / `<leader>/`

## Android DAP

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>da`     | Attach to Android process               |
| `<leader>db`     | Toggle hardware breakpoint              |
| `<leader>dc`     | Continue                                |
| `<leader>dp`     | Pause                                   |
| `<leader>dn`     | Step over                               |
| `<leader>di`     | Step in                                 |
| `<leader>do`     | Step out                                |
| `<leader>dl`     | Launch debug (auto-attach)              |
| `<leader>du`     | Toggle DAP UI                           |
| `<leader>dr`     | Toggle REPL                             |
| `<leader>dx`     | Reset DAP layout                        |
| `:UESetAndroidPackage <pkg>` | Set attach package name        |
| `F9`             | Toggle hardware breakpoint              |
| `F5`             | Continue                                |
| `F6`             | Pause                                   |
| `F10`            | Step over                               |

Quick reference (all lowercase, in order):
- `Space ub` build → `Space ui` install → `Space da` attach
- `Space dl` launch debug
- `Space dc` continue, `Space dp` pause
- `Space dn` step over, `Space di` step in, `Space do` step out
- `Space db` breakpoint, `Space du` DAP UI, `Space dr` REPL, `Space dx` reset

`:qa` auto-cleans DAP session.

---

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

## Debug Log (persistent error trail)

All ERROR-level `vim.notify` calls and key job/process callback failures are also written to a rotating log file on disk, so problems that flash by once can still be inspected later (great for AI/manual debugging).

| Command                        | Action                                                                 |
|--------------------------------|------------------------------------------------------------------------|
| `:NvimLog`                     | Open the current log file in a new tab                                 |
| `:NvimLogPath`                 | Echo + yank the absolute path of the active log file                   |
| `:NvimLogClear`                | Truncate + rotate (keeps `.1`–`.5` backups)                            |
| `:NvimLogLevel <lvl>`          | Set global threshold: `trace`/`debug`/`info`/`warn`/`error` (default `warn`) |
| `:NvimLogScope <scope> <lvl>`  | Per-scope override (use `clear` to remove); no args = list overrides   |

- File: `stdpath('log')/nvim/nvim-debug.log` → on this box `<LOCAL_APPDATA>\nvim-data\nvim\nvim-debug.log`
- Rotation: per-file cap **2 MB**, keeps **5** rolling backups (`.1` … `.5`); old ones drop off the tail
- Default level is **WARN**: only `warn`/`error` land on disk. Raise to `info`/`debug`/`trace` via `:NvimLogLevel` for noisier sessions; reset back when done.
- Format: `ISO-time LEVEL [scope] message [k=v ...] | short_src:line`
- Scopes you'll see: `ue` / `ue.build` / `ue.prepare` / `ue.android` / `ue.pch` / `ue.io` / `dap` / `dap.bp` / `dap.pause` / `dap.aslr` / `yazi` / `theme` / `workarounds` / `sidebar` / `snacks` / `windows` / `ue_logs` / `ue_launch` / `smoke`
- Want only `ue.dap` chatter? `:NvimLogScope ue.dap debug` then reproduce. `:NvimLogScope ue.dap clear` to remove.
- A red `vim.notify(..., ERROR)` you missed? Tail the file:

  ```bash
  tail -f "$LOCALAPPDATA/nvim-data/nvim/nvim-debug.log"
  ```

- Lua module authors: prefer `local L = require("utils.log").scoped("my.scope")` then `L.error(...)` / `L.error_ctx("msg", {k=v})` / `L.notify_error("...")` / `L.wrap_job{cmd=...}`. Fast-event safe (libuv timer/job callbacks ok).

## When Stuck
- `<leader>sk` — search keymaps for the action you want
- `<leader>sh` — search help
- `<leader>?`  — open this cheatsheet floating
- `:help motion.txt`
- `:help usr_28`
- `:help folds`
- `:help quickfix`

## Cheatsheet Float Window

| Key                  | Action         |
|----------------------|----------------|
| `q` / `<Esc>`        | Close          |
| `<Tab>` / `<S-Tab>`  | Next / prev category tab |
| `1` … `9`            | Jump to tab N  |
| `j` / `k`            | Move           |
| `<C-f>` / `<C-b>`    | Page down / up |
| `gg` / `G`           | Top / bottom   |
