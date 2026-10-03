# editor-behavior-regression Specification

## Purpose

定义本 Neovim 配置中编辑器行为与主循环响应性的回归覆盖大方向：`lua/config/options.lua`
关键 option、自定义 filetype/FileType autocmd 行为、workarounds 注册表完整性、关键模块重复
加载/初始化的幂等性，以及编辑器 MUST NOT 卡顿（P6）这条不可退让的底线——包括进程内不阻塞
主循环，以及宿主级不被本配置自己起的工作占满资源。具体断言细节由 `tests/cases/*_spec.lua`
承载，本 spec 只固定方向与已验证的踩坑结论。

## Requirements

### Requirement: 工具链安装保持显式

Mason 与 mason-lspconfig 的继承安装列表 SHALL 清空，已配置 LSP server SHALL 使用外部工具链
而非在编辑器启动时触发自动下载；手动 Mason 操作 MAY 保留。

#### Scenario: 全新插件数据目录启动

- **WHEN** LazyVim 默认包含 formatter 或 LSP 自动安装项
- **THEN** 本仓配置阻止这些自动安装，且不因缺少某工具而下载替代版本

### Requirement: 编辑器行为、filetype 与幂等性回归

回归套件 SHALL 验证关键 option 取值（缩进、行号、session/list 选项）、自定义 filetype 映射
与 FileType autocmd 的可观察行为（如 `usf/ush` 解析为 `hlsl`、C 家族 `cindent` 切换）、
workarounds 注册表能发现所有 workaround 文件且 frontmatter 合法，以及关键模块（`ue`、
`ue.config`、`utils.platform` 等）重复 `require`/重复 `setup()`/`reset_for_test()` 是幂等
且无状态泄漏的。

#### Scenario: 行为契约与幂等性均受保护

- **WHEN** 用例加载配置、触发 FileType autocmd，或连续调用 `setup()`/`reset_for_test()` 多轮
- **THEN** option 与 filetype 行为符合既定契约
- **AND** 重复初始化不产生状态泄漏，命令注册计数与 config 默认值在每轮后正确恢复

### Requirement: picker 与 Git 审阅保留真实交互语义

picker 跳转完成后用户有意的光标移动 SHALL 被保留，MUST NOT 用通用 CursorMoved 回拉撤销正常
输入。原 Git sidebar 入口 SHALL 转入统一完整文件审阅（见 git-review-workspace），不再维护
独立 Git 状态视图；Git 文件导航 SHALL 保留原始路径及 rename/copy 语义，消费 porcelain 输出的
路径 SHALL 使用 NUL 分隔记录，不把展示用引号或转义当作真实文件名。

#### Scenario: picker 跳转后立即移动光标

- **WHEN** picker 跳转完成后用户在短时间内按 j
- **THEN** 光标保持用户移动后的行，不被跳转保护拉回

### Requirement: 主循环余量（main-loop headroom）—— P6 不可退让

编辑器 MUST NOT 在任何时刻卡顿。这条要求有两层，缺一不可：**进程内**单个回调不得阻塞主循环
（周期性回调、每事件同步 I/O 均违规）；**宿主级**本配置启动的工作 MUST NOT 把宿主资源占满到
编辑器不可用——第 2 条是首要原则，资源与功能冲突时让路优先于功能尽快完成。下列不变量已由
2026-08-25/26 实测定位（证据见 `docs/changelog.md`；诊断工具 `tools/stall_profile.lua`、
`tools/stall_attribute.lua`、`tools/stall_repro.lua`）：clangd 并发度需同时受内存与 CPU 预算
约束并为 UI 保留核数；LSP 的普通 stderr 输出不得每条同步落盘；`lua/config/lazy.lua` 的
`change_detection` 必须显式关闭（其周期回调会在主循环上同步 `fs_stat` 全部 spec 模块）；
周期性回调禁止同步子进程往返（K40）；卡顿探针记录必须携带 CPU/gap 比值得出的归属判定
（`in-process`/`descheduled`/`mixed`/`unknown`，rusage 不可用时诚实为 `unknown`）；交互路径
（如 `gr` 引用查找）禁止同步阻塞主循环等待子进程或 LSP 应答，异步化 MUST NOT 静默改变可观察
行为（如丢失 `includeDeclaration`）。

#### Scenario: 关键不变量均受回归保护

- **WHEN** 用例检查 clangd 并发策略、LSP 日志级别、`change_detection` 配置、周期回调实现或
  交互路径（如 `gr`）的同步/异步实现
- **THEN** 各项均符合上述踩坑结论所固化的契约
- **AND** 卡顿记录携带归属判定，且异步化路径的返回集与同步版一致

### Requirement: 宿主负载感知层 SHALL 常驻、廉价、可归属且不含策略

宿主资源纪律的全部决策依赖负载读数，因此感知层 SHALL 只回答「现在多忙、趋势如何、谁在占用」，
MUST NOT 内嵌阈值或推迟/降级策略（后者属于准入判定层，混入感知层会使阈值散落多处互相漂移）。
系统 SHALL 常驻采样（首个差分间隔前明确报告 `warming`，不得伪装成 `idle`）、稳态开销可忽略且
不通过 spawn 子进程采样、同时暴露宿主整体忙碌度与 Neovim 本进程占用（差值标记为
`unattributed`，不得宣称是「外部进程占用」）、暴露平滑值与趋势方向抑制单次尖峰、并在计数器不
推进或平台不支持时诚实报告 `unknown`（`uv.loadavg()` 在 Windows 恒为 0，MUST NOT 用作判据）。

#### Scenario: 首个差分间隔与已知/未知状态被诚实区分

- **WHEN** 某工作在感知层完成首个差分间隔前/后查询宿主负载，或计数器未推进/平台不支持
- **THEN** 完成前返回 `warming`，完成后返回有效缓存读数且不触发新的整机采样
- **AND** 无法测量时返回 `unknown`，不返回 0 或编造数值；查询方 MUST NOT 把 `warming`/`unknown`
  当作 `idle`

### Requirement: 宿主资源纪律 SHALL 覆盖本配置启动的每个重活，按工作类型区分策略

后台索引、CDB pipeline、csearch/gtags 重建、语言服务器、构建与部署等重活 SHALL 受统一的宿主
负载判定约束（复用同一份采样与双水位滞回阈值，不允许各子系统各写一套可能漂移的判据），且
策略按工作类型区分：**可推迟批任务**在高水位时推迟启动、回落后恢复，推迟有上限不得无限饿死
交付；**长驻交互服务**（如 clangd）MUST NOT 被 kill/suspend（会丢弃已建 preamble），只用可逆
的 OS 级降级；**用户显式发起的前台任务**不被自动推迟或降级，但会抑制新后台批任务启动，且
MUST NOT 为省 CPU 终止已运行的批任务。并发预算参数（`-j` 等）同时受 RAM 与 CPU 约束并为 UI
保留余量。系统 MUST NOT 声称能保证宿主 CPU 低于任何阈值，MUST NOT 操作非自身启动的进程；
契约仅为不在宿主已饱和时继续加压，且在饱和时主动让路。负载不可测量时 SHALL 视为无压力按既有
行为执行，不得因无法测量永久阻塞工作。

#### Scenario: 不同工作类型在宿主饱和时的处置符合各自契约

- **WHEN** 宿主 CPU 高于高水位，分别存在可推迟批任务到期、长驻 clangd 运行中、用户显式发起
  前台构建，或饱和主要由外部进程造成
- **THEN** 批任务被推迟且原因可观测；clangd 只受可逆降级而非被杀；前台任务照常执行但抑制新
  后台批任务；外部进程主导饱和时系统仍抑制自身工作但不操作外部进程
- **AND** 任何场景下都不声称能保证宿主 CPU 低于阈值

## 选型与踩坑

- **选型（2026-10-03）**：C/C++ 手动格式化先找工程配置，缺失时由用户选择本仓 UE 模板，
  不以 LLVM 默认或 LSP fallback 替代工程风格；自动格式化保持默认关闭。
- **踩坑**：未保存计数不能只监听 `BufModifiedSet`；直接设置 option 和隐藏缓冲区 API 编辑
  有不同事件路径。缓冲区订阅、`OptionSet` 与编辑完成后的单次调度共同维护缓存，状态栏只读。
  原生 `QuitPre` 不能可靠区分 `qa` / `qa!`，因此集中退出面板接常用键和显式命令，保留原生退出语义。
- **踩坑（2026-10-03 收尾复核）**：`BufDelete` 既用于卸载也用于取消列出，回调中仍可能读到
  卸载前的 modified；须在事件完成后校正，不能把隐藏修改排除。原生确认用 ASCII 热键，等待
  输入期间仍处理事件，放弃前须复核文件身份和 changedtick，拒绝丢弃确认后才出现的修改。

- **选型**：感知层（只读负载）与准入判定层（阈值/推迟/降级策略）严格分离——避免阈值散落多处
  互相漂移，也让「诚实上报未知」不被策略逻辑污染。
- **踩坑**：`change_detection` 默认周期回调会在主循环上同步 `fs_stat` 全部 spec 模块，命中变更
  时进一步触发 `Plugin.load()`；处置为显式关闭并在运行时校验意图未漂移。
- **踩坑**（K40 一般化）：周期性回调中使用 `vim.fn.system`/`vim.fn.systemlist` 会造成同步子进程
  往返阻塞主循环；处置为改用 `vim.system` 异步回调或 `jobstart`。
- **踩坑**：`vim.system():wait()` 在本宿主的空 spawn 底线约 87ms p50，`client:request_sync`
  默认可堵至 5000ms；交互路径（如 `gr`）必须走异步 provider，且异步化不得丢失
  `includeDeclaration` 等参数导致返回集变化。
- **重要事项**：`uv.getrusage()` 不包含仍在运行的子进程（如 clangd），剩余占用只能标记为
  `unattributed`，不能编造归属；`uv.loadavg()` 在 Windows 恒为 0，禁止作为判据。
