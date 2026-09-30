# android-f9-breakpoint-hit Specification

## Purpose

定义 UE Android F9 断点从 Neovim、DAP、LLDB 到真机 stop 的可验证端到端行为与
诊断证据。边界：管断点从设置到命中的完整闭环判据（真实 LLDB 状态、职责单一、
诊断可复现）；不管 attach 建连本身（那部分由 `android-dap-attach` 管）。

## Requirements

### Requirement: 修复方案必须以当前代码行为为依据，禁止无证据 workaround 入主路

系统 SHALL 在实现 Android F9 修复前建立当前代码行为图（keymap → `_persist_bp` →
DAP listener → `ue.dap.android` attach config → LLDB command → stop event），
每个修复想法 SHALL 指向具体代码位置和预期运行行为；代码行为与设计假设冲突时
MUST 先更新设计再实现。某方案无法证明真实 LLDB resolved 与 stop event 时，
MUST NOT 进入运行时主路，只能作为明确标记的诊断 probe 或被删除。

#### Scenario: 禁止无证据 workaround 进入主路

- **WHEN** 某方案无法证明真实 LLDB resolved 与 stop event
- **THEN** 该方案 MUST NOT 进入运行时主路
- **AND** 只能作为明确标记的诊断 probe 或被删除

### Requirement: Android 断点植入职责必须单一，不得靠 reattach 应用变更

系统 SHALL 让 attach-time preseed 与 active-session live breakpoint 各有唯一
运行时 owner；`lua/ue/dap.lua` MUST NOT 重复注入 Android attachCommands，也
MUST NOT 以 reattach 作为会话中断点变更的正常应用路径。断点命令 SHALL 位于
symbol target、platform connect、process attach、signal disposition、ASLR
rebase 之后。

#### Scenario: 会话中 F9 不静默重连

- **WHEN** 用户在已 attach 的 Android 会话中按 F9 新增或删除断点
- **THEN** active-session breakpoint owner SHALL 即时下发并验证真实 LLDB 状态
- **AND** 系统 MUST NOT 提示用户 reattach，也 MUST NOT 静默 detach/reattach

### Requirement: F9 断点必须端到端命中，成功判据以 LLDB 证据为准

系统 SHALL 让 UE Android F9 file:line 断点从编辑器设置到真机运行时命中形成可
验证闭环；attach 前断点由 preseed 处理，会话中变更由 live 通道处理，两条路径
都 MUST 以真实 LLDB 状态为准且不得要求 reattach。`verified=true` SHALL 对应
已经 preseed 或即时下发的 LLDB breakpoint，且最近一次 `breakpoint list` SHALL
显示匹配的 resolved location；不依赖只看 UI 状态或合成响应。

#### Scenario: attach 前断点命中

- **WHEN** 用户在 attach 前通过 F9 设置 UE C++ file:line 断点并触发 `<space>da`
- **THEN** attach 流程 SHALL 在 LLDB 中植入对应断点，`breakpoint list` SHALL
  显示 `resolved>0`
- **AND** 目标运行到该位置时 SHALL 产生 breakpoint stop 并定位到对应本地源码行

#### Scenario: pending 或未下发时返回可诊断信息，不建议 reattach 掩盖

- **WHEN** LLDB breakpoint pending、命令未发出、路径无法匹配或 adapter 风险
  路径被禁止
- **THEN** DAP/UI 反馈 SHALL 暴露原因（live/preseed 未下发、路径未匹配、符号
  未加载、ASLR 未校正、LLDB 命令失败之一）
- **AND** MUST NOT 建议用户通过 reattach 掩盖失败

### Requirement: source-file 与 address 断点必须证明语义等价

系统 SHALL 在 source-file 断点不稳定时允许使用 address 断点，但必须证明其与
用户 F9 的源码行语义等价。source-file 断点稳定（`breakpoint set -f -l` 不崩溃
且 resolved）时 SHALL 优先使用；崩溃/pending/无法可靠匹配时改用
`image lookup --file --line` 取得 PC 后 `breakpoint set --address`，并验证命中
stop frame 映射回同一源码行。

#### Scenario: address 断点作为正解

- **WHEN** source-file breakpoint 路径崩溃、pending 或无法可靠匹配
- **THEN** 系统 SHALL 通过 `image lookup --file <file> --line <line>` 或等价
  LLDB 查询取得目标 PC，并使用 `breakpoint set --address <pc>` 植入断点
- **AND** SHALL 验证命中 stop frame 映射回同一源码行

### Requirement: 断点诊断日志必须可复现，覆盖编辑器到真机四层

系统 SHALL 为 Android F9 问题提供可复现诊断输出，覆盖 nvim 断点表、attachCommands
或即时命令、DAP `setBreakpoints` 响应、LLDB `breakpoint list`、adapter exit
code、stop event 与 selected frame；日志 SHALL 使用 fresh pid/port，不复用旧
会话结论。验证失败时诊断输出 SHALL 能区分：未下发、未 resolved、resolved 但
未命中、已命中但 UI 未跳转，四类之一。

#### Scenario: 验证失败可定位层级

- **WHEN** F9 未命中
- **THEN** 诊断输出 SHALL 能区分失败发生在未下发、未 resolved、resolved 但未
  命中、已命中但 UI 未跳转这四类之一

## 选型与踩坑

- **踩坑**：曾存在两处导致 F9 必然不生效的设计性短路——`setBreakpoints` 被拦截
  为合成响应，以及 preseed 调用被注释未下发——这是"先保 attach 稳定"的取舍。
  处置：接通断点需要在 attach 稳定后分别落地 preseed（初始断点）与 live 通道
  （会话中变更），两者各自唯一 owner。
- **重要事项**：断点成功判据必须双重验证（DAP `verified` + lldb
  `breakpoint list` resolved>0），单独任一个都不足以证明真实接通。
