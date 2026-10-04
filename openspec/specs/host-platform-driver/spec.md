# host-platform-driver Specification

## Purpose

把“当前宿主是什么平台”收口到单一权威来源，并把宿主专属能力以可枚举、可验证、可失败关闭的
方式暴露给上层。调用方只消费 host driver 的稳定接口，不重新探测操作系统、猜测可执行文件，或把
平台差异散落到通用模块中，从而在 Windows/macOS/Linux/stub 之间保持一致边界，防止 OS 分支再次
写回调用点。

## Requirements

### Requirement: 直接宿主平台检测只有一个归属

SHALL：直接 OS detection 只发生在宿主平台驱动注册与加载路径中；`platform.id`、
`platform.is_windows`/`is_mac`/`is_linux` 以及 `platform.driver()` 是调用方读取宿主身份的唯一
入口。兼容布尔值 SHALL 保持只读且仅服务既有 API 兼容，MUST NOT 被当作新的扩展点；调用方 MUST NOT
再调用独立 OS probe、按路径分隔符推断平台，或在通用代码中复制平台判定逻辑。

#### Scenario: 调用方需要宿主相关行为

- **WHEN** 某个新增或迁移后的调用点需要路径、工具、shell 或进程行为
- **THEN** 它 SHALL 调用对应的 host driver capability
- **AND** MUST NOT 用 `platform.is_*` 或 `platform.id` 分支重新实现该行为

### Requirement: 基础能力固定，扩展能力显式且可缺失

SHALL：每个宿主驱动提供稳定的基础能力集合（`shell`、`shell_entry`、`path_sep`、`list_sep`、
`exe_suffix`、`open_path`、`reveal_file`、`default_clangd_candidates`、`python_candidates`、
`default_lldb_dap_paths`、`default_lldb_server_paths`、`cmd_quote`、`host_path`、
`environment_key`、`directory_symlink_options`、`default_target`、`launch_process_plan`、
`follow_file_plan`、`ue_build_entry`、`ue_uat_entry`）。宿主专属能力（如 macOS 的
`xcrun_entry`/`security_entry`/`plutil_entry`，Windows 的 content-event watcher、grouped
frozen-input watcher）MAY 以可选方法存在；能力不存在时系统 SHALL fail closed，MUST NOT 伪造一个
看似可用但语义不同的替代实现，也 MUST NOT 自动切换到另一宿主工具或猜测等价命令。

#### Scenario: macOS 暴露宿主专属能力，Linux 不暴露

- **WHEN** 调用方查询 `xcrun_entry`、`security_entry` 或 `plutil_entry`
- **THEN** macOS 驱动 SHALL 提供这些能力
- **AND** Linux 与 Windows 驱动 MUST NOT 伪装同名能力来冒充可用

#### Scenario: 缺失能力直接失败，不静默降级

- **WHEN** 调用方需要一个当前宿主没有声明的可选能力
- **THEN** 系统 SHALL 返回明确的不可用结果或错误，MUST NOT 自动切换到另一宿主工具

### Requirement: 宿主驱动拥有宿主路径与可执行文件语义

SHALL：`path_sep`、`list_sep`、`exe_suffix` 以及 `host_path()` 由宿主驱动定义为宿主语义的权威
来源；任何需要宿主可执行文件或路径表示的上层逻辑 MUST 使用这些结果，MUST NOT 自行拼接后缀、
替换分隔符，或按平台名称硬编码路径规则。

#### Scenario: Windows 与 Linux 的路径语义不同但调用方不分支

- **WHEN** 上层代码拿到 Windows 驱动的 `exe_suffix` 与 `host_path()` 结果
- **THEN** 它 SHALL 使用这些值构造宿主路径，MUST NOT 自己写 `if windows then add .exe`

## 选型与踩坑

- **选型（2026-10-03 IDE）**：Editor 测试计划是宿主可选能力；当前 Windows 从所选引擎的
  Build.version 和实际 Editor 二进制解析，原生 argv 保持单个 ExecCmds 参数。其他宿主缺少能力
  时直接说明不可用，不猜测其他引擎、安装工具或加入假实现。用户显式启动的测试 worker
  复用前台 ownership 和任务取消，不在打开菜单或状态栏时启动。

- **选型**：宿主专属能力（`xcrun_entry`/`security_entry`/`plutil_entry`、Windows native
  content-event watcher、grouped frozen-input watcher）以可选方法暴露而非全平台统一接口——因为
  这些能力本身在其他宿主上不存在等价物，强行统一接口会诱使调用方伪造假实现
  （出处：`lua/utils/platform/AGENTS.md`）。
- **选型**：Windows 环境变量名比较用大小写不敏感，POSIX 保留大小写敏感；目录 symlink 选项只在
  Windows 驱动选择 junction 行为，其他宿主保留普通目录链接选项——这是宿主原生语义差异，不是可
  统一的通用逻辑。
- **重要事项**：本 spec 是 `openspec/changes/archive/2026-08-24-establish-ue-platform-workflow-boundaries`
  拆分出的独立 canonical capability，此前平台宪法曾被埋在 Apple semantic spec
  （`macos-ios-cdb-semantic-prepare`）里代管，导致测试按源码位置锁定，容易随文件搬移失效；现在
  验收必须基于 driver capability contract，不得基于源码位置。
