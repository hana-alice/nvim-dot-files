# LazyVim + Neovim Cheatsheet

这份速查表按你当前这套配置整理:
- LazyVim
- `snacks.nvim` picker
- `trouble.nvim`
- 你自己的 UE / Windows 自定义

## 先记住这几个
- `按 <leader> 后停一下` 打开 which-key，直接看当前可用前缀
- `<leader>?` 当前 buffer 的本地快捷键
- `<leader>sk` 查看全部 keymaps
- `<leader>sh` 查看 help tags
- `<leader><space>` 当前 root 下找文件
- `<leader>/` 当前 root 下全文 grep
- `<leader>ss` 当前文件 symbols
- `<leader>sS` workspace symbols
- `<leader>cs` 用 Trouble 打开 symbols outline

## Search / Picker
- `<leader><space>` Find Files (root)
- `<leader>,` Buffers
- `<leader>/` Grep project code (C++/Shader only, excludes intermediates)
- `<leader>:` Command history
- `<leader>ff` Find project code files (C++/Shader only)
- `<leader>fF` Find workspace code files (engine + project, C++/Shader)
- `<leader>fa` Find workspace all files (no type filter)
- `<leader>fg` Git files in current UE project
- `<leader>fr` Recent files
- `<leader>fR` Recent files (cwd)
- `<leader>fp` Projects
- `<leader>fb` Buffers
- `<leader>fB` All buffers
- `<leader>fc` Find config files
- `<leader>uo` Find code files in current UE module/plugin
- `<leader>uO` Grep code in current UE module/plugin

## Symbols / LSP / Code Nav
- `gd` Definition
- `gr` References
- `<leader>ch` Switch header / source (`clangd`)
- `gI` Implementations
- `gy` Type definition
- `gai` Incoming calls
- `gao` Outgoing calls
- `<leader>ss` Document symbols
- `<leader>sS` Workspace symbols
- `<leader>cs` Symbols outline in Trouble
- `<leader>cS` LSP items in Trouble
- `<leader>cd` Line diagnostics
- `[d` / `]d` Prev / next diagnostic
- `[e` / `]e` Prev / next error
- `[w` / `]w` Prev / next warning
- `<leader>cl` LSP info
- `<leader>K` Keyword help

## Search Inside Code
- `<leader>sb` Current buffer lines
- `<leader>sB` Grep open buffers
- `<leader>sg` Grep workspace code (C++/Shader, engine + project)
- `<leader>sG` Grep workspace all files (no type filter)
- `<leader>sw` Search current word or visual selection (root)
- `<leader>sW` Search current word or visual selection (cwd)
- `<leader>sx` Grep whole word (root)
- `<leader>sX` Grep case-sensitive (root)
- `<leader>sy` Live grep current word or visual selection (root)
- `<leader>sY` Live grep current word or visual selection (cwd)
- `<leader>sd` Diagnostics
- `<leader>sD` Buffer diagnostics
- `<leader>sq` Quickfix list
- `<leader>sl` Location list
- `<leader>sj` Jumps
- `<leader>sm` Marks
- `<leader>su` Undo history
- `<leader>sR` Resume last picker
- `<leader>sp` Search plugin specs
- `<leader>sr` Search and replace (`grug-far`)
- `<leader>st` Todo comments
- `<leader>sT` Todo/Fix/Fixme comments

## Live Grep Tips
- 默认是 `smart-case`: 搜 `foo` 忽略大小写，搜 `Foo` 自动区分大小写
- `<leader>sw` / `<leader>sW` 是直接搜当前词或选区，不是 live 模式
- `<leader>sy` / `<leader>sY` 会把当前词或选区预填进 livegrep，可继续改关键字
- 在 livegrep 输入里可追加 ripgrep 参数: `foo -- --word-regexp`
- 强制全字匹配: `foo -- --word-regexp`
- 强制区分大小写: `foo -- --case-sensitive`
- 两个一起用: `Foo -- --word-regexp --case-sensitive`

## Editing
- `<C-s>` Save file
- `<leader>cf` Format
- `s` Flash jump
- `S` Flash Treesitter
- `r` Remote Flash in operator-pending mode
- `R` Treesitter search in operator/visual mode
- `<A-j>` / `<A-k>` Move current line or selection
- `gco` Add comment below
- `gcO` Add comment above

## Buffers / Windows / Tabs
- `<S-h>` / `<S-l>` Prev / next buffer
- `<leader>bb` Switch to other buffer
- `<leader>bn` New empty buffer
- `<leader>bd` Delete buffer
- `<leader>bo` Delete other buffers
- `<leader>bD` Delete buffer and window
- `<leader>-` Horizontal split
- `<leader>|` Vertical split
- `<leader>wd` Delete window
- `<leader>wm` Toggle zoom window
- `<leader><tab><tab>` New tab
- `<leader><tab>[` Previous tab
- `<leader><tab>]` Next tab
- `<leader><tab>d` Close tab
- `<leader><tab>o` Close other tabs
- `<leader><tab>f` First tab
- `<leader><tab>l` Last tab

## Terminal
- `<leader>ft` Floating terminal at project root
- `<leader>fT` Floating terminal at cwd
- `<C-/>` Toggle root terminal
- `<C-_>` Same as `<C-/>` on some terminals
- `<leader>tt` Toggle bottom terminal and reuse buffer
- `<leader>t` Same as `<leader>tt`
- `<leader>tc` Terminal `cd` to current file dir
- `<leader>tp` Terminal `cd` to current project root
- `<leader>te` Terminal `cd` to UE engine root
- `terminal mode <Esc>` Exit terminal mode

## Git
- `<leader>gg` Lazygit (root)
- `<leader>gG` Lazygit (cwd)
- `<leader>gb` Git blame line
- `<leader>gf` Git current file history
- `<leader>gl` Git log (root)
- `<leader>gL` Git log (cwd)
- `<leader>gB` Git browse in browser
- `<leader>gY` Git browse and copy URL
- `<leader>gd` Git diff hunks
- `<leader>gD` Git diff against origin
- `<leader>gs` Git status
- `<leader>gS` Git stash

## Trouble / Quickfix
- `<leader>xx` Diagnostics (Trouble)
- `<leader>xX` Buffer diagnostics (Trouble)
- `<leader>xL` Location list (Trouble)
- `<leader>xQ` Quickfix list (Trouble)
- `<leader>xq` Toggle quickfix list
- `<leader>xl` Toggle location list
- `[q` / `]q` Prev / next Trouble or quickfix item

## UI / Toggle / Theme
- `<leader>ut` Theme picker
- `<leader>uC` Colorscheme picker
- `:Theme` Open theme picker
- `:Theme <name>` Set and persist theme
- `<leader>uf` Format on save
- `<leader>uF` Force format on save mode
- `<leader>ud` Diagnostics
- `<leader>us` Spelling
- `<leader>uw` Wrap
- `<leader>ul` Line numbers
- `<leader>uL` Relative numbers
- `<leader>uh` Inlay hints
- `<leader>uG` Git signs
- `<leader>uT` Treesitter
- `<leader>uZ` Zen zoom alias
- `<leader>uz` Zen mode
- `<leader>ui` Inspect position
- `<leader>uI` Inspect Treesitter tree
- `<leader>ur` Redraw and clear search highlight

## Windows Custom
- `<leader>E` Reveal current file in Explorer
- `<leader>oe` Same as `<leader>E`
- `:RevealInExplorer` Reveal current file in Explorer

## UE Custom
- `<leader>uP` Set project root or `.uproject`
- `:UESetAndroidPackage <pkg>` Persist Android package name for DAP attach
- `<leader>uB` Run `UEPrepare`
- `<leader>uc` Export `compile_commands.json`
- `<leader>ub` Build Android Development with Windows `Build.bat`
- `<leader>ui` Install built APK to connected Android device
- `<leader>uo` Find files in current module/plugin
- `<leader>uO` Grep in current module/plugin
- `<leader>up` Show current UE paths
- `:UECheatsheet` Open this cheatsheet
- `:UECheatsheetEdit` Edit this markdown file
- `UEBuildAndroid` / `UEPrepare` / `UEExportCompileCommands` 失败时会自动把错误塞进 quickfix
- lualine 里的 UE 状态会显示类似 `M:Foo IDX BOK` / `P:Bar IDX! B6`

## Android DAP (Debug)
- `<leader>da` Attach to Android process (auto ASLR fix + resume)
- `<leader>dL` Launch app in debug mode (force-stop + start -D + auto-attach)
- `:UESetAndroidPackage <pkg>` Set the Android package used by `UEAndroidDAPAttach`
- `F9` Toggle hardware breakpoint (works with or without DAP session; pending BPs apply on attach)
- `F5` Continue
- `F6` Pause
- `F10` Step Over
- `<leader>di` Step In
- `<leader>do` Step Out
- `<leader>du` Toggle DAP UI (auto save/restore window layout)
- `<leader>dr` Toggle REPL
- `<leader>dR` Reset layout (re-open DAP UI if debugging, otherwise `:only`)
- `:qa` auto-cleanup: disconnect DAP, kill CodeLLDB, kill remote lldb-server
- Only hardware breakpoints (`-H`) work; software BPs cannot write to remote Android memory
- F9 can be used **before** attaching — breakpoints are saved as pending and auto-applied after ASLR fix on attach/launch
- Globals/Static scopes are filtered out to prevent LLDB from enumerating millions of symbols

## Explorer / Discovery
- `<leader>e` Explorer (root)
- `<leader>E` 当前被你改成 Reveal in Explorer，不再是文件树别名
- `<leader>sk` Keymaps picker
- `<leader>n` Notification history
- `<leader>l` Open Lazy
- `<leader>L` LazyVim changelog

## Nvim Basics
- `:q` Quit
- `:w` Write
- `:wa` Write all
- `:qa` Quit all
- `<leader>qq` Quit all
- `zz` Center current line
- `*` Search word under cursor
- `n` / `N` Next / prev search result
- `%` Jump matching pair
- `m{a-z}` Set mark
- `'{a-z}` Jump to mark line
- `` `{a-z} `` Jump to exact mark position

## Cheatsheet Window
- `q` / `<Esc>` Close
- `j` / `k` Move
- `<C-f>` / `<C-b>` Page down / up
- `gg` / `G` Jump to top / bottom
