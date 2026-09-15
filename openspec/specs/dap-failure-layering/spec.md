# dap-failure-layering Specification

## Purpose
为 DAP 调试链建立**归属分层契约**：任何调试失败必须先指认它属于哪一层（宿主工具链 /
传输 / 目标 OS 策略 / 调试引擎 / 符号语义）以及该层的 owner，再给处置；设备能力必须探测
而非假设；attach 前必须过能力门禁，使外部契约失败自诊断，而不是每月在现场取证。
## Requirements
### Requirement: 五层归属契约 SHALL 是所有 agent 的第一手可见规则

系统 SHALL 定义并维护一份 DAP 五层归属契约（L0 宿主工具链 / L1 传输 / L2 目标 OS 策略 /
L3 调试引擎 / L4 符号语义），每层 SHALL 声明其 owner 模块与判定手段。

该契约 SHALL 出现在**三端共用的唯一内容源**（根 `AGENTS.md`）与 `docs/CONSTRAINTS.md`，
并 SHALL 在 `lua/ue/dap/AGENTS.md` 本地规则中可见，使 Claude Code / Codex / pi 在
SESSION START 阶段即读到，而 MUST NOT 只存在于源码注释、changelog 或某次会话记录中。
MUST NOT 为让某一个 agent 生效而新增并行入口文件。

#### Scenario: 新 context 的 agent 读到层契约

- **WHEN** 任一 agent 在仓库根开始一个新会话并按 SESSION START 读取强制前置文件
- **THEN** 其读到的内容 SHALL 包含五层归属契约与「失败先报层」纪律
- **AND** 该内容 SHALL 可从根 `AGENTS.md` 一步导航到权威出处

#### Scenario: 契约缺失被回归拦下

- **WHEN** 根 `AGENTS.md`、`docs/CONSTRAINTS.md` 或 `lua/ue/dap/AGENTS.md` 中的层契约被删除或改名
- **THEN** 结构可发现性回归 SHALL 失败并指出缺失位置

### Requirement: DAP 失败 SHALL 先指认层与 owner，再给处置

每个对用户可见的 DAP 失败 SHALL 携带四要素：`layer`（L0–L4）、`owner`（该层负责模块或
外部系统）、`evidence`（可核验的观测，如确切命令与其退出码/输出）、`remedy`（下一步动作）。
失败反馈 SHALL 先呈现层与 owner，再呈现处置，MUST NOT 只给症状文本。

系统 MUST NOT 发出不带层归属的 DAP 失败。当层无法判定时，SHALL 显式标注为「未判定」
并给出用于判定的下一步，MUST NOT 猜测一个层。

#### Scenario: 目标 OS 策略拒绝

- **WHEN** 设备策略拒绝了某个必要能力（例如 app uid 无法执行 staged 二进制）
- **THEN** 失败 SHALL 归入 L2 并指明目标 OS 策略为 owner
- **AND** evidence SHALL 包含实际执行的命令与其退出码或拒绝文本
- **AND** MUST NOT 表述为调试引擎（L3）或本仓代码缺陷

#### Scenario: 调试引擎行为

- **WHEN** 失败源自调试引擎自身行为或缺陷
- **THEN** 失败 SHALL 归入 L3 并给出协议级或 packet 级事实作为 evidence
- **AND** MUST NOT 把它表述为设备策略问题

#### Scenario: 层未判定时不猜

- **WHEN** 现有证据不足以判定层归属
- **THEN** 反馈 SHALL 显式标注层为未判定
- **AND** SHALL 给出可执行的判定手段
- **AND** MUST NOT 呈现一个未经证据支持的层归属

#### Scenario: 无层失败被回归拦下

- **WHEN** 某个 DAP 失败路径发出不含层归属的用户可见错误
- **THEN** 回归 SHALL 失败并指出该发出点

### Requirement: attach SHALL 先过能力门禁

系统 SHALL 提供一个用户可触发的前置检查，按 L0→L4 顺序判定当前环境是否具备完成一次
attach 的能力，并对每层给出通过 / 失败 / 不适用的判定与其 evidence。该检查 SHALL 异步执行，
MUST NOT 阻塞主循环。

当 L2（目标 OS 策略）判定为失败时，attach SHALL 在发起调试引擎连接**之前**以带层归属的
错误终止，MUST NOT 继续把该失败推迟到 L3 表现为连接或 attach 的通用错误。

系统 SHALL 提供逃生开关以在门禁误判时仍能发起 attach，且使用该开关 SHALL 在反馈中留痕。

#### Scenario: L2 红灯不进入 L3

- **WHEN** 前置检查判定目标 OS 策略层不具备必要能力
- **THEN** attach SHALL 立即以 L2 归属的错误终止
- **AND** 反馈 SHALL 给出确切的拒绝命令与其输出
- **AND** 系统 MUST NOT 启动调试引擎连接

#### Scenario: 逐层判定可读

- **WHEN** 用户主动运行前置检查
- **THEN** 输出 SHALL 逐层给出判定与 evidence
- **AND** 首个失败层 SHALL 被明确标识为阻塞层
- **AND** 该层之后的层 MAY 标注为未判定而不必强行探测

#### Scenario: 前置检查不阻塞编辑器

- **WHEN** 前置检查执行设备侧命令
- **THEN** 命令 SHALL 异步执行
- **AND** MUST NOT 在主循环内同步等待子进程

#### Scenario: 逃生开关留痕

- **WHEN** 用户以逃生开关跳过门禁并发起 attach
- **THEN** 系统 SHALL 记录该跳过行为
- **AND** 后续失败反馈 SHALL 说明门禁已被显式跳过

### Requirement: 设备能力 SHALL 由探测得出，MUST NOT 假设单台设备的结论

判定一次 attach 可行性所需的设备能力（例如受限用户能否执行 staged 二进制、能否
ptrace 目标进程、沙箱路径是否可用、强制访问控制是否生效）SHALL 由针对当前设备的探测
得出，MUST NOT 以某一台已验证设备的答案作为其他设备的既定前提。

探测 SHALL 以最小权限视角进行：判定某身份能否执行某动作时，SHALL 以**该身份**探测，
MUST NOT 以另一个更高权限身份的探测结果代替。

探测结论 SHALL 可被复现：每条结论 SHALL 能追溯到一条具体命令与其输出。

#### Scenario: 换设备不需要改代码

- **WHEN** 在一台此前未验证过的设备上发起 attach
- **THEN** 系统 SHALL 探测其实际能力并据此判定
- **AND** MUST NOT 因为设备与既有验证设备不同而给出误导性的层归属

#### Scenario: 以正确身份探测执行权限

- **WHEN** 判定某受限身份能否执行一个已 staged 的二进制
- **THEN** 探测 SHALL 以该身份执行
- **AND** 更高权限身份的同名探测结果 MUST NOT 被当作该判定的依据

#### Scenario: 能力探测结论可追溯

- **WHEN** 前置检查报告某层失败
- **THEN** 该结论 SHALL 附带其来源命令与输出摘要
- **AND** 未经命令验证的推断 SHALL 标注为推断而非事实

### Requirement: 真机端到端验证 SHALL 可按需触发并产出脱敏证据

系统 SHALL 提供一个按需触发的真机端到端验证入口，覆盖从能力门禁到 attach 成功判据的
完整链路，并产出可归档的结构化证据。

该证据 MUST NOT 包含真实设备标识、包标识、进程号或个人路径；SHALL 只保留摘要、
判定与摘要化的度量。验证 SHALL 明确区分「宿主不具备该能力因此不适用」与「具备但失败」，
MUST NOT 通过注入假可执行文件或假宿主让验证碰巧通过。

#### Scenario: 端到端验证产出判定与证据

- **WHEN** 用户在具备设备的宿主上触发真机验证
- **THEN** 系统 SHALL 逐层记录判定并给出最终成败
- **AND** SHALL 落一份脱敏的结构化证据

#### Scenario: 缺少设备时诚实不适用

- **WHEN** 当前宿主没有可用目标设备
- **THEN** 验证 SHALL 报告为不适用而非通过
- **AND** MUST NOT 伪造设备或可执行文件以取得通过

#### Scenario: 证据不泄漏身份

- **WHEN** 验证证据被写入仓库可归档位置
- **THEN** 证据 MUST NOT 含真实设备标识、包标识、进程号或个人路径

