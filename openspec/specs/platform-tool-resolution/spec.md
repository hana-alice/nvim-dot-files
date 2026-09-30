# platform-tool-resolution Specification

## Purpose

统一宿主可执行工具（Python、Go 构建产物如 `csearch`/`cindex-uefilter`、clangd、lldb-dap、
lldb-server 等）的解析规则，使它们都走同一条解析链。明确环境变量、配置与驱动默认值之间的
优先级，把路径身份、可执行后缀、宿主路径格式这些细节收归宿主驱动所有权，使上层调用点不需要
为不同工具写平台分支或后缀拼接逻辑，也不会因为缺一个工具就悄悄换成另一种工具家族。

## Requirements

### Requirement: 工具解析必须遵守 env > config > driver 的优先级

系统 SHALL 以环境变量、配置值、宿主驱动默认值的顺序解析宿主工具；解析器 SHALL 选择按该顺序
遇到的第一个可用候选，并 SHALL 在诊断结果中保留被跳过的无效高优先级候选及其来源，MUST NOT
静默吞掉无效 override 的诊断证据。

#### Scenario: 环境变量失效时保留诊断后按序解析
- **WHEN** 某工具的环境变量显式指向一个不存在的工具
- **THEN** 解析 SHALL 记录该候选、来源与不可用原因，并继续按 config、driver 顺序选择第一个
  可用候选
- **AND** 返回结果 MUST NOT 隐藏被跳过的环境变量 override

### Requirement: 路径身份、后缀与宿主规范由驱动统一管理

工具解析 SHALL 以宿主驱动提供的路径语义为准（`host_path()`、`exe_suffix`、候选路径格式、
路径分隔规则）；调用方 MUST NOT 自行补 `.exe`/`.bat`/`.cmd`、路径分隔符或绝对路径拼接规则，
也 MUST NOT 通过文件后缀猜测工具身份。

#### Scenario: Windows LLVM 未加入 PATH 时仍被发现
- **WHEN** PATH 中没有 clangd，但 LLVM 存在于 Windows Program Files 目录下
- **THEN** Windows 驱动 SHALL 在其 PATH 候选之后提供该安装
- **AND** 显式 环境变量/配置 override SHALL 保留更高优先级

### Requirement: 调用方不得自行分支工具家族或猜测替代

Python、Go 构建产物、clangd、lldb-dap、lldb-server 等工具的候选列表、命名差异与可用性判断
SHALL 由平台工具解析层统一处理；调用方 MUST 只消费解析结果，MUST NOT 通过
`if windows then python.exe else python3` 这类分支自行拼装候选，也 MUST NOT 在发现某个工具
缺失后擅自换另一种工具家族来掩盖缺失。

#### Scenario: Go 构建产物缺失时显式失败
- **WHEN** 某宿主没有可用的 `csearch` 或 `cindex-uefilter` 构建产物
- **THEN** 解析 SHALL 直接报告不可用
- **AND** 调用方 MUST NOT 改用 Python、clangd 或其他家族来代替 Go

## 选型与踩坑

- **选型**：优先级固定为 env > config > driver，不做「更智能」的合并或打分，理由是可预测性
  优先于灵活性——调用方总能通过环境变量强制覆盖，而不必理解驱动内部候选逻辑。
- **踩坑**：早期实现在环境变量指向的工具不存在时会静默跳过并丢失该候选的诊断信息，导致
  用户看到「用了 driver 默认值」却不知道自己设置的环境变量被忽略；处置为强制保留跳过原因。
