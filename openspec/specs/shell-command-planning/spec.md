# shell-command-planning Specification

## Purpose
本 capability 负责把 shell 相关逻辑缩减为纯粹的命令计划：给定明确的 shell kind、shell executable、脚本和参数，它只做 quote 与 argv 组装，不决定宿主平台，不挑选可执行文件，也不执行命令。这样可以把 shell 语义从宿主探测与 target 逻辑中分离出来，让上层只关心“要跑什么”与“谁来选 shell”，而不是把不同平台的 shell 细节散落到调用点里。

## Requirements

### Requirement: shell helper 只负责 quote 与 argv 计划

`shell.lua` SHALL 接收显式的 shell kind、shell executable、脚本与参数，并返回可供上层消费的 argv/plan 结果；它 MUST NOT 执行命令、选择 shell 可执行文件、或者在内部探测宿主 OS。任何 host-specific shell 选择 SHALL 来自宿主驱动，上层调用方 MUST NOT 通过 shell helper 自己猜测环境。

#### Scenario: 给定显式 shell executable 生成计划

- **WHEN** 宿主驱动传入 `posix` kind 与 `/bin/sh` executable
- **THEN** shell helper SHALL 生成对应的命令计划
- **AND** 它 MUST NOT 改写为其他 shell 可执行文件

#### Scenario: helper 不执行命令

- **WHEN** 调用方请求 shell 计划
- **THEN** helper SHALL 只返回计划数据
- **AND** MUST NOT 直接启动进程或触发 UI

### Requirement: 宿主驱动负责选择 shell kind 与 shell executable

宿主驱动 SHALL 决定当前宿主应使用的 shell kind 与对应 executable；调用方 MUST 通过 `platform.driver().shell_entry(kind)` 或等价宿主入口取得结果，而 MUST NOT 在共享代码里硬编码 `cmd.exe`、`powershell.exe`、`/bin/sh`、`/bin/bash` 或其他 shell 名称。不同宿主的 shell 决策 SHALL 保持在 driver 边界内。

#### Scenario: 同一调用点在不同宿主上使用不同 shell

- **WHEN** 共享调用点需要在 Windows 与 macOS 上生成 shell 计划
- **THEN** 它 SHALL 只依赖宿主驱动返回的 shell entry
- **AND** 它 MUST NOT 写平台名称分支来选 shell

#### Scenario: shell 选择与 target 无关

- **WHEN** target 改变但宿主不变
- **THEN** shell kind 与 executable SHALL 保持由宿主驱动决定
- **AND** 调用方 MUST NOT 因 target 变化而重选宿主 shell

### Requirement: 非法 shell 请求 fail closed

当 shell kind 不受支持、shell executable 为空、或驱动无法提供有效 shell entry 时，系统 SHALL fail closed 并返回明确错误；它 MUST NOT 自动回退到另一种 shell，也 MUST NOT 通过猜测执行文件名来继续执行。

#### Scenario: 请求未知 shell kind

- **WHEN** 调用方请求一个驱动不支持的 shell kind
- **THEN** helper SHALL 返回错误
- **AND** MUST NOT 默默切换到默认 shell

#### Scenario: shell executable 为空时拒绝计划

- **WHEN** 驱动提供的 shell executable 为空字符串或不可用
- **THEN** 计划生成 SHALL 失败
- **AND** 系统 MUST NOT 继续构造可执行命令
