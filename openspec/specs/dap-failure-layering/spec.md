# dap-failure-layering Specification

## Purpose

为 DAP 调试链建立**归属分层契约**：任何调试失败必须先指认它属于哪一层、该层的
owner 是谁，再给处置；设备能力必须探测而非假设；attach 前必须过能力门禁。目的是
让外部契约失败能自诊断，而不是每次都要在现场重新取证半天才能定位到底是宿主、
传输、设备策略、调试引擎还是符号语义的问题。

## Requirements

### Requirement: 五层归属契约 SHALL 是所有 agent 的第一手可见规则

系统 SHALL 定义并维护一份 DAP 五层归属契约，每层声明 owner 模块与判定手段：

| 层 | 名称 | Owner |
|----|------|-------|
| L0 | 宿主工具链 | host adapter（如 `lldb-dap` 版本/启动） |
| L1 | 传输 | ADB/forward、platform connect 链路 |
| L2 | 目标 OS 策略 | 设备端权限/沙箱/ptrace/SELinux 等策略 |
| L3 | 调试引擎 | LLDB/lldb-dap 协议与行为本身 |
| L4 | 符号语义 | 符号选择、ASLR、DWARF、地址映射 |

该契约 SHALL 出现在三端共用的唯一内容源（根 `AGENTS.md`）与 `docs/CONSTRAINTS.md`，
并 SHALL 在 `lua/ue/dap/AGENTS.md` 本地规则中可见，使 Claude Code / Codex / pi 在
SESSION START 阶段即读到，MUST NOT 只存在于源码注释、changelog 或某次会话记录中。
MUST NOT 为让某一个 agent 生效而新增并行入口文件。

#### Scenario: 新 context 的 agent 读到层契约

- **WHEN** 任一 agent 在仓库根开始新会话并按 SESSION START 读取强制前置文件
- **THEN** 其读到的内容 SHALL 包含五层归属契约与「失败先报层」纪律
- **AND** 该内容 SHALL 可从根 `AGENTS.md` 一步导航到权威出处

### Requirement: DAP 失败 SHALL 先指认层与 owner，再给处置

每个对用户可见的 DAP 失败 SHALL 携带四要素：`layer`（L0–L4）、`owner`、`evidence`
（可核验的观测，如确切命令与其退出码/输出）、`remedy`（下一步动作）。失败反馈 SHALL
先呈现层与 owner，再呈现处置，MUST NOT 只给症状文本。层无法判定时 SHALL 显式标注
「未判定」并给出判定手段，MUST NOT 猜测一个层。

#### Scenario: 目标 OS 策略拒绝归入 L2

- **WHEN** 设备策略拒绝了某个必要能力（例如 app uid 无法执行 staged 二进制）
- **THEN** 失败 SHALL 归入 L2 并指明目标 OS 策略为 owner
- **AND** evidence SHALL 包含实际执行的命令与其退出码或拒绝文本
- **AND** MUST NOT 表述为调试引擎（L3）或本仓代码缺陷

#### Scenario: 层未判定时不猜

- **WHEN** 现有证据不足以判定层归属
- **THEN** 反馈 SHALL 显式标注层为未判定并给出可执行的判定手段
- **AND** MUST NOT 呈现一个未经证据支持的层归属

### Requirement: attach SHALL 先过能力门禁，L2 红灯不得推迟到 L3

系统 SHALL 提供一个用户可触发的前置检查，按 L0→L4 顺序判定当前环境是否具备完成
一次 attach 的能力，并对每层给出通过/失败/不适用的判定与其 evidence；该检查 SHALL
异步执行，MUST NOT 阻塞主循环。当 L2 判定失败时，attach SHALL 在发起调试引擎连接
**之前**以带层归属的错误终止，MUST NOT 把该失败推迟到 L3 表现为连接或 attach 的
通用错误。系统 SHALL 提供逃生开关以在门禁误判时仍能发起 attach，使用该开关 SHALL
在反馈中留痕。

#### Scenario: L2 红灯不进入 L3

- **WHEN** 前置检查判定目标 OS 策略层不具备必要能力
- **THEN** attach SHALL 立即以 L2 归属的错误终止
- **AND** 反馈 SHALL 给出确切的拒绝命令与其输出
- **AND** 系统 MUST NOT 启动调试引擎连接

### Requirement: 设备能力 SHALL 由探测得出，MUST NOT 假设单台设备的结论

判定一次 attach 可行性所需的设备能力（受限用户能否执行 staged 二进制、能否 ptrace
目标进程、沙箱路径是否可用、强制访问控制是否生效）SHALL 由针对当前设备的探测得出，
MUST NOT 以某一台已验证设备的答案作为其他设备的既定前提。判定某身份能否执行某动作
时 SHALL 以**该身份**探测，MUST NOT 以更高权限身份的探测结果代替；每条结论 SHALL
可追溯到一条具体命令与其输出。

#### Scenario: 换设备不需要改代码

- **WHEN** 在一台此前未验证过的设备上发起 attach
- **THEN** 系统 SHALL 探测其实际能力并据此判定
- **AND** MUST NOT 因为设备与既有验证设备不同而给出误导性的层归属

### Requirement: 真机端到端验证 SHALL 可按需触发并产出脱敏证据

系统 SHALL 提供一个按需触发的真机端到端验证入口，覆盖从能力门禁到 attach 成功判据
的完整链路，并产出可归档的结构化证据；该证据 MUST NOT 包含真实设备标识、包标识、
进程号或个人路径。验证 SHALL 明确区分「宿主不具备该能力因此不适用」与「具备但
失败」，MUST NOT 通过注入假可执行文件或假宿主让验证碰巧通过。

#### Scenario: 缺少设备时诚实不适用

- **WHEN** 当前宿主没有可用目标设备
- **THEN** 验证 SHALL 报告为不适用而非通过
- **AND** MUST NOT 伪造设备或可执行文件以取得通过

## 选型与踩坑

- **踩坑**：历史上 L2（目标 OS 策略）失败被推迟到 L3 才暴露，表现为 `platform
  connect` handshake 失败、`attach failed: lost connection` 或
  `attach failed: The parameter is incorrect`——这三种症状均不指向根因，是反复消耗
  数小时取证的直接原因（K56/K58，见 `docs/CONSTRAINTS.md`）。处置：attach 前置能力
  门禁必须在发起调试引擎连接前判定 L2，红灯立即以 L2 归属终止。
- **重要事项**：能力探测结论必须按身份区分——更高权限身份的探测结果对判定受限身份
  的能力零信息量（K58：shell uid 的 `test -x` 对 app uid 的执行权限无参考价值）。
