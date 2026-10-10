# 使用手册：把这套 Neovim 当 UE / Android IDE 用

先按 **`<leader>uH` 打开工作台**，查看当前目标、选择下一步、找回之前的工作。
`<leader>` 是空格键；工作台旁边保留源码。全部操作可用键盘完成。
完整按键表见 [速查](ue_lazyvim_cheatsheet.md)，能力与恢复边界见 [使用边界](USER_GUIDE_LIMITS.md)。

## 1. 从工作台开始

### 当前开发工作台

`<leader>uH` / `:UEWorkbench` 打开工作台。用 `j` / `k` 选择，`<CR>` 执行，`r` 刷新，`q` 关闭。

| 分区 | 想做什么 → 怎么做 |
|---|---|
| 当前目标 | 检查工程、平台、配置、设备和包名；在对应行回车修改 |
| 下一步 | 初次配置选「首次上手向导」或按 `g`；日常选构建、运行或环境检查 |
| 最近结果 | 按构建编号查看该次错误或输出；修复并保存后再构建 |
| 运行中任务 | 回车查看任务输出或详情；到任务面板显式停止 |
| 恢复 | 回车或按 `R`，按想找回的内容选择入口 |

想搜索动作，在工作台按 `p` 打开命令中枢。手册用 `<leader>u?` / `:UEGuide`，按键帮助用 `<leader>?`。
边界与结果含义：[工作台](USER_GUIDE_LIMITS.md#工作台与构建结果)。

### 恢复

统一从 **工作台 → `R`（恢复）** 进入，用 Ctrl-N / Ctrl-P 或上下箭头选择、回车打开：

| 想找回什么 | 选什么 |
|---|---|
| 关掉的构建、终端或应用日志 | 「找回关掉的日志」；知道是最近构建时选「找回最近构建日志」 |
| 关掉的窗口、文件或结果列表 | 「找回关掉的窗口、文件或结果」 |
| 一组文件、搜索条件和下一步 | 「继续已保存调查」 |
| 上次会话的文件和布局 | 「恢复上次会话」 |
| 异常退出前尚未保存的文字 | 「找回异常退出的文本」 |

每个入口继续用原有操作；[恢复边界](USER_GUIDE_LIMITS.md#恢复入口与保留范围)说明能找回哪些内容。

### 已习惯的直达键

| 按键 | 直达 |
|---|---|
| `<leader>P` | 搜索命令中枢 |
| `<leader>uu` | 当前目标面板 |
| `<leader>uk` | 执行上次失败建议的修复 |
| `<leader>wM` | 窗口、缓冲区、结果、任务与日志找回 |
| `<F5>` / `<S-F5>` | 运行或继续 / 停止调试 |

## 2. 第一次使用

工作台「下一步」显示当前缺项。选「首次上手向导」或按 `g`，按缺项连续补齐：

| 顺序 | 在向导里做什么 | 需要单独操作时 |
|---|---|---|
| 工程 | 选择工程 | `:UESetProject`，或打开工程里的文件 |
| 平台与配置 | 选择要开发的平台和配置 | `<leader>uu` → Platform |
| 设备与包名 | 按当前目标的要求选择；Android 包名可从已安装应用中选 | `<leader>uu` → Device / Package |
| Prepare | 明确确认后才运行编译数据库与索引准备 | `:UEPrepare` |
| 检查环境 | 查看环境检查；✗ 行回车执行修复 | `:UEDoctor` |

补齐一项自动进入下一项。随时按 Esc 取消；选择列表的普通模式也可用 `q`，输入模式中的 `q` 仍是文字。
取消后流程结束，不会稍后启动任务。Prepare 可能较久，必须单独确认。
配置与就绪判定：[首次使用边界](USER_GUIDE_LIMITS.md#首次使用与目标选择)。

## 3. 日常循环（Android）

| 想做什么 | 按什么 |
|---|---|
| 编 SO → 部署 → 调试启动 | 工作台「运行」，或 `<F5>` / `<leader>ux` |
| 同样循环但不带调试器 | `:UEAndroidIterate nodebug` |
| 取消当前循环 | `:UEAndroidIterateStop` |
| 只编 SO / 热替换 SO / 普通启动 | `<leader>us` / `<leader>uq` / `<leader>ul` |
| 安装 APK / 完整构建 | `<leader>ui` / `<leader>ub` |
| 保存 / 选择 / 删除常用运行配置 | `:UERunProfileSave` / `:UERunProfile` / `:UERunProfileDelete`；方式 `run` 是无调试器循环 |
| 到最近构建的首个源码错误 | `<leader>uE`；Ctrl-O 返回 |
| 查看某次构建的错误或输出 | 工作台「最近结果」选对应编号 |
| 继续浏览当前结果 | `]q` / `[q`；`2]q` 前进两项 |

构建前保存修改。失败后从该次错误打开源码 → 修复并保存 → 工作台重新构建。
循环、部署与构建结果：[验证边界](USER_GUIDE_LIMITS.md#运行循环与部署)。

## 4. 调试

| 想做什么 | 按什么 |
|---|---|
| 附加正在运行的应用 / 启动即调试 | `<leader>da` / `<leader>dl` |
| 下 / 取消断点 | `<F9>` 或 `<leader>db` |
| 继续 / 暂停 | `<F5>` / `<F6>` |
| 单步跳过 / 进入 / 跳出 | `<F10>` / `<F11>` / `<S-F11>` |
| 运行到光标 | `<leader>dt` |
| 看变量 / 求值表达式 | `<leader>dh` / `<leader>de` |
| 加入监视 / UE 类型监视 | `<leader>dw` / `<leader>dW` |
| 上 / 下一调用帧 | `<leader>dk` / `<leader>dj` |
| 条件断点 / 日志断点 / 清空断点 | `<leader>dB` / `<leader>dL` / `<leader>dC` |
| 停止调试 | `<S-F5>`（Shift-F5） |
| 附加前检查 / 应用重启后重新附加 | `:UEDAPPreflight` / `:UEDAPReattach` |

失败提示先给问题层与处置；有建议修复时选工作台「修复上次失败」或 `<leader>uk`。
调试期间可继续下新断点。调试边界与变量显示限制：[调试](USER_GUIDE_LIMITS.md#调试)。

## 5. 看日志、查崩溃

| 想做什么 | 按什么 |
|---|---|
| 应用日志 / 调试 logcat | `<leader>ug` / `<leader>d4` |
| 最近崩溃调用栈 / 历史通知 | `<leader>uX` / `<leader>uN` |
| 找回已关闭日志 | 工作台 → 恢复 →「找回关掉的日志」 |

| logcat 内的按键 | 做什么 |
|---|---|
| `<CR>` | 跳到这一行的源码位置 |
| `gl` | 切显示级别：全部 → Debug → Info → Warn → Error |
| `g/` / `gt` / `g0` | 内容筛选 / tag 筛选 / 清除筛选 |
| `gf` / `G` | 暂停或切换跟随 / 最新日志并恢复跟随 |
| `gx` | 符号化最近崩溃 |

向上阅读可暂停跟随，崩溃结果里回车打开有源码位置的帧。
日志保留与符号匹配：[日志边界](USER_GUIDE_LIMITS.md#日志与崩溃)。

## 6. 读代码、找东西

| 想做什么 | 按什么 |
|---|---|
| 定义 / 引用 / 头源切换 | `gd` / `gr` / `<leader>ch` |
| 看谁调用它 / 它调用谁 | `<leader>cI` / `<leader>cO` |
| 看基类 / 派生类 | `<leader>cB` / `<leader>cD` |
| 工作区符号 / 当前文件大纲 | `<leader>sS` / `<leader>ss`；输入名称筛选 |
| 当前类 / 函数的父级上下文 | `[c`；Ctrl-O 返回 |
| 模块文件 / 工作区全部文件 | `<leader>uo` / `<leader><leader>` |
| 工程文件 / 最近文件 | `<leader>ff` / `<leader>fr` |
| 文件树 / 侧栏 | `<leader>fe` / `<leader>v` 开头的一组键 |

语义导航、大纲与上下文：[阅读边界](USER_GUIDE_LIMITS.md#语义导航与连续阅读)。

### 先查看，再跳转

| 想做什么 | 操作 |
|---|---|
| 预览定义 | `:UEPeek`；另可选 `declaration` / `implementation` / `type_definition` / `references` |
| 打开预览项 | 回车原窗口；Ctrl-S 横分屏、Alt-V 竖分屏、Ctrl-T 新标签页；Esc 取消 |
| 保存预览结果 | Ctrl-Q；之后 `:UEWorkspace results` 查看 |
| 取消请求或预览 / 回阅读起点 | `:UEReadCancel` / `:UEReadReturn` |
| 跳转历史后退 / 前进 | Ctrl-O / Ctrl-I |
| 连续看调用或继承树 | `:UERelations incoming`；另可选 `outgoing` / `base` / `derived` |
| 展开 / 折叠分支 | 右 / 左方向键，或 `l` / `h`；Alt-U 选父节点 |
| 打开关系节点 / 在旁边打开 | 回车 / Alt-V；`:UERelations resume` 回已加载分支 |

迟到请求与关系覆盖：[连续阅读边界](USER_GUIDE_LIMITS.md#语义导航与连续阅读)。

### 直接跳到行列，或分享当前位置

`<leader>fl` 输入 `42` 或 `42:7` 跳到行 / 行列；Esc 取消。列从 1 开始，按 UTF-8 字节计。
跨行 Ctrl-O 返回；同一行内用两个反引号返回精确位置。
`<leader>fy` 复制相对当前窗口目录（`:pwd`）的路径；`<leader>fA` 绝对路径；`<leader>fY` 复制 `路径:行:字节列`。
行列合法性与剪贴板：[位置边界](USER_GUIDE_LIMITS.md#行列与文件位置)。

### 找文件和搜索内容

文件列表接受 `/`、`\` 和 `文件:行:列`，如 `Source/Game/Alpha.cpp:42:7` 或 `"Source/Space Name.cpp":42:7`。
Ctrl-V 粘贴；Ctrl-Y 复制候选的 `路径:行:列`，Alt-Y 绝对路径，Alt-Shift-Y 相对路径；F5 刷新全文件列表。

| 想做什么 | 按什么 |
|---|---|
| 搜索已索引的工程与引擎文件 | `<leader>/` |
| 显式搜索磁盘文本 / 代码 | `<leader>sG` / `<leader>sg`；例如 `foo -- -g *.cpp` |
| 整词 / 大小写 / 字面量与正则 | Alt-W / Alt-C / Alt-R |
| 选择搜索范围 / 包含排除与扩展名 | Alt-D / Alt-F |
| 内容查询与候选文件筛选切换 | Ctrl-G |
| 文件分组开关 | `:UEGrepGroupingToggle` |

范围、部分结果与文件缓存：[搜索边界](USER_GUIDE_LIMITS.md#文件与工程搜索)。

### 在当前文档逐个查找

`<leader>sf` 输入文字；`<leader>sF` 预填光标词或单行选区。回车跳到原编辑区，Esc 取消。
Alt-C / Alt-W / Alt-R 切大小写、整词与正则；Ctrl-V 粘贴；编辑文档后 F5 更新结果。
`<leader>sR` 用上次条件在当前文档重查。跨行 Ctrl-O 返回，同一行内用两个反引号返回。
模糊筛选当前缓冲区行用 `<leader>sb`；搜索已打开文件的磁盘内容用 `<leader>sB`。
条件语法与预算：[文档查找边界](USER_GUIDE_LIMITS.md#当前文档查找)。

### 重构与 UE 声明

| 想做什么 | 操作 |
|---|---|
| 符号重命名 / code action | `<leader>cr` / `:UERename`；`<leader>ca` / `:UECodeActions`；先预览再确认 |
| 撤销整批修改 / 查看恢复记录 | `:UERefactorUndo` / `:UERefactorRecovery` |
| 插入 UE 片段 | 补全搜 `uproperty` / `ufunction` / `uclass` / `ustruct` / `uenum` / `ulog`；Tab / Shift-Tab 切字段 |
| 创建类 | `:UENewClass` 选模块和 UObject / Actor / Component，预览后创建，再跑 UHT 和编译 |

版本保护与类生成范围：[重构边界](USER_GUIDE_LIMITS.md#重构与类生成)。

### 替换文本，再检查结果

`<leader>sr` 预填当前文件整词替换；先用 `v` / `V` 选择则替换选区覆盖的行。
输入替换文字回车，再按 `y` 替换、`n` 跳过、`a` 替换剩余、`q` 停止；Esc 取消命令。
`u` 撤销，Ctrl-R 重做，再自行保存。Vim 替换中 `&` 是匹配原文，字面 `&` 用 `\&`。
多文件磁盘替换用 `:GrugFar`。范围与撤销差异：[替换边界](USER_GUIDE_LIMITS.md#替换与诊断)。

### UE Editor 测试

`:UETests` 打开测试入口；`:UETests list` 发现，`:UETests run <筛选>` 运行，
`:UETests results` 看结果，`:UETests rerun` 重跑失败。Tasks 里可停止。
Editor 前提与报告完整性：[测试边界](USER_GUIDE_LIMITS.md#editor-测试)。

### 保存和继续调查

工作台选「保存当前调查」填写名字与下一步；工作台 → 恢复 →「继续已保存调查」找回。
也可用 `:UEWorkContext save` 保存，`:UEWorkContext` 继续；`<leader>P` 仍可搜「保存具名调查」。
`:UEWorkContext add` 关联当前文件，`:UEWorkContext search` 关联完整搜索条件，`:UEWorkContext note` 更新下一步。
列表回车继续活动文件并开详情；详情回车操作、`r` 刷新、`dd` 删除记录、`q` 关闭。
持久元数据与原实例结果：[调查边界](USER_GUIDE_LIMITS.md#具名调查)。

### 找回以前做过的事

| 想找回什么 | 按什么 |
|---|---|
| 搜索、文件、跳转、命令、通知、结果与 Git 历史 | `<leader>fh` |
| 完整条件重搜 / 最近内容搜索 / 上次 picker | `<leader>sH` / `<leader>s/` / `<leader>sR` |
| 最近文件 / 跳转位置 / 书签 | `<leader>fr` / `<leader>sj` / `<leader>sm` |
| 保存搜索结果 | Ctrl-Q，之后工作台 → 恢复 → 窗口/文件/结果，或 `:UEWorkspace results` |

旧搜索格式与结果预算：[搜索历史边界](USER_GUIDE_LIMITS.md#搜索历史与结果)。

### 管理文件和关闭缓冲区

文件树 `<leader>fe` 内：回车打开或展开，`h` 收起，`a` 新建，`r` 改名，`m` 移到已有目录，`d` 确认删除。
先保存受影响文件；改名后 `:w` 保存到新路径。需要恢复提示时用 `<leader>uN` 查看保留位置。
`<leader>bc` 智能关闭文件/面板；`<leader>bd` 关闭缓冲区保留布局；`<C-w>q`（Ctrl-W q）只关闭视图。
找回窗口用工作台恢复；找未保存文本用 `:UEUnsaved`。取消/回收与新编辑保护：[文件操作边界](USER_GUIDE_LIMITS.md#文件操作与关闭)。

### 编辑、格式化与未保存文件

| 想做什么 | 按什么 |
|---|---|
| 选择补全 / 接受 / 关闭 | Ctrl-N / Ctrl-P；回车或 Ctrl-Y；Ctrl-E |
| 片段字段前进 / 后退 | Tab / Shift-Tab |
| 参数签名 | 输入时自动；普通模式 `gK`，插入模式 Ctrl-K |
| 语法选区进入 / 扩大 / 缩小 / 退出 | Ctrl-Space / Ctrl-Space / 退格 / Esc |
| 注释行 / 选区 | `gcc` / `gc` |
| 上移 / 下移行或选区 | Alt-K / Alt-J；`u` 撤销 |
| 撤销 / 重做 / 历史 | `u` / Ctrl-R / `<leader>su` |
| 当前诊断详情 / 前后诊断 / 前后错误 | `<leader>cd` / `[d`、`]d` / `[e`、`]e` |
| 格式化文件 / 选区 | `<leader>cf`；选区先用 `v` / `V` |
| 明确使用内置 UE 风格 | `:UEFormat epic`；选区 `:'<,'>UEFormat epic` |
| 参数名类型提示 / 自动格式化开关 | `<leader>uh` / `<leader>uf` |
| 未保存列表 / 退出前集中处理 | `:UEUnsaved` / `<leader>qq`、`:UEQuit` |

工程风格、能力前提和退出保护：[编辑边界](USER_GUIDE_LIMITS.md#编辑格式化与退出)。

### 逐项处理问题

`<leader>xx` 全部语言诊断，`<leader>xX` 当前文件，`<leader>sd` 按文字或文件名搜诊断。
列表 `j` / `k` 选择、回车跳源码，`gb` 当前文件筛选，`s` 严重级别；换范围先关再从源码打开。
源码 `]e` 找下一错误 → `<leader>cd` 看详情 → `<leader>ca` 看修复 → 修改后再检查；Ctrl-O 返回。
构建或搜索结果用 `]q` / `[q`；撤销历史 `<leader>su`，整批重构回退 `:UERefactorUndo`。
语言诊断与构建结果含义：[诊断边界](USER_GUIDE_LIMITS.md#替换与诊断)。

### 回到工作现场

工作台 → 恢复 →「恢复上次会话」：`:UESessionRestore` 按需打开文件；`:UESessionRestore full` 完整加载。
工作台 → 恢复 →「找回异常退出的文本」：`:UERecovery`；跨工程快照用 `:UERecovery all`。
重启编辑器用 `:Restart`。原生退出仍可 `:q` / `:qa`；`:qa!` 明确放弃修改。
会话与文本的保留范围：[恢复边界](USER_GUIDE_LIMITS.md#会话与异常文本)。

## 7. 状态栏怎么读

| 看到什么 | 怎么做 |
|---|---|
| 索引状态、`Q:…`、`PREP*` | 等待准备/索引，或 `:UEIndexStatus` 查看 |
| `BOK` / `B<数字>` / `BERR`、`LOOP✓ 42s` / `LOOP✗` | 工作台看最近构建/运行结果 |
| `A:Pixel 8/game` / `A:no-device` | 设备与包名选择；缺设备在当前目标里补齐 |
| `⏵3` | 三个后台任务；工作台查看，或 `<leader>X` |
| `⏸ DBG` / `▶ DBG` | 调试已暂停 / 正在运行 |
| `未保存:3` | `:UEUnsaved` 逐个处理 |
| `可恢复文本:N` / `恢复缓存未更新` | 工作台恢复异常文本，检查提示 |
| `维护诊断:N未读（可忽略）` | 维护者用 `:UEProbeReport` 查看 |

状态含义与维护配置：[状态栏边界](USER_GUIDE_LIMITS.md#状态栏与维护诊断)。

## 8. 后台任务

工作台「运行中任务」回车查看输出或详情；底部列表 `<leader>X` 用 `dd` / Ctrl-X 停止，`r` 刷新。
`<leader>Xs` 停一个，`<leader>XA` 确认后停全部；调试仍用 Shift-F5。
关闭视图与取消任务：[任务边界](USER_GUIDE_LIMITS.md#恢复入口与保留范围)。

### 关闭窗口后找回来

从工作台恢复选择日志或窗口/文件/结果；直达 `<leader>wM` / `:UEWorkspace` 仍可用。
输入文件名或任务名筛选，回车打开；Ctrl-R 刷新，Ctrl-X 停止选中的任务。

| 分类 | 回车做什么 | 直达命令 |
|---|---|---|
| Windows | 聚焦已有窗口，含其它标签页 | `:UEWorkspace windows` |
| Buffers | 重新显示隐藏文件 | `:UEWorkspace buffers` |
| Results | 打开保存的搜索、构建或 quickfix | `:UEWorkspace results` |
| Tasks | 查看任务输出或详情 | `:UEWorkspace tasks` |
| Logs | 显示保留的终端或日志 | `:UEWorkspace logs` |

`:UEWorkspace` 也可接分类参数 `windows` / `buffers` / `results` / `tasks` / `logs`。
普通编辑区里，隐藏文件 Ctrl-O 在原窗口打开；回车用分屏或聚焦已有窗口。日志、任务和结果用回车。
保留范围与过期条目：[找回边界](USER_GUIDE_LIMITS.md#恢复入口与保留范围)。

### 共用底部面板

`<leader>uJ` 依次切构建输出 → 问题 → logcat → 任务；构建终端也可按。
`:UEPanel build`，或参数 `quickfix` / `logcat` / `tasks` 直接切面板。
`:UEPanel history` / 构建输出 `gH` 看阶段日志；应用日志用 `<leader>ug`，调试日志用 `<leader>d4`。
底部面板生命周期：[面板边界](USER_GUIDE_LIMITS.md#恢复入口与保留范围)。

## 9. 出问题时先看哪里

工作台检查目标与下一步；搜索动作可按 `p`，原 `<leader>P` 保留。

| 现象 / 想检查什么 | 怎么做 |
|---|---|
| 环境缺项 | `:UEDoctor`；工作台向导逐项补齐 |
| 上次失败有修复 | `<leader>uk` |
| 附加失败 / 应用没运行 | `:UEDAPPreflight`；先 `<leader>ul` 或启动调试 |
| 断点未命中 | 查看预检符号结果；按提示编 SO、部署或安装匹配包 |
| 设备未选 / 离线 | 当前目标选设备，或重新连接 |
| `gd` 未就绪 | `:UEIndexStatus`；需要准备时明确运行 `:UEPrepare` |
| 搜索不全 | 检查范围和标题；确认索引过期后 `:UEBuildCsearch` |
| 提示一闪而过 | `<leader>uN` |
| 编辑器基础功能 | `:NvimCoreHealth` |
| 关闭后找不到输出 | 工作台 → 恢复 → 找回日志 |

尚未验证范围和进一步证据：[使用边界](USER_GUIDE_LIMITS.md)。
