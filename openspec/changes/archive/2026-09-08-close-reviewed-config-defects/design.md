## Context

本文件是实施与验证后的设计补录，动机和范围见 `proposal.md`。详细改动及既有证据已归入 `docs/release_1.9.0.md`。这次收口包含此前 Android DAP 工作和本轮全仓审查修复；不能把本轮 headless 回归解释成重新完成真机调试验证。

主规格已经同步到工作区。delta 从补录时的 `HEAD` 与当前主规格提取，记录 10 项 capability 的新增或修改 requirement；修改块包含全部现有 scenario。Android 符号发现 requirement 同时改名和扩展，因此保留 RENAMED 操作及新名称的完整 MODIFIED 块。

## Goals / Non-Goals

**Goals:**

- 将异步结果、持久化与 DAP 状态写入绑定到捕获的 project/session owner。
- 确保独占 writer lease、失败保留旧索引，以及不可证明的编译上下文明确拒绝或 exact fallback。
- 使用户实际输入、协议位置与语义缓存的新鲜度成为可重复验证的行为。
- 使新环境能够安装既有锁定依赖并运行权威回归，保留真实宿主能力边界。

**Non-Goals:**

- 不重写 `ue.lua` 或引入另一套插件、索引器、安装器或语义解析体系。
- 不把 shell uid 的握手 control 提升为 Android attach 路线。
- 不以测试替身、headless 或某个设备的结果宣称全部宿主、GUI、PCH 和真机链路成功。

## Decisions

### 1. owner 必须进入最终写入地址

project updater 消费捕获的地址；watcher 的旧事件失效，保存重试持续指向原 owner。断点交接先保存旧 bucket，再清除它管理的 live store；活跃 DAP 会话结束前延迟交接。仅在操作启动时捕获 context、完成时仍读取当前选择，不能解决 A 操作写入 B 的问题。

`dirty_save.lua` 承担绑定路径的有界退避保存，以保持 watcher 的行数门禁和明确状态归属。永久 I/O 失败给出一次告警；成功保存使排队重试失效。

### 2. 发布前完成产物，回收只能触及观察到的 owner

lease 以完整且带唯一 token 的非空 owner 目录发布。旧回收者只删除自己观察到的 owner 文件；损坏、不可读或死亡状态无法证明的 owner 按 fail closed 处理。递归删除整个锁目录可能破坏已替换的新 owner，因此不能用于过期回收。

Go cindex 的 reset/add 先完成暂存并释放 writer 句柄，再替换正式路径；读取端只校验正式索引的有界格式信息。文件足够大和暂存路径存在都不构成完整发布证据。

### 3. 编译语义由 active command 和 compiler evidence 决定

response、Definitions、PCH 和 UHT 输入必须由 active argv 明确引用或证明。缺失、循环 response 保留原始 command；无法证明 unity 与 active command 的语义一致时回到 exact command。跨平台 Editor 路径猜测虽可能增加覆盖外观，却不能证明正确宏分支。

sidecar 以 compiler-authored inclusion 集合和主文件磁盘签名检查已保存源码变化，失效 warm TU 与 destination cache；检查留在 sidecar，避免扫描项目或阻塞编辑器。

### 4. 交互与回调边界采用真实事件证据

LSP 位置按选定 client encoding 转换，self/declaration 判定使用精确位置或范围。跳转和 lineage 更新之前检查请求与 generation；取消后的响应不得改动新请求状态。

Visual 替换读取当前 anchor/cursor/type；picker 删除会撤销正常按键的通用回拉；Git sidebar 消费 NUL porcelain 原始路径及双路径记录。回归使用实际选区、光标移动、Git 特殊文件名与异步回调，替代仅检查源码字符串的旧断言。

### 5. Android build identity、host symbol 与 runtime module 分层

构建和 DAP 共用 Target/Configuration resolver。当前配置产物需要真实 ELF section 的 DWARF 证据；runtime module 由 `DT_SONAME` 关联，LLDB 仍操作 host 符号模块。弱版本候选不唯一时拒绝猜测；普通 attach 不复用旧配置的符号快照。

只有成功的 DAP attach response 允许更新 reattach 快照。app uid listener 的存在不证明握手成功；同设备、同 binary 的 shell control 仅隔离握手差异，不能证明 shell 可以 ptrace app。

### 6. CI 初始化与只读健康检查分别承担责任

CI checkout 位于隔离 `stdpath(config)`，bootstrap 验证锁定插件 HEAD 并编译加载 c/cpp/hlsl parser。bootstrap 冻结输入 lock，避免 Lazy 分轮发现依赖时删除尚未安装的 pin；安装阶段延迟 startup，并显式限制安装并行度与 parser 集合。

只读 health 缺少 lazy.nvim 时明确失败；正常配置清空继承的 Mason 自动安装计划。CI 保留 smoke/lint，并运行全量 Lua 与已有 Go 工具回归。已有运行依赖由 CI 初始化，产品依赖集合不扩张。

## Risks / Trade-offs

- [旧进程仍使用旧锁代码] → 旧实例需要重启；新协议不能限制旧进程继续递归删锁。
- [发布前崩溃留下 pending 目录，未知 owner 无法安全回收] → 不占正式 lease 的残留保留；未知正式 owner 给出诊断，不猜测死亡。
- [不可写磁盘或长期竞争] → 有界退避耗尽后明确告警，不承诺无法完成的落盘。
- [严格 unity 证明增加 exact TU 比例] → 正确性优先；大型工程重索引时间和 PCH ABI 未在本轮重新测量。
- [Bootstrap 使用锁定 Lazy 的内部启动与 lock 接口] → 逐插件验证 pin；升级相关依赖必须重新验证全新配置/数据环境。
- [Android 当前设备仍有 app uid forwarded handshake 阻断] → 保留此前受控 A/B 证据和未完成端到端的结论，不跨身份回退。
- [GUI 与其他宿主证据不足] → Windows 本机及隔离环境全量通过；原 Neovide mouse-release 现象、远程 workflow 和 macOS/Linux runner 本轮未执行。

## Migration Plan

实现已完成并通过本机与隔离 Windows 全量回归；本 change 仅补录后续同步与归档所需产物。主规格已含全部 delta 内容，归档前须逐块核验，不重复应用 ADDED；随后由主 agent 执行归档、隐私检查、提交和推送。本文件不把这些后续操作记录成已完成。

代码回退应以本次提交为边界评估，并重新验证同一组归属、锁、索引和交互行为；锁协议不能在旧新实例混用时假设独占证明仍完整。
