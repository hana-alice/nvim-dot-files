# Neovim + LazyVim Development Handbook

这份文档按你当前这套配置整理，目标不是罗列所有命令，而是覆盖高频开发动作：
- 基础操作
- 读代码与导航
- 搜索与批量修改
- 折叠与大文件阅读
- 窗口、buffer、terminal、git
- UE / Android DAP 工作流

## 文档入口
- `:UECheatsheet` 默认以预览模式打开这份手册
- 在 markdown 里，Normal 模式看渲染后的预览，按 `i` 进入 Insert 后会回到原始 markdown 方便编辑
- `:UECheatsheetEdit` 强制原文编辑这份手册，不走渲染预览
- `:MarkdownPreview` 当前 markdown buffer 开启渲染预览
- `:MarkdownEdit` 当前 markdown buffer 关闭预览，回到原始 markdown
- `:MarkdownPreviewToggle` 当前 markdown buffer 切换预览 / 原文
- 文档路径：`docs/ue_lazyvim_cheatsheet.md`
- 维护约定：以后所有快捷键新增、删除、改动，都要同步更新这份手册

## 先记住这几个
- `Space` 是 `<leader>`
- `按 <leader> 后停一下` 打开 which-key，看当前可用前缀
- `<leader>sk` 搜索 keymaps
- `<leader>sh` 搜索帮助文档
- `<leader><space>` 找文件
- `<leader>/` 在项目里 grep
- `gd` / `gr` 跳定义 / 查引用
- `u` 撤销，`Ctrl-r` 重做，`.` 重复上一次修改

## 模式基础
- Normal 模式：导航、删除、复制、跳转
- Insert 模式：输入文本
- Visual 模式：选区操作
- Command 模式：执行 `:w`、`:q`、`:s` 之类命令
- Terminal 模式：终端输入，`<Esc>` 退出回 Normal

## 基础移动
- `h j k l` 左下上右
- `w` / `b` / `e` 下一个词开头、上一个词开头、词结尾
- `0` / `^` / `$` 行首、首个非空字符、行尾
- `gg` / `G` 文件头、文件尾
- `42G` 跳到第 42 行
- `%` 在括号、花括号、标签对之间跳转
- `f<char>` / `t<char>` 行内跳到字符 / 跳到字符前
- `;` / `,` 重复上一次 `f t F T`
- `zz` 把当前行滚到屏幕中间
- `Ctrl-o` / `Ctrl-i` 回到上一个 / 下一个跳转位置

## 搜索与定位
- `/text` 向下搜索
- `?text` 向上搜索
- `n` / `N` 下一个 / 上一个结果
- `*` / `#` 搜当前单词，向下 / 向上
- `gd` 定义
- `gr` 引用
- `gI` 实现
- `gy` 类型定义
- `gai` / `gao` incoming / outgoing calls
- `<leader>ss` 当前文件 symbols
- `<leader>sS` workspace symbols
- `Ctrl + LeftMouse` 智能跳转：文件引用优先 `gf`，否则走定义

## 选区与 text objects
- `viw` / `vaw` 选中 inner word / around word
- `ciw` 改当前词
- `diw` 删当前词
- `ci"` / `ci'` / `ci(` / `ci{` 改引号或括号内部
- `da"` / `da(` / `da{` 删除包含边界的文本对象
- `vip` / `vap` 选段落
- `vit` / `vat` 选 tag 内部 / 外围
- `gc` 注释 operator
- `gcc` 注释当前行
- `gco` / `gcO` 在下方 / 上方插入注释行

## 编辑高频动作
- `i a I A o O` 在不同位置进入插入模式
- `x` / `X` 删除光标后 / 前字符
- `dd` 删整行
- `yy` 复制整行
- `p` / `P` 在后 / 前粘贴
- `>>` / `<<` 缩进 / 反缩进
- `J` 合并下一行
- `.` 重复上一次修改，做重复编辑时非常有用
- `<C-s>` 保存当前文件
- `<leader>cf` 格式化
- `<A-j>` / `<A-k>` 上下移动当前行或选区

## 寄存器、标记、宏
- `"+y` / `"+p` 用系统剪贴板复制 / 粘贴
- `"_d` 删除但不污染默认寄存器
- `"0p` 粘贴最近一次 yank 的内容
- `ma` 设置 mark `a`
- `'a` 跳到 mark 所在行
- `` `a `` 跳到 mark 精确位置
- `qa` 开始录制宏到寄存器 `a`
- `q` 结束录制
- `@a` 执行宏
- `@@` 重复上一个宏

## 搜索与替换
- `:s/old/new/g` 当前行替换
- `:%s/old/new/gc` 全文件替换并确认
- `:%s/\<Name\>/NewName/gc` 精确替换完整单词
- `<leader>sr` 进入搜索替换工具，适合跨文件改名
- 先 `gr` 看引用，再做替换，风险更低

## 折叠与大文件阅读
当前配置默认没有强行启用“打开文件就自动折叠”，而且 `foldenable` 默认关闭。需要折叠时先确认当前 buffer 有 fold，或者临时开启：
- `zi` 开关 fold 功能
- `:setlocal foldenable` 开启当前 buffer 的 fold
- `:setlocal foldmethod=indent` 用缩进快速创建折叠
- 如果当前语言已有 fold provider，再直接用下面这些命令

常用折叠操作：
- `zc` 折叠当前节点
- `zo` 展开当前节点
- `za` 切换当前节点折叠状态
- `zC` 递归折叠当前节点
- `zO` 递归展开当前节点
- `zA` 递归切换当前节点
- `zM` 折叠全部
- `zR` 展开全部
- `zm` 增加折叠级别
- `zr` 减少折叠级别
- `zj` / `zk` 跳到下一个 / 上一个 fold

手工折叠也很有用：
- `zf{motion}` 按 motion 创建折叠，例如 `zfap`
- Visual 选中一段后 `zf`，把选区折成一块
- `zd` 删除当前折叠
- `zE` 删除所有手工折叠

读大文件的推荐手法：
- 先 `zM` 折叠全部，只看结构
- 用 `zj` / `zk` 在函数之间跳
- 对感兴趣的函数 `zo`
- 看完后 `zc`
- 需要回到全局再 `zM` 或 `zR`

## Picker / Search
- `<leader><space>` 找 workspace 所有文件
- `<leader>ff` 找项目文件
- `<leader>fF` 找 workspace code 文件
- `<leader>fa` 找项目 code 文件
- `<leader>fg` 找当前 UE 项目的 git files
- `<leader>,` buffers
- `<leader>;` 搜索所有可用 command，选中后回车直接执行
- `<leader>:` 命令历史
- `<leader>fr` / `<leader>fR` recent files
- `<leader>fC` 清理 file/grep picker history
- `<leader>/` grep 项目代码
- `<leader>sg` grep workspace code
- `<leader>sG` grep workspace all files
- `<leader>sw` / `<leader>sW` 搜当前词或选区
- `<leader>sy` / `<leader>sY` live grep 当前词或选区
- `<leader>sx` 全词匹配 grep
- `<leader>sX` 区分大小写 grep
- `<leader>sH` grep history
- `<leader>sC` 清理 grep / files history
- `<leader>sR` 恢复上一次 picker

## Grep 使用技巧
- 默认是 smart-case：搜 `foo` 不区分大小写，搜 `Foo` 自动区分
- `<leader>sw` 是直接搜当前词或选区
- `<leader>sy` 会把当前词或选区预填进 live grep，可继续修改关键字
- 需要全词匹配时用 `<leader>sx`
- 需要大小写精确匹配时用 `<leader>sX`
- 在任意 Snacks picker 里按 `<C-q>`，把当前选中项（没选时就是当前全部结果）固定到 quickfix，并自动在左侧打开结果栏
- 先用 `<C-Space>` 多选，再按 `<C-q>`，可以把筛过的一部分结果固定下来
- 在 live grep 输入里可以追加 ripgrep 参数，比如 `Foo -- --word-regexp --case-sensitive`

## Trouble / Quickfix / Diagnostics
- `<leader>xx` 打开 diagnostics
- `<leader>xX` 当前 buffer diagnostics
- `<leader>xQ` quickfix list
- `<leader>xL` location list
- `[d` / `]d` 上一个 / 下一个诊断
- `[e` / `]e` 上一个 / 下一个 error
- `[w` / `]w` 上一个 / 下一个 warning
- `<leader>cd` 当前行 diagnostics
- `<leader>cl` LSP info
- `:copen` / `:cclose` 打开 / 关闭 quickfix
- `:cnext` / `:cprev` 在 quickfix 间跳转

## Left Sidebar / Workbench
- `<leader>va` 打开侧栏视图菜单，`1-7` 直选，或 `Tab` / `Shift-Tab`、`j/k` 移动后 `Enter`
- `<leader>vv` 显示 / 隐藏左侧工具栏
- `<leader>vg` 左侧显示 git modified files / status
- `<leader>vb` 左侧显示 open buffers
- `<leader>vs` 左侧显示当前文件 symbols
- `<leader>vd` 左侧显示 diagnostics
- `<leader>vq` 左侧显示固定后的 quickfix 结果
- `<leader>vl` 左侧显示 loclist
- `<leader>vt` 左侧显示 TODO / FIXME
- 这组视图共用同一个左侧区域，切别的 `v?` 会直接切换内容
- git 视图会先显示旧结果或空标题，并带 `Updating git status...` 占位，然后异步刷新
- 空结果的视图会保留标题，不会因为没有内容直接把左栏关掉

## Buffer / Window / Tab
- `<S-h>` / `<S-l>` 上一个 / 下一个 buffer
- `<leader>bb` 切到上一个 buffer
- `<leader>bn` 新建空 buffer
- `<leader>bd` 删除 buffer
- `<leader>bo` 删除其他 buffers
- `<leader>bD` 删除 buffer 和 window
- `<leader>-` 横向分屏
- `<leader>|` 纵向分屏
- `Ctrl-w h j k l` 在窗口间切换
- `<leader>wd` 删除窗口
- `<leader>wm` 窗口最大化 / 还原
- `<leader><tab><tab>` 新 tab
- `<leader><tab>[` / `<leader><tab>]` 上一个 / 下一个 tab
- `<leader><tab>d` 关当前 tab
- `<leader><tab>o` 关其他 tabs

## Terminal / Shell
- `<leader>ft` 根目录浮动终端
- `<leader>fT` cwd 浮动终端
- `<C-/>` / `<C-_>` 切换 root terminal
- `<leader>tt` 切换底部终端并复用 buffer
- `<leader>t` 同 `<leader>tt`
- `<leader>tc` 终端切到当前文件目录
- `<leader>tp` 终端切到当前项目目录
- `<leader>te` 终端切到 UE engine 目录
- terminal 模式下按 `<Esc>` 退出到 Normal

## Git
- `]h` / `[h` 跳到下一个 / 上一个修改块（git hunk）
- `]H` / `[H` 跳到最后一个 / 第一个修改块
- 这套配置里 git 修改跳转看 `h` 这一组，不看 `[c` / `]c`
- `<leader>gg` / `<leader>gG` 打开 Lazygit
- `<leader>gb` 当前行 blame
- `<leader>gf` 当前文件历史
- `<leader>gl` / `<leader>gL` git log
- `<leader>gs` git status
- `<leader>gS` git stash
- `<leader>gd` diff hunks
- `<leader>gD` 对比 origin
- `<leader>gB` 浏览器打开当前文件
- `<leader>gY` 复制仓库 URL

## UI / Toggle
- `<leader>ut` 主题选择器
- `:Theme` 打开主题选择器
- `:Theme <name>` 设置并持久化主题
- `:Theme ubuntu-terminal` 切到 Ubuntu Terminal 风格主题
- `<leader>uf` format on save
- `<leader>uF` force format mode
- `<leader>ud` diagnostics 开关
- `<leader>us` 拼写检查
- `<leader>uw` 自动换行
- `<leader>uh` inlay hints
- `<leader>uG` git signs
- `<leader>uT` treesitter
- `<leader>uz` zen mode
- `<leader>uZ` zen zoom alias
- `<leader>ur` redraw 并清掉搜索高亮
- 注意：这套配置里 `u` 前缀有一部分默认 LazyVim toggle 被 UE / Android 工作流刻意接管了，比如 `ub` / `ui` / `ul` / `uL` / `uD` / `up`

## Windows 自定义
- `<leader>E` 在 Explorer 中定位当前文件
- `<leader>oe` 同上
- `:RevealInExplorer` 直接调用定位

## UE 工作流
- `<leader>uj` 设置项目根目录或 `.uproject`
- `<leader>uP` 同上，旧的大写兼容键
- `:UESetPlatform` 交互选择 platform + configuration
- `:UESetPlatform Win64 Development Editor` 直接设置
- `<leader>ub` Android Development 构建
- `<leader>ue` 执行 `UEPrepare`
- `<leader>uB` 同上，旧的大写兼容键
- `<leader>uc` 导出 `compile_commands.json`
- `<leader>ul` 启动 app，但不 attach debugger
- `<leader>ui` 安装 APK 到连接设备
- `<leader>ug` 切换 app log
- `<leader>uL` 同上，旧的大写兼容键
- `<leader>uv` 切换 Windows debug log
- `<leader>uD` 同上，旧的大写兼容键
- `<leader>uo` / `<leader>uO` 在当前 module/plugin 范围查文件 / grep
- `<leader>up` 查看当前 UE 路径
- `UEBuildAndroid` / `UEPrepare` / `UEExportCompileCommands` 失败时会写入 quickfix

典型 Win64 编辑流程：
- `:UESetPlatform Win64 Development Editor`
- `:UEExportCompileCommands`
- 打开代码，`gd` / `gr` / `<leader>ss` / `<leader>/` 开始工作

## Android DAP
- `<leader>da` attach 到 Android 进程
- `<leader>db` 切换硬件断点
- `<leader>dc` continue
- `<leader>dp` pause
- `<leader>dn` step over
- `<leader>di` step in
- `<leader>do` step out
- `<leader>dl` debug 模式启动并自动 attach
- `<leader>dL` 同上，旧的大写兼容键
- `<leader>du` 切换 DAP UI
- `<leader>dr` 切换 REPL
- `<leader>dx` 重置布局
- `<leader>dR` 同上，旧的大写兼容键
- `:UESetAndroidPackage <pkg>` 设置 attach 用的包名
- `F9` 切换硬件断点
- `F5` continue
- `F6` pause
- `F10` step over
- `:qa` 会自动做 DAP 清理

推荐优先记住这一组全小写：
- `Space ub` build
- `Space ui` install apk
- `Space da` attach
- `Space dl` launch debug
- `Space dc` continue
- `Space dp` pause
- `Space dn` step over
- `Space di` step in
- `Space do` step out
- `Space db` breakpoint
- `Space du` dap ui
- `Space dr` repl
- `Space dx` reset layout

## 提升开发效率的习惯
- 改代码前先 `*` 搜当前词，再 `gr` 看引用
- 改重复结构时先录一个宏，而不是手动改三次
- 做局部结构改动时优先用 text objects，比如 `ci(`、`da{`、`viw`
- 批量改名时不要只靠肉眼搜索，优先 `gr`、`<leader>ss`、`<leader>sS`、`<leader>sr`
- 读超大文件时用 marks + jumps + folds：`ma` 标记、`Ctrl-o` 返回、`zM/zo/zc` 管结构
- 删除时怕污染寄存器就用 `"_d`
- 每次完成一个小修改后记住 `.`，重复编辑会快很多

## 需要记住的一组 builtin
- `u` / `Ctrl-r` 撤销 / 重做
- `.` 重复上次修改
- `*` / `#` 搜当前词
- `%` 找配对符号
- `ma` / `'a` / `` `a `` 标记与回跳
- `qa` / `@a` 宏录制与执行
- `zc` / `zo` / `za` 单个折叠
- `zM` / `zR` 全部折叠 / 全部展开

## 卡住时先做什么
- `<leader>sk` 搜你想做的动作对应 keymap
- `<leader>sh` 搜帮助
- `:help motion.txt`
- `:help usr_28`
- `:help folds`
- `:help quickfix`
