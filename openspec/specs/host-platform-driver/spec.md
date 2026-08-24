# host-platform-driver Specification

## Purpose
本 capability 负责把“当前宿主到底是什么平台”这件事收口到单一权威来源，并把宿主专属能力以可枚举、可验证、可失败关闭的方式暴露给上层。它要保证调用方只消费 host driver 的稳定接口，而不是重新探测操作系统、猜测可执行文件、或者把平台差异散落到各个通用模块中。这样才能把 Windows、macOS、Linux 以及 stub 行为保持一致的边界感，并防止后续改动再次把 OS 分支写回调用点。

## Requirements

### Requirement: 直接宿主平台检测只有一个归属

系统 SHALL 只在宿主平台驱动注册与加载路径中执行直接 OS detection；`platform.id`、`platform.is_windows`、`platform.is_mac`、`platform.is_linux` 以及 `platform.driver()` MUST 成为调用方读取宿主身份的唯一入口。兼容布尔值 SHALL 保持只读且仅服务既有 API 兼容；新增或迁移后的行为分支 MUST 消费 driver capability，而 MUST NOT 把这些布尔值当作新的扩展点。调用方 MUST NOT 再次调用独立的 OS probe、根据路径分隔符推断平台、或者在通用代码中复制平台判定逻辑。

#### Scenario: 调用方只从单一入口读取宿主身份

- **WHEN** 某个通用模块需要记录或展示宿主平台身份
- **THEN** 它 SHALL 读取 `platform.id` 或 `platform.driver()` 的结果
- **AND** 它 MUST NOT 再额外执行新的平台探测

#### Scenario: 调用方需要宿主相关行为

- **WHEN** 某个新增或迁移后的调用点需要路径、工具、shell 或进程行为
- **THEN** 它 SHALL 调用对应的 host driver capability
- **AND** 它 MUST NOT 用 `platform.is_*` 或 `platform.id` 分支重新实现该行为

#### Scenario: 测试替换驱动后仍走同一入口

- **WHEN** 测试环境替换宿主驱动实现
- **THEN** 后续调用 SHALL 继续通过 `platform.driver()` 取得替换后的驱动
- **AND** 调用方 MUST NOT 通过自身分支重新恢复旧平台判断

### Requirement: 基础能力固定，扩展能力显式且可缺失

每个宿主驱动 SHALL 提供稳定的基础能力集合：`shell`、`shell_entry`、`path_sep`、`list_sep`、`exe_suffix`、`open_path`、`reveal_file`、`default_clangd_candidates`、`python_candidates`、`default_lldb_dap_paths`、`default_lldb_server_paths`、`cmd_quote`、`host_path`、`default_target`、`launch_process_plan`、`follow_file_plan`、`ue_build_entry` 与 `ue_uat_entry`。宿主专属能力 MAY 以可选方法形式存在；当能力不存在时，系统 SHALL fail closed，并 MUST NOT 伪造一个看似可用但语义不同的替代实现。

#### Scenario: macOS 暴露宿主专属能力，Linux 不暴露

- **WHEN** 调用方查询 `xcrun_entry`、`security_entry` 或 `plutil_entry`
- **THEN** macOS 驱动 SHALL 提供这些能力
- **AND** Linux 与 Windows 驱动 MUST NOT 伪装同名能力来冒充可用

#### Scenario: 缺失能力直接失败，不静默降级

- **WHEN** 调用方需要一个当前宿主没有声明的可选能力
- **THEN** 系统 SHALL 返回明确的不可用结果或错误
- **AND** MUST NOT 自动切换到另一宿主工具或猜测等价命令

### Requirement: 宿主驱动拥有宿主路径与可执行文件语义

`path_sep`、`list_sep`、`exe_suffix` 以及 `host_path()` SHALL 由宿主驱动定义为宿主语义的权威来源。任何需要宿主可执行文件或宿主路径表示的上层逻辑 MUST 使用这些结果，而 MUST NOT 自行拼接后缀、替换分隔符、或按平台名称硬编码路径规则。

#### Scenario: Windows 与 Linux 的路径语义不同但调用方不分支

- **WHEN** 上层代码拿到 Windows 驱动的 `exe_suffix` 与 `host_path()` 结果
- **THEN** 它 SHALL 使用这些值构造宿主路径
- **AND** 它 MUST NOT 自己写 `if windows then add .exe`

#### Scenario: 宿主进程计划已包含正确的宿主可执行文件

- **WHEN** 调用方请求 `launch_process_plan()` 或 `ue_build_entry()`
- **THEN** 驱动 SHALL 返回宿主可执行文件与宿主路径形式
- **AND** 调用方 MUST NOT 再根据平台名称重写该可执行文件
