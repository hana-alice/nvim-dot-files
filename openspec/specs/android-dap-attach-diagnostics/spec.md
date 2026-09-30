# android-dap-attach-diagnostics Specification

## Purpose

诊断契约：UE Android DAP attach 失败与 F9 断点失效的分层定位、判定标准与出处。
边界：只规定诊断文档与可判定诊断入口应覆盖哪些层、给出什么证据；不改变
`lua/ue/dap/*.lua` 的运行时 attach/断点行为本身（那部分由 `android-dap-attach`、
`android-dap-live-breakpoints` 契约管）。

## Requirements

### Requirement: 诊断文档必须存在且分层覆盖 attach 失败排查路径

仓库 SHALL 在 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 提供
Android DAP attach 失败诊断文档，把排查拆成自顶向下的若干层（host adapter、
ADB/forward、设备端 `lldb-server platform`、serial-form platform connect、
ptrace/进程架构边界），每层给出可执行验证手段与判定标准。文档 MUST 将 sandbox
`gdbserver --attach` 标为已证伪的历史路线，不得继续写成当前前置条件；旧诊断
证据（sandbox gdbserver、单设备假设、已修复的 F9 short-circuit）SHALL 标记为
historical/superseded，当前排查步骤指向 `android-dap-attach`、
`android-dap-live-breakpoints`、`dap-platform-dispatch` 的现行契约。

#### Scenario: 遇到 lost connection 先核对运行 uid

- **WHEN** 排查遇到 `Cannot get process architecture` / `lost connection`
- **THEN** ptrace 层 SHALL 首先核对 platform server 的运行 uid（K56：shell uid
  在 `ro.debuggable=0` 的 user build 上无权 ptrace app），MUST NOT 把 device
  server 版本当作首要变量

### Requirement: 诊断必须暴露 F9 断点当前被设计性短路的两处代码事实

诊断文档 SHALL 明确指出：`lua/ue/dap.lua` 曾将 Android 会话的 `setBreakpoints`
拦截为合成响应，且 `lua/ue/dap/android.lua` 的 preseed 调用曾被注释未下发，避免
被误判为环境问题。断点接通的判定标准 SHALL 同时要求 DAP 侧 `verified=true` 与
lldb 侧 `breakpoint list` 中 `resolved` 计数大于 0；仅 UI 上出现断点标记不算
接通。

#### Scenario: 断点接通的判定标准

- **WHEN** 后续验证断点是否真正接通
- **THEN** 文档要求同时满足 DAP 侧 `verified=true` 与 lldb 侧 `breakpoint list`
  中 `resolved` 计数大于 0
- **AND** 仅 UI 上出现断点标记不算接通

### Requirement: 分层定位必须提供机器可判定的逐层结论，且不依赖活跃会话

Android attach 的分层定位 SHALL 除文档排查顺序之外，提供机器可判定的逐层结论：
每层给出通过/失败/不适用，并附带判定所依据的确切命令与输出；首个失败层 SHALL
被明确标识为阻塞层。该判定 SHALL 可在没有活跃调试会话时运行——历史上诊断入口
需要活会话才能给信息，导致"attach 都起不来"时恰恰拿不到诊断。

#### Scenario: 无活跃会话也能取得逐层判定

- **WHEN** 用户在没有任何活跃 DAP 会话时请求分层判定
- **THEN** 系统 SHALL 逐层给出判定与 evidence，MUST NOT 因缺少活跃会话而拒绝
  给出结论

### Requirement: 该诊断能力不得改变运行时行为

该诊断 change SHALL 仅产出诊断文档，不修改 host adapter 版本策略
（22.1.6+ forward-only）、不修改 `stopOnEntry=true`、不在 attachCommands/
postRunCommands 加 `process continue`、不动 SIGSEGV/SIGBUS 信号处置。

#### Scenario: 保持既有边界不变

- **WHEN** 该诊断 change 被应用
- **THEN** 不修改 host adapter 版本策略、`stopOnEntry` 语义与信号处置
- **AND** 不新增运行时代码修改，只新增/更新诊断文档

## 选型与踩坑

- **踩坑**：历史诊断入口要求活跃 DAP 会话才能给出信息，而 attach 起不来正是
  最需要诊断的场景，形成"最需要诊断时诊断不可用"的死锁。处置：诊断判定必须
  能在无活跃会话时独立运行。
- **重要事项**：ASLR slide 缺失（缺少 `target modules load --slide` 模块 rebase）
  是断点解析到错地址的潜在原因（对应 `docs/CONSTRAINTS.md` K2/K11），诊断要求
  比对 `image list libUE4.so` 的 base 与设备 `/proc/<pid>/maps` 首映射地址。
