# android-dap-attach

## Purpose

UE Android DAP attach、断点与设备路由的目标行为契约。当前以 host
LLVM 22.1.6+ `lldb-dap`、device `lldb-server platform`、K30 serial-form URL 为准；
交互式流程消费当前 Neovim 进程内选择的 Android serial，程序化显式 serial 保持最高优先级。
## Requirements
### Requirement: device 端用 lldb-server platform 模式，不用 gdbserver --attach

系统 SHALL 用 `lldb-server platform --server` 启动设备端 platform server，并 `adb forward`
该端口。MUST NOT 使用 `gdbserver --attach <pid>`（该形态在真机从不绑定监听端口）。
server 的运行 uid、路径与 listen 参数由下一条 Requirement 规定。

#### Scenario: platform server 正常监听

- **WHEN** `<space>da` 触发 Android attach
- **THEN** 设备端以 `platform --server --listen` 启动并进入 LISTEN 状态
- **AND** 不再使用 `gdbserver --attach <pid>`

### Requirement: platform server 以 app uid 从 app sandbox 运行

系统 SHALL 以 app uid（经 `run-as <package>`）从 app sandbox 内的副本
`/data/data/<package>/lldb-server` 启动 device 端 platform server，MUST NOT 以 shell uid
从 `/data/local/tmp` 启动它。

该形态是当前已验证设备上的**唯一可行运行形态**，但其可行性 SHALL 由针对当前设备的能力
探测确认（见「设备能力 SHALL 探测得出而非沿用既有设备结论」），MUST NOT 作为对所有设备
无条件成立的前提；探测失败时 SHALL 以 L2 归属报告，MUST NOT 静默回退到 shell uid 形态。

理由（K56，2026-09-03 真机）：在 `ro.debuggable=0` 的 `user` build 上 shell uid 无法 ptrace
app 进程，NDK 27 LLDB 18 的 lldb-server 不把该拒绝报成错误——其 fork 的 per-target
gdbserver 子进程在 `vAttach` 里 SIGSEGV，host 仅看到 `error: attach failed: lost connection`。
同一健康目标上 A/B：shell uid 3/3 失败，app uid 3/3 成功。device server 版本不是变量
（LLDB 9/14/18 在 shell uid 下全部同样失败），MUST NOT 通过降级 device server 版本来「修」它。

`/data/local/tmp/lldb-server` 保留为 `adb push` 的中转路径，不是 server 的运行路径。

#### Scenario: 两跳 staging 到 app sandbox

- **WHEN** attach bootstrap 推送 lldb-server
- **THEN** 系统 SHALL 先 `adb push` 到 `/data/local/tmp/lldb-server` 作为中转
- **AND** SHALL 经 `run-as <package>` 用 `cat <公共路径> > /data/data/<package>/lldb-server`
  复制进 sandbox 并 `chmod 700`（用 `cat` 重定向而非 `cp`，跨 sandbox 边界 `cp` 会 EACCES）
- **AND** SHALL 校验 sandbox 副本可执行后才继续，否则以明确错误中止

#### Scenario: 复用快路径只以 app uid 探测 sandbox 副本

- **WHEN** staging 判断能否跳过某一跳
- **THEN** transport 跳的「同尺寸 + 可执行」判定 SHALL 只用于跳过 `adb push`，
  MUST NOT 被当作「server 已可运行」而把 `/data/local/tmp/lldb-server` 作为运行路径返回
- **AND** run path 的复用判定 SHALL 以 `run-as <package>` 在 app uid 下同时校验
  sandbox 副本的尺寸与 `test -x`，两者都成立才跳过重新 staging
- **AND** shell uid 对公共中转路径的 `test -x` MUST NOT 参与 run path 判定

理由（K58，2026-09-03 真机实测）：公共中转副本的 SELinux 标签是
`u:object_r:shell_data_file:s0`（owner `shell`），app 域可读但不可执行；sandbox 副本标签为
`u:object_r:app_data_file:s0:…`（owner app uid）。`getenforce` = `Enforcing`。同一台设备上
app uid `test -x /data/local/tmp/lldb-server` rc=1、直接 exec 得
`sh: …: can't execute: Permission denied`（rc=126）；对 sandbox 副本 rc=0。
早期实现在 transport 判定为 `reuse` 时提前返回公共路径作为运行路径，导致启动命令变成
`run-as <pkg> sh -c '/data/local/tmp/lldb-server platform --server …'` → 126 退出、设备端
无监听，host 侧表现为 `platform connect` 的
`Connection shut down by remote side while waiting for reply to initial handshake packet`
与随后的 `process attach` 失败。

#### Scenario: 以 app uid 启动 platform server

- **WHEN** 系统启动 device 端 platform server
- **THEN** 启动命令 SHALL 经 `run-as <package>` 执行
- **AND** 可执行文件路径 SHALL 是 `/data/data/<package>/lldb-server`
- **AND** listen 参数 SHALL 双引号保护为 `--listen "*:<port>"`，使 device shell 不会把 `*`
  glob 成 sandbox 内的文件名
- **AND** 启动命令 MUST NOT 采用 `cd /data/local/tmp && ./lldb-server …` 的 shell-uid 形式

#### Scenario: 收尾清理两个 uid 的残留 server

- **WHEN** session 结束触发 device 端清理
- **THEN** 系统 SHALL 同时 kill shell uid 与 app uid（`run-as <package>`）下的 lldb-server
- **AND** 理由 SHALL 是：残留的 shell-uid server 会占住端口并静默把 SEGV 路径带回来

### Requirement: platform 连接使用 K30 serial-form 路线

系统 SHALL 使用已验证的 Android platform-mode serial-form 连接路线建立 attach 会话，不得回退到已证伪的 `gdbserver --attach`。交互式 DAP attach/launch SHALL 优先使用当前 Neovim 进程选择的 `vim.g.ue_android_device_serial`；程序化调用显式传入的 `context.android_serial` / `opts.serial` SHALL 保持最高优先级。选定后，该 serial SHALL 同时用于 `platform connect connect://[<serial>]:<port>` 与本次 session 的全部设备定向 ADB 命令。禁止 localhost / 127.0.0.1 形式与已证伪的 `gdbserver --attach` 路线。

#### Scenario: 用全局 serial-form platform connect 建立连接

- **WHEN** `vim.g.ue_android_device_serial = "SERIAL-002"` 且交互式构建 lldb-dap attach 配置
- **THEN** attachCommands SHALL 包含 `platform select remote-android`
- **AND** attachCommands SHALL 使用 `platform connect connect://[SERIAL-002]:<port>`
- **AND** attachCommands SHALL 随后执行 `process attach --pid <pid>`
- **AND** 本次 bootstrap/cleanup 的设备定向 ADB 命令 SHALL 使用 `adb -s SERIAL-002 ...`
- **AND** attachCommands MUST NOT 使用 `platform connect connect://localhost:<port>` 或 `platform connect connect://127.0.0.1:<port>`

#### Scenario: 程序化显式 serial 保持可复现

- **WHEN** headless/tool 调用显式传入 `context.android_serial = "SERIAL-AUTO"`，同时全局 serial 为其他值
- **THEN** 本次 attach SHALL 使用 `SERIAL-AUTO`
- **AND** K30 connect URL 与全部设备定向 ADB 命令 SHALL 使用同一个 `SERIAL-AUTO`

#### Scenario: 未设置时先选设备

- **WHEN** 交互式 DAP attach/launch 没有显式 serial 且全局 serial 为空
- **THEN** 系统 SHALL 打开同时显示 device 名称与 serial 的统一选择 UI
- **AND** 选择成功后 SHALL 写入全局 serial 并继续 attach
- **AND** 取消时 SHALL 中止 attach，不猜测第一台或唯一一台设备

#### Scenario: 连接建立无旧路径错误

- **WHEN** 连接执行
- **THEN** 不出现 `error: Invalid URL:`
- **AND** 不出现 `Connection shut down ... initial handshake` 超时
- **AND** 不启动 `lldb-server gdbserver --attach <pid>`

### Requirement: attach 后 ASLR rebase

系统 SHALL 在连接 + attach 成功后，对 libUE4.so 显式
`target modules load --file libUE4.so --slide 0x<base>`，base 运行时从设备
`/proc/<pid>/maps` 读取。

#### Scenario: 用运行时 base rebase

- **WHEN** attach 完成
- **THEN** 读 `/proc/<pid>/maps` 取 libUE4.so 首映射 base（每次冷启会变，不缓存跨会话）
- **AND** 下发 `target modules load --file libUE4.so --slide 0x<base>`
- **AND** hex 字符串用拼接构造，MUST NOT 用 `string.format("%x", addr)`

### Requirement: Android 项目和符号包发现不得固定项目名

系统 SHALL 从显式 `.uproject` 或唯一的 `Source/<Project>/*.uproject` 派生 Android 输出目录，并从符号包实际目录发现 `<Target>-arm64`，不得假设项目或 Target 名为固定字符串。

#### Scenario: 非 Client 项目的 nested layout

- **WHEN** 项目位于 `<repo>/Source/<Project>/<Project>.uproject` 且 Android 输出位于该项目的 `Binaries/Android`
- **THEN** packageInfo 与符号库发现 SHALL 使用该项目目录
- **AND** versionCode 精确匹配 SHALL 接受任意 `<Target>_Symbols_v<code>/<Target>-arm64` 目录
- **AND** 多个 nested 项目同时具有 Android 输出且没有显式 `.uproject` 时 SHALL 不猜测项目

### Requirement: F9 断点真实 resolved 并命中

系统 SHALL 让 Android file:line 断点真实下发、resolve 并在目标运行到对应代码时命中，
覆盖 **attach 前已存在**（attach-time preseed）与 **会话中运行时新增/修改**（live 通道）
两类断点；`verified` MUST 反映真实 LLDB 状态，MUST NOT 无条件返回固定成功值，MUST NOT
要求 `:UEDAPReattach` 重连才能应用会话中 F9 变更。

#### Scenario: 断点接通判定

- **WHEN** 验证 F9 断点（无论 attach-time 还是 session-time）
- **THEN** DAP 响应 SHALL 返回与真实植入状态一致的 `verified`
- **AND** lldb `breakpoint list` 中该断点 SHALL `resolved>0`
- **AND** 适配器进程 SHALL 存活（无 `3221226505`）
- **AND** 目标运行到对应位置时 SHALL 触发 breakpoint stop
- **AND** stop frame SHALL 映射到正确本地源码行

#### Scenario: 会话中新增断点即时生效

- **WHEN** DAP 会话已 attach 且进程运行中，用户按 F9 新增断点
- **THEN** 系统 SHALL 经 live 通道即时下发该断点到 LLDB
- **AND** 该断点 SHALL 在不重连会话的前提下 resolve 并在命中位置触发 stop
- **AND** 系统 MUST NOT 提示需要 `:UEDAPReattach`

#### Scenario: 断点未生效时不伪装成功

- **WHEN** 断点未下发、pending、路径匹配失败、符号/ASLR 未就绪或 LLDB 命令失败
- **THEN** 系统 MUST NOT 报告无条件成功
- **AND** 反馈 SHALL 包含可用于定位失败层级的信息
- **AND** 系统 MUST NOT 通过静默 detach+reattach 伪装即时生效

### Requirement: 入口停顿不报 Source missing

系统 SHALL 在 UE Android 入口 stopOnEntry 合成帧时不触发源码跳转。

#### Scenario: 入口合成帧不 jump

- **WHEN** attach 入口停在 PC-only 合成帧
- **THEN** 不调用 jump，不出现 `Source missing, cannot jump to ...`

### Requirement: 仅改 nvim 配置且保持 host adapter 约束

该 attach 实现 SHALL 保持在本 nvim 配置仓的 Lua/OpenSpec/docs/tests 边界内，MUST NOT
修改或替换 host adapter / device binary；host adapter SHALL 维持 LLVM 22.1.6+
forward-only。每次 session 选定 serial 后，全部设备命令与收尾清理 SHALL 显式使用
`-s <session.serial>`，不得固定某一台设备或在运行中重读 global 改投其他设备。

#### Scenario: 边界与 selected serial 保持

- **WHEN** 该 attach 实现被应用并以 `SERIAL-002` 建立 session
- **THEN** host adapter SHALL 维持 LLVM 22.1.6+
- **AND** 实现 SHALL 不改 host adapter / device binary
- **AND** 全部设备命令与收尾清理 device lldb-server + forward SHALL 指定 `-s SERIAL-002`

### Requirement: 会话结束原因必须讲事实

会话中的 app 死亡时，系统 SHALL 报告**可核验的死亡原因**，MUST NOT 只给出无信息量的
"App … exited. Detaching."——那会让「进程被外部 SIGKILL（不可捕获）」与「调试器漏掉了
崩溃」在用户侧无法区分。

事实基础（2026-09-03 实测）：lldb-dap 只提供裸状态
（`{"body":{"exitCode":9},"event":"exited"}` 与 console 行
`Process <pid> exited with status = N (0x…)`），且 `liblldb` 中不存在任何
"Terminated due to signal" 文本，因此信号语义必须由本仓 Lua 层合成；设备侧唯一能指认
「谁杀的」的权威是 `dumpsys activity exit-info <package>` 的 `ApplicationExitInfo`
记录（`reason` / `subreason` / `status` / `description`）。

#### Scenario: 外部 force-stop（不可捕获）

- **WHEN** 会话中 app 死亡，DAP 报 exit status 9，且设备记录为
  `reason=10 (USER REQUESTED) subreason=21 (FORCE STOP)`
- **THEN** 反馈 SHALL 指明该状态对应 SIGKILL 且**无法被任何调试器捕获**
- **AND** 反馈 SHALL 包含设备侧 `reason`/`subreason` 与 `description`（指认发起方）
- **AND** 反馈 SHALL 显式否掉「调试器漏掉了崩溃」这一错误印象

#### Scenario: app 自身崩溃路径

- **WHEN** 设备记录为 `reason=1 (EXIT_SELF)`，或 exit status 落在 UE 的
  `TargetSignals`（SIGQUIT/SIGILL/SIGFPE/SIGBUS/SIGSEGV/SIGSYS/SIGABRT/SIGTRAP）
- **THEN** 反馈 SHALL 表述为 app 走了自身崩溃路径
- **AND** 反馈 MUST NOT 宣称该死亡不可捕获

#### Scenario: 取不到设备记录时不编造

- **WHEN** 设备不可达（wifi ADB 掉线正是本场景）或该 pid 无 `ApplicationExitInfo` 记录
- **THEN** 系统 SHALL 仍报告 lldb 侧状态
- **AND** SHALL 告知用户自行取证的命令，而 MUST NOT 把推断当作事实
- **AND** 措辞 SHALL 为「匹配某信号」而非断言「被某信号杀死」（lldb 对 `exit(N)` 与
  死于信号 N 打印同一字段，无法区分）
- **AND** 探针 SHALL 落一条 `android-session-exit` 记录以便事后复查

### Requirement: 真实致命信号必须可停

系统 SHALL 让 UE 的真实致命信号在调试器中产生**真实 stop**，同时保持 K3 对 ART 良性
陷阱的 `--stop false` 处置不回退。

事实基础：ART 通过 `libsigchain.so` 把 SIGSEGV/SIGBUS 用作 JIT read barrier /
压缩 GC card-table / heap poisoning 的常规机制，故按**信号号**无法区分良性与致命；但按
**符号**可以——NDK 27 `llvm-nm` 实测出货 symbol `libUE4.so` 中存在
`FFatalSignalHandler::OnTargetSignal(int, siginfo*, void*)`，它在故障线程上运行。

#### Scenario: 符号断点在 attach 命令序列中的位置

- **WHEN** 构造 Android attach 命令序列
- **THEN** 序列 SHALL 在 `process attach` 与 ASLR `target modules load --slide` 之后
  下发一条限定 `libUE4.so` 的 `FFatalSignalHandler::OnTargetSignal` 符号断点
- **AND** 该命令 SHALL 以 `?` 前缀标记为非致命：符号不匹配的构建 MUST NOT 中断整个 attach
- **AND** SIGSEGV/SIGBUS 处置 SHALL 仍为 `--pass true --stop false`（K3 不回退）
- **AND** 系统 SHALL 提供 `UE_DAP_NO_FATAL_BP=1` 逃生开关以还原旧行为

### Requirement: attach SHALL 先过 L2 能力门禁再连接调试引擎

Android attach SHALL 在发起 `platform connect` **之前**判定目标 OS 策略层（L2）是否具备
必要能力：staged 二进制能否被将要运行它的身份执行、该身份能否 ptrace 目标进程、沙箱
运行路径是否就绪。任一项失败时 attach SHALL 以 L2 归属的错误终止，并给出确切的拒绝
命令与其输出。

MUST NOT 把 L2 失败推迟到 L3 表现为 `platform connect` handshake 失败、
`attach failed: lost connection` 或 `attach failed: The parameter is incorrect`——这三种
症状均**不指向**根因，是历史上反复消耗数小时取证的直接原因（K56 / K58）。

#### Scenario: 执行权限缺失在连接前被拦下

- **WHEN** 将要运行 platform server 的身份对 staged 二进制没有执行权限
- **THEN** attach SHALL 在启动 device server 与 `platform connect` 之前终止
- **AND** 错误 SHALL 归入 L2 并附带该身份下的探测命令与其退出码
- **AND** MUST NOT 出现 handshake 或 `attach failed` 类下游症状

#### Scenario: ptrace 能力缺失在连接前被拦下

- **WHEN** platform server 的运行身份无法 ptrace 目标进程
- **THEN** attach SHALL 以 L2 归属终止并说明该身份不具备 ptrace 能力
- **AND** 反馈 MUST NOT 把 device server 版本表述为首要变量

#### Scenario: 门禁通过后才进入 L3

- **WHEN** L2 全部判定通过
- **THEN** 系统 SHALL 继续启动 device server 并 `platform connect`
- **AND** 此后的失败 SHALL 归入 L3 并给出协议级事实

### Requirement: 设备能力 SHALL 探测得出而非沿用既有设备结论

Android attach 依赖的设备能力 SHALL 针对当前设备探测：受限身份的执行权限、ptrace 可行性、
沙箱路径可用性、强制访问控制模式、`run-as` 可用性。系统 MUST NOT 把某一台已验证设备的
答案当作其他设备的既定前提。

判定「某身份能否执行某动作」时 SHALL 以**该身份**探测；更高权限身份的同名探测结果
MUST NOT 代替该判定（K58：shell uid 的 `test -x` 对 app uid 的执行权限零信息量）。

#### Scenario: 未验证设备上给出正确层归属

- **WHEN** 在一台此前未验证过的 Android 设备上发起 attach
- **THEN** 系统 SHALL 探测其实际能力并据此判定与分层
- **AND** MUST NOT 因设备与既有验证设备不同而给出误导性归属或静默失败

#### Scenario: 沙箱路径不可用时诚实归层

- **WHEN** 当前设备不提供预期的 app 沙箱运行路径或 `run-as` 不可用
- **THEN** 系统 SHALL 以 L2 归属报告该能力缺失
- **AND** SHALL 给出探测命令作为 evidence
- **AND** MUST NOT 回退到已被证伪的受限身份运行形态

