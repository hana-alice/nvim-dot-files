# platform-tool-resolution Specification

## Purpose

本 capability 负责把宿主可执行工具的解析规则统一起来，确保 Python、Go 构建产物、clangd、lldb-dap、lldb-server 以及类似的宿主工具都通过同一条解析链得到结果。它要明确环境变量、配置与驱动默认值之间的优先级，并把路径身份、可执行后缀、宿主路径格式这些细节放回宿主驱动所有权之下。这样，上层调用点就不需要再分别为不同工具写平台分支或后缀拼接逻辑，也不会因为缺一个工具就悄悄换成另一种工具家族。

## ADDED Requirements

### Requirement: 工具解析必须遵守 env > config > driver 的优先级

系统 SHALL 以环境变量、配置值、宿主驱动默认值的顺序解析宿主工具；环境变量 MUST 最先检查，配置 MUST 次之，宿主驱动默认值 MUST 最后。解析器 SHALL 选择按该顺序遇到的第一个可用候选，并 SHALL 在诊断结果中保留被跳过的无效高优先级候选及其来源；它 MUST NOT 重排来源或静默吞掉无效 override 的诊断证据。

#### Scenario: 环境变量覆盖配置与驱动默认值

- **WHEN** 某工具同时在环境变量、配置和驱动默认值中都存在不同值
- **THEN** 系统 SHALL 采用环境变量指定的值
- **AND** MUST NOT 退回配置或驱动默认值

#### Scenario: 环境变量失效时保留诊断后按序解析

- **WHEN** 环境变量显式指向一个不存在的工具
- **THEN** 解析 SHALL 记录该环境变量候选、来源与不可用原因
- **AND** SHALL 继续按 config、driver 的既定顺序选择第一个可用候选
- **AND** 返回结果 MUST NOT 隐藏被跳过的环境变量 override

### Requirement: 路径身份、后缀与宿主规范由驱动统一管理

工具解析 SHALL 以宿主驱动提供的路径语义为准，包括 `host_path()`、`exe_suffix`、候选路径格式与宿主路径分隔规则。调用方 MUST NOT 自行补 `.exe`、`.bat`、`.cmd`、路径分隔符或绝对路径拼接规则，也 MUST NOT 通过文件后缀猜测工具身份。

#### Scenario: Windows 工具候选包含宿主后缀

- **WHEN** 驱动在 Windows 上返回一个工具候选
- **THEN** 该候选 SHALL 反映 Windows 的可执行后缀与路径语义
- **AND** 调用方 MUST NOT 再手工追加后缀

#### Scenario: Linux 工具候选保持无后缀语义

- **WHEN** 驱动在 Linux 上返回同一逻辑工具
- **THEN** 候选 SHALL 保持 Linux 的宿主路径表示
- **AND** 调用方 MUST NOT 因平台名称而自行改写路径

### Requirement: 调用方不得自行分支 Python、Go 构建产物或其他工具家族

Python、Go 构建产物（例如 `csearch`、`cindex-uefilter`）、clangd、lldb-dap、lldb-server 以及类似工具的候选列表、命名差异与可用性判断 SHALL 由平台工具解析层统一处理；调用方 MUST 只消费解析结果。调用方 MUST NOT 通过 `if windows then python.exe else python3` 这类分支自行拼装候选，也 MUST NOT 在发现某个工具缺失后擅自换另一种工具家族来掩盖缺失。

#### Scenario: Python 解析统一返回一个最终候选

- **WHEN** 当前宿主只提供 `python3` 而不提供 `python`
- **THEN** 解析层 SHALL 返回可用的 Python 候选或明确不可用结果
- **AND** 调用方 MUST NOT 自行写平台分支去重试另一个名字

#### Scenario: Go 构建产物缺失时显式失败

- **WHEN** 某宿主没有可用的 `csearch` 或 `cindex-uefilter` 构建产物
- **THEN** 解析 SHALL 直接报告不可用
- **AND** 调用方 MUST NOT 改用 Python、clangd 或其他家族来代替 Go
