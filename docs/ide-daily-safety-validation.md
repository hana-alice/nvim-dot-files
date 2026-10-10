# 日常 IDE 操作保护与可发现性验收（2026-10-04）

基线为 `429405b`。本轮按用户授权继续实现，并将新旧操作写入
[使用手册](USER_GUIDE.md)。原始 UI、进程与文件路径证据仅保存在忽略的 `.tmp/`。

## report-first

真实探针仍有三条历史复发：provider 6/旧处置 3、identity-missing 3/旧处置 1、
semantic-tu-unavailable 3/旧处置 2。沿用 [已有待验证理由](ide-experience-validation.md#report-first)：
原 subject 缺失，无法重现原事件。本轮未改计数，也不把新 fixture 通过当作这些历史问题已关闭。
开始前上一轮 required-native 全量为 2835/2835，零失败、零跳过。

## 已验证的操作

| 流程 | 证据与范围 |
|---|---|
| 关闭文件保护新输入 | 4 个真实入口修复前均丢失确认期间的新文本，修复后均保留 loaded/dirty 文本与未变磁盘；19/19 回归包含实际 root 插件接线、原生确认框和 RPC UI |
| 原生卸载回调产生新文本 | 独立 Neovim 实验确认普通 `force=false` 仍会卸载回调中的编辑；本地尾回调捕获新版本，恢复为未命名脏缓冲区；不会复活明确放弃的旧版本 |
| 补全与文件大纲 | 21/21 回归，实际 Blink/Snacks/clangd 16 组交互与配置验证；Tab 优先片段字段，原生大纲树保留，编辑后的旧坐标不交付，UTF-16 转换不污染缓存，刷新只取消旧请求 |
| 文件树改名、移动、删除 | 36/36 owner 回归、12 组实际 Explorer UI；元数据保护由其中 7 条回归覆盖。目录、Unicode、双窗口、脏文件、迟到目标、新脏子文件、原路径重建与新保存者通过；成功改名后的普通 `:w`、原撤销历史、隐藏文档及多 tab 不等尺寸窗口通过；删除保留文本 |
| 独占移动 | 本机 Windows 12/12 原生测试：文件/非空目录、Unicode、目标存在和入队后创建目标、无效输入及主循环继续响应；另 8/8 真实跨卷场景拒绝，无复制/覆盖，源保留；平台 66/66 |
| 命令中枢 | Hub 28/28、5 组实际 Snacks RPC UI及关系提供者修订验证；补齐导航、全部文件、显式文本搜索、最近搜索、历史入口和命令名显示；旧来源或目标变化后不执行 |
| 操作手册 | 新增 9 个任务索引；独立核对全部锚点、真实按键、F5 范围、关闭/停止区别和人工恢复边界 |

数据保护实现沿用原生窗口、任务注册表、文件树与阅读 owner，没有新增依赖。
补丁集中在 `workarounds/snacks/`，命令中枢使用原映射回调，文件大纲保留原生符号树。
宿主差异仅由平台驱动提供；异步回收有超时、前台 ownership 和派生任务状态。

## 选型及纠正

- **签名提示候选撤回**：最初仅看到 Blink 的 `signature=false`，据此推测缺自动参数提示。
  继续核对发现 Noice 已启用自动签名；保留该 owner，只补手册说明，不启用第二套提示。
- **关系可用性纠正**：只看 provider 的方法广告曾让非 clangd 客户端被标为可用，
  但实际关系 chooser 明确仅选 clangd。已按同一名称及方法约束修正并实跑整个调用链；
  非 clangd 无派发，合格 provider 有请求。普通 gd、编译器 Peek 与返回/取消没有增加该门槛。
- **关闭事件的边界**：buffer listener 在 `BufUnload` 前分离，单靠 `on_lines` 无法保护卸载回调。
  使用单次、buffer-local 的尾回调，不屏蔽全局事件或修改 Neovim API。
- **目标排他**：stat 后普通 rename 仍可覆盖迟到目标。Windows 使用
  [MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw) 的零 flags；
  原先候选 MoveFileW 允许文件跨卷移动，不能满足拒绝跨卷复制的约束。原生调用进入 libuv 工作池。
- **来源身份边界**：目标的原子排他不等于跨进程来源身份锁。文件 owner 分别核验快照、
  已加载文档及移动后身份；变化时保留目标/隔离对象和恢复记录，不声称自动回滚。
- **异步删除的归属**：先同卷隔离，再仅回收所捕获路径；不会把后来重建的原路径交给 child。
  服务器需要文件改名文本编辑时先拒绝，尚未接通该编辑的多文件预览。
- **独立反例及修复**：回收等待期间，原缓冲区输入新内容并保存重建了文件，旧 cleanup 仍会把它
  变成未命名脏缓冲区。后置清理改为核验冻结的名称、版本、状态及原路径重建；
  实际回收 backend 与原生写入复验后，新保存者的名称、clean 状态和磁盘内容均保留。
- **文件命名事件**：真实 BufFilePre 中的新输入和保存也可能被旧命名动作接管。
  单次局部守卫中止本次外层命名，不阻止用户回调中的新命名；Pre/Post 嵌套操作分别实测。
- **改名后的普通保存**：单纯设置 buffer 名称会留下原生 not-edited 状态，普通 `:w` 报 E13，
  已交叉核对 [Neovim 原生实现](https://github.com/neovim/neovim/blob/v0.11.5/src/nvim/ex_cmds.c)。
  `checktime` 和 scratch/hidden-float 候选未解除该错误；重新 `edit` 会重读并增加 undo，普通 split 会改窗口尺寸。
  原生显式文件名 split 可刷新该状态而不重读文本；内部呈现的最终选择及复验见下。
- **独立元数据反例**：仅观察上述三个事件仍遗漏 WinEnter。真实回调选择已有脏窗口时，
  旧原生 split 的 filename 部分继续在该窗口执行，文本虽保留在隐藏 buffer，原窗口被错误替换。
  独立复验发现后中止首轮全量；该轮不计为最终门禁，修复和补回归先于重新冻结。
  后续复验还发现用户可在新窗口切换到新文档；只按窗口 ID 转回不足以保留该视图。
  WinLeave 抛错 veto 候选也已被真实最后一个 tab 窗口场景证伪：普通窗口的 abort 检查不能冒充该分支。
  后改用隐藏的自有 float 与单条命令局部 noautocmd，仅隔离没有用户操作语义的临时呈现。
  原生小实验中 7 类临时窗口/缓冲区事件均为 0，普通保存、精确 undo 与原窗口保持；
  不更改全局事件选项，不压制真实文件命名/保存事件；独立复验确认真实 Pre/Post 各 1 次，
  返回后的正常 WinEnter 新文档仍保留 buffer、版本、dirty、view 和焦点。
  原先与 picker 相关的临时 auto_close hook 随该收敛删除。
- **隐藏文档生命周期与原始路径**：仅用浮窗临时展示时，关闭最后一个窗口可能触发
  `bufhidden=wipe`，已用原生 buffer context 持有引用，不更改用户 hide policy。
  结构化命令仍默认展开 `%`/`#` 文件名；显式关闭 filename/bar magic 后，
  带 Unicode、空格、`#`、`%` 的真实目标也能普通保存。两项均先做原生红绿实验再锁回归。
- **类型诊断的边界**：真实 Neovim/luv metadata 提示 `new_timer` 可为空；受控失败分配 seam
  证实服务器改名前置步骤会抛错且不回调，需要明确拒绝并清理。没有复现或宣称真实 OOM。
- **同步服务器响应**：原生 Lua 服务器可在返回 request ID 前回包或触发取消。
  请求记录区分已完成与待取消，拒绝后停止后续派发，迟到 ID 只取消仍属于旧请求者。
- **宿主/target 分类**：LuaJIT 的 Linux 主机名与 UE target 同名。AST 门禁仅辨认 host driver 中
  的限定 OS 属性，通用代码的 FFI OS 分支与实际 target 分支仍被禁止；没有增加文件 allowlist。
- **手册按键纠正**：原生实验确认 Ctrl-W q 才关闭窗口，大写 Q 无效；Space Space 是工作区全文件，
  最近文件使用 Space f r。F5 快照刷新不扩展到普通工程/模块文件 picker。

## 验证边界及未完成事项

实际编译器、原生 SDK、受控 transport 和物理 GUI 证据分别记录。RPC UI 不等于物理 GUI；
Linux/macOS 的独占移动尚未实机验收。Windows 跨卷测试的两个自有临时根已核验原生解析路径并清理，
没有挂载/模拟卷或修改真实工程。
参数签名已核对现有 Noice 自动配置，手动提示通过真实 clangd 验证；Noice 自动前端显示尚未做物理交互验收。
缺原语/跨卷不降级覆盖；仅改大小写需两步临时改名。
异步隔离路径不提供对任意外部 writer 的 OS 身份锁，回收失败保留对象供检查。

本轮不修改 CDB、SuperUnity、prepare 或索引输入机制，不宣称全工程性能恢复。
全 UE 工程性能、UE 类型调试易读显示、真实 Editor 测试、Actor/Component 编译与 Blueprint 桥接
继续保留为未完成事项，见 [前批验收](ide-experience-validation.md)。

## 静态验证与独立复核

27 个改动/新增 Lua 文件通过 AST 检查，16 个新增 Lua 通过 StyLua；既有文件仅检查所改范围。
两份主 spec strict 校验通过，无活跃 OpenSpec change，沿用直接同步主规格与 release 文档归档。
关闭、编辑、大纲、Hub、平台与文件操作的独立复核均 APPROVED；最后的文件范围独立
required-native 回归为 36/36，零失败、零跳过，绑定最终源码哈希。

两个符号模块的范围 LuaLS 为零诊断；另 9 个新 runtime 使用实际 Neovim/luv metadata 完整扫描，
0 Error、6 Warning，CLI exit 1。六条分别为 `fs_lstat(string)` 被注释成 integer 的五条警告，
及 `vim.cmd` 可调用 table 的一条警告，均由实际 API 与安装版源码/文档交叉核对。
没有添加假依赖或禁用诊断。真正的 nil timer 缺口已补，受控失败时恰好一次拒绝回调且清理取消状态；
普通真实 timer 分配成功。额外的两条局部声明警告通过等义拆分声明消除。

## 最终门禁

最终 required-native 全量：**2949/2949，0 failed，0 skipped，exit 0**，包含 legacy；
27 个改动源码/测试文件的 SHA256 在执行前后保持一致。前一轮中断不计验收。
版本归档后结构回归 **78/78**，零失败、零跳过。
发布前 38 个候选文件全文、author/committer 元数据及精确 Lore 提交说明通过
本机私有 denylist 与通用 secret 扫描，两个 scanner 均 exit 0；原始输出仅保存在忽略目录。
正常 commit/ref/push 隐私 hooks 保持启用，公开推送仅限已授权分支，不创建 tag。
