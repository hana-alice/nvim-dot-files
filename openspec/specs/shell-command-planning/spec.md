# shell-command-planning Specification

## Purpose

把 shell 相关逻辑缩减为纯粹的命令计划：给定明确的 shell kind、shell executable、脚本和
参数，`lua/utils/platform/shell.lua` 只做 quote 与 argv 组装，不决定宿主平台、不挑选可执行
文件、不执行命令。目的是把 shell 语义从宿主探测与 target 逻辑中分离，使上层只关心「要跑
什么」，而「谁来选 shell」完全交给宿主驱动。

## Requirements

### Requirement: shell helper 只负责 quote 与 argv 计划

`shell.lua` SHALL 接收显式的 shell kind、shell executable、脚本与参数，返回可供上层消费的
argv/plan 结果；它 MUST NOT 执行命令、选择 shell 可执行文件，或在内部探测宿主 OS。任何
host-specific shell 选择 SHALL 来自宿主驱动，调用方 MUST NOT 通过 shell helper 自己猜测环境。

#### Scenario: 给定显式 shell executable 生成计划
- **WHEN** 宿主驱动传入 `posix` kind 与 `/bin/sh` executable
- **THEN** shell helper SHALL 生成对应的命令计划，MUST NOT 改写为其他 shell 可执行文件

### Requirement: 宿主驱动负责选择 shell kind 与 shell executable

宿主驱动 SHALL 决定当前宿主应使用的 shell kind 与对应 executable；调用方 MUST 通过
`platform.driver().shell_entry(kind)` 或等价宿主入口取得结果，MUST NOT 在共享代码里硬编码
`cmd.exe`、`powershell.exe`、`/bin/sh`、`/bin/bash` 等 shell 名称。不同宿主的 shell 决策 SHALL
保持在 driver 边界内，且与 target 无关（target 改变不应触发重选宿主 shell）。

#### Scenario: 同一调用点在不同宿主上使用不同 shell
- **WHEN** 共享调用点需要在 Windows 与 macOS 上生成 shell 计划
- **THEN** 它 SHALL 只依赖宿主驱动返回的 shell entry，MUST NOT 写平台名称分支来选 shell

### Requirement: 非法 shell 请求 fail closed

当 shell kind 不受支持、shell executable 为空、或驱动无法提供有效 shell entry 时，系统 SHALL
fail closed 并返回明确错误；它 MUST NOT 自动回退到另一种 shell，也 MUST NOT 通过猜测执行文件
名来继续执行。

#### Scenario: shell executable 为空时拒绝计划
- **WHEN** 驱动提供的 shell executable 为空字符串或不可用
- **THEN** 计划生成 SHALL 失败，系统 MUST NOT 继续构造可执行命令

## 选型与踩坑

- **选型**：shell helper 与宿主探测彻底分离——helper 只吃显式参数、只出 argv，宿主驱动
  独占「选哪个 shell」的决策权。理由是避免 shell 语义（quote 规则）与宿主语义（哪个 shell
  存在）耦合在同一层，导致新增宿主时要同时改两处。
- **重要事项**：shell kind 与 target 无关这一条是明确设计边界——曾经的隐患是「target 变了
  就该换 shell」的直觉，但实际上 shell 只取决于宿主 OS，与正在构建/调试哪个 target 无关。
