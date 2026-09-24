## ADDED Requirements

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

## MODIFIED Requirements

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
