# Neovim + LazyVim Development Handbook

Covers everything from raw Vim fundamentals to LazyVim workflows and UE/Android DAP.

## How to Use This Document
- `:UECheatsheet` opens this file in preview float
- `:UECheatsheetEdit` opens for raw editing
- `:MarkdownPreview` / `:MarkdownEdit` / `:MarkdownPreviewToggle` for render control
- Path: `docs/ue_lazyvim_cheatsheet.md`
- Convention: keep this file in sync whenever keymaps change

## Start Here
- `Space` is `<leader>`
- `Hold <leader>` to open which-key and discover available prefixes
- `<leader>sk` search keymaps
- `<leader>sh` search help
- `<leader><space>` find files
- `<leader>/` grep in project
- `gd` / `gr` go to definition / references
- `u` undo, `Ctrl-r` redo, `.` repeat last change

---

## Vim Fundamentals — Modes

| Mode     | Enter              | Purpose                       |
|----------|--------------------|-------------------------------|
| Normal   | `<Esc>`            | Navigate, delete, copy, jump  |
| Insert   | `i` `a` `o` etc    | Type text                     |
| Visual   | `v` `V` `Ctrl-v`   | Select regions                |
| Command  | `:`                | Ex commands (`:w` `:q` `:s`)  |
| Terminal | `:term` or toggle  | Shell input, `<Esc>` to exit  |

## Vim Fundamentals — Motions

| Key                    | Action                              |
|------------------------|-------------------------------------|
| `h` `j` `k` `l`       | Left / Down / Up / Right            |
| `w` / `W`              | Next word / WORD start              |
| `b` / `B`              | Previous word / WORD start          |
| `e` / `E`              | End of word / WORD                  |
| `0` / `^` / `$`        | Line start / first char / line end  |
| `gg` / `G`             | File start / file end               |
| `42G`                  | Go to line 42                       |
| `{` / `}`              | Previous / next paragraph           |
| `(` / `)`              | Previous / next sentence            |
| `%`                    | Jump to matching bracket/tag        |
| `f{c}` / `F{c}`       | Find char forward / backward        |
| `t{c}` / `T{c}`       | Till char forward / backward        |
| `;` / `,`              | Repeat f/F/t/T forward / backward   |
| `Ctrl-d` / `Ctrl-u`   | Half page down / up                 |
| `Ctrl-f` / `Ctrl-b`   | Full page down / up                 |
| `H` / `M` / `L`       | Screen top / middle / bottom        |
| `zz` / `zt` / `zb`    | Center / top / bottom cursor line   |
| `Ctrl-o` / `Ctrl-i`   | Jump back / forward in jump list    |

## Vim Fundamentals — Editing

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `i` / `a`        | Insert before / after cursor            |
| `I` / `A`        | Insert at line start / end              |
| `o` / `O`        | New line below / above                  |
| `x` / `X`        | Delete char forward / backward          |
| `r{c}`           | Replace single char                     |
| `R`              | Enter replace mode                      |
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
| `.`              | Repeat last change                      |
| `u` / `Ctrl-r`   | Undo / redo                             |

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

## Vim Fundamentals — Visual Mode

| Key                     | Action                             |
|-------------------------|------------------------------------|
| `v`                     | Character-wise visual              |
| `V`                     | Line-wise visual                   |
| `Ctrl-v`                | Block visual (column select)       |
| `gv`                    | Reselect last visual               |
| `o`                     | Jump to other end of selection     |
| `>` / `<`               | Indent / unindent selection        |
| `=`                     | Auto-indent selection              |
| `:'<,'>s/old/new/g`     | Substitute in visual selection     |

## Vim Fundamentals — Search & Replace

| Key                     | Action                             |
|-------------------------|------------------------------------|
| `/{pattern}`            | Search forward                     |
| `?{pattern}`            | Search backward                    |
| `n` / `N`               | Next / previous match              |
| `*` / `#`               | Search word under cursor fwd / bwd |
| `:s/old/new/g`          | Replace in current line            |
| `:%s/old/new/gc`        | Replace all in file with confirm   |
| `:%s/\<Name\>/New/gc`   | Replace exact word                 |
| `:noh`                  | Clear search highlight             |

## Vim Fundamentals — Marks & Jumps

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `m{a-z}`         | Set local mark                          |
| `m{A-Z}`         | Set global mark                         |
| `` `{mark} ``    | Jump to mark (exact position)           |
| `'{mark}`        | Jump to mark (line start)               |
| `` `` ``         | Jump to last position before jump       |
| `Ctrl-o`         | Jump back in jump list                  |
| `Ctrl-i`         | Jump forward in jump list               |
| `gi`             | Go to last insert position and insert   |
| `gv`             | Reselect last visual selection          |

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
| `Ctrl-a` / `Ctrl-x`   | Increment / decrement number        |
| `gf`                   | Go to file under cursor             |
| `gx`                   | Open URL under cursor               |
| `ga`                   | Show char code under cursor         |
| `Ctrl-g`               | Show file info                      |
| `:!{cmd}`              | Run shell command                   |
| `:r !{cmd}`            | Insert shell command output         |
| `ZZ`                   | Save and quit                       |
| `ZQ`                   | Quit without saving                 |

---

## LSP Navigation

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `gd`             | Go to definition (LSP → GTAGS → rg)    |
| `gr`             | References (LSP → GTAGS fallback)       |
| `gD`             | Go to declaration                       |
| `gI`             | Go to implementation                    |
| `gy`             | Go to type definition                   |
| `gai` / `gao`   | Incoming / outgoing calls               |
| `K`              | Hover documentation                     |
| `gK`             | Signature help                          |
| `Ctrl-k` (ins)   | Signature help in insert mode           |
| `Ctrl+LMB`       | Smart jump: `gf` if file ref, else `gd` |
| `<leader>ca`     | Code action                             |
| `<leader>cr`     | Rename symbol                           |
| `<leader>cf`     | Format buffer or selection              |
| `<leader>cd`     | Line diagnostics                        |
| `<leader>cl`     | LSP info                                |
| `<leader>ss`     | Document symbols                        |
| `<leader>sS`     | Workspace symbols                       |
| `<leader>sr`     | Search & replace tool (cross-file)      |
| `gc`             | Comment operator                        |
| `gcc`            | Comment current line                    |
| `gco` / `gcO`    | Insert comment line below / above       |

## Picker / Search

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader><space>`| Find workspace files                    |
| `<leader>ff`     | Find project files                      |
| `<leader>fF`     | Find workspace code files               |
| `<leader>fa`     | Find project code files                 |
| `<leader>fg`     | Find git files (UE-aware)               |
| `<leader>,`      | Buffers                                 |
| `<leader>;`      | Search all commands, Enter to execute   |
| `<leader>:`      | Command history                         |
| `<leader>fr/fR`  | Recent files                            |
| `<leader>fC`     | Clear file/grep picker history          |
| `<leader>/`      | Grep project code                       |
| `<leader>sg`     | Grep workspace code                     |
| `<leader>sG`     | Grep workspace all files                |
| `<leader>sw/sW`  | Search current word or selection        |
| `<leader>sy/sY`  | Live grep with current word prefilled   |
| `<leader>sx`     | Grep whole word match                   |
| `<leader>sX`     | Grep case-sensitive                     |
| `<leader>sH`     | Grep history                            |
| `<leader>sC`     | Clear grep/files history                |
| `<leader>sR`     | Resume last picker                      |
| `<leader>sk`     | Keymaps                                 |
| `<leader>sh`     | Help tags                               |
| `<leader>sm`     | Marks                                   |

## Grep Tips
- Default is smart-case: `foo` is case-insensitive, `Foo` is case-sensitive
- `<leader>sw` searches current word/selection directly
- `<leader>sy` prefills current word into live grep for further editing
- `<leader>sx` for whole-word match, `<leader>sX` for case-sensitive
- In any Snacks picker: `<C-q>` sends results to quickfix (auto-opens sidebar)
- `<C-Space>` to multi-select, then `<C-q>` to pin filtered subset
- Append ripgrep args in live grep: `Foo -- --word-regexp --case-sensitive`

## Trouble / Quickfix / Diagnostics

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>xx`     | Open diagnostics                        |
| `<leader>xX`     | Buffer diagnostics                      |
| `<leader>xQ`     | Quickfix list                           |
| `<leader>xL`     | Location list                           |
| `[d` / `]d`      | Previous / next diagnostic              |
| `[e` / `]e`      | Previous / next error                   |
| `[w` / `]w`      | Previous / next warning                 |
| `<leader>cd`     | Line diagnostics                        |
| `:copen/:cclose` | Open / close quickfix                   |
| `:cnext/:cprev`  | Navigate quickfix                       |

## Left Sidebar / Workbench

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>va`     | Sidebar view menu (1-7 direct, j/k+Enter) |
| `<leader>vv`     | Toggle left sidebar                     |
| `<leader>vg`     | Git modified files / status             |
| `<leader>vb`     | Open buffers                            |
| `<leader>vs`     | File symbols                            |
| `<leader>vd`     | Diagnostics                             |
| `<leader>vq`     | Quickfix results                        |
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
| `<leader>bD`          | Delete buffer and window             |
| `<leader>-`           | Horizontal split                     |
| `<leader>\|`          | Vertical split                       |
| `Ctrl-w h/j/k/l`     | Move between windows                 |
| `<leader>wd`          | Delete window                        |
| `<leader>wm`          | Maximize / restore window            |
| `<leader><tab><tab>`  | New tab                              |
| `<leader><tab>[/]`    | Previous / next tab                  |
| `<leader><tab>d`      | Close tab                            |
| `<leader><tab>o`      | Close other tabs                     |

## Terminal / Shell

| Key              | Action                                  |
|------------------|-----------------------------------------|
| `<leader>ft`     | Float terminal (root)                   |
| `<leader>fT`     | Float terminal (cwd)                    |
| `<C-/>` / `<C-_>`| Toggle root terminal                   |
| `<leader>tt`     | Toggle bottom terminal (reuses buffer)  |
| `<leader>t`      | Same as `<leader>tt`                    |
| `<leader>tc`     | Terminal cd to current file dir         |
| `<leader>tp`     | Terminal cd to project dir              |
| `<leader>te`     | Terminal cd to UE engine dir            |
| `<Esc>`          | Exit terminal mode to Normal            |

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
| `<leader>gB`     | Open file in browser                    |
| `<leader>gY`     | Copy repo URL                           |

Note: this config uses `[h`/`]h` for hunk navigation, not `[c`/`]c`.

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
| `<leader>uZ`     | Zen zoom alias                          |
| `<leader>ur`     | Redraw + clear search highlight         |

Note: some `u` prefix keys are overridden by UE/Android workflow (`ub`/`ui`/`ul`/`uL`/`uD`/`up`).

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
| `<leader>ub`              | Android Development build           |
| `<leader>ue`              | Run UEPrepare                       |
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

Typical Win64 workflow:
1. `:UESetPlatform Win64 Development Editor`
2. `:UEExportCompileCommands`
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

Quick reference (all lowercase):
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
- For large files: marks + jumps + folds: `ma` to mark, `Ctrl-o` to return, `zM`/`zo`/`zc`
- To avoid polluting register: `"_d`
- After each small edit: remember `.` to repeat quickly

## Essential Builtins to Memorize
- `u` / `Ctrl-r` — undo / redo
- `.` — repeat last change
- `*` / `#` — search current word
- `%` — matching bracket
- `ma` / `'a` / `` `a `` — marks
- `qa` / `@a` — macros
- `zc` / `zo` / `za` — fold single
- `zM` / `zR` — fold all / open all

## When Stuck
- `<leader>sk` search keymaps for the action you want
- `<leader>sh` search help
- `:help motion.txt`
- `:help usr_28`
- `:help folds`
- `:help quickfix`

## Cheatsheet Window
| Key                  | Action         |
|----------------------|----------------|
| `q` / `<Esc>`        | Close         |
| `j` / `k`            | Move          |
| `Ctrl-f` / `Ctrl-b`  | Page down/up  |
| `gg` / `G`            | Top / bottom |
