## ADDED Requirements

### Requirement: 配置加载冒烟覆盖

回归套件 SHALL 包含冒烟测试，验证 headless 启动时关键模块可被加载且不抛错。

#### Scenario: 核心模块可 require

- **WHEN** 冒烟用例运行
- **THEN** `require("ue")`、`require("ue.config")`、`require("utils.platform")`、`require("utils.log")` 均成功返回 table
- **AND** 任一模块加载报错时该用例标记为 FAIL 并打印模块名与错误

#### Scenario: ue.setup 注册命令不报错

- **WHEN** 冒烟用例调用 `require("ue").setup()`
- **THEN** 调用无异常返回
- **AND** `UEDAP*` 等关键用户命令通过 `vim.fn.exists(":Cmd")` 验证为已注册

### Requirement: 平台驱动契约覆盖

回归套件 SHALL 验证 `utils.platform` 的四个驱动（windows/macos/linux/stub）实现一致的接口形状。

#### Scenario: 每个驱动实现完整接口

- **WHEN** 平台契约用例遍历四个驱动模块
- **THEN** 每个驱动的 `id` 与模块名一致
- **AND** `shell`、`open_path`、`reveal_file`、`cmd_quote`、`default_clangd_candidates`、`default_lldb_dap_paths`、`default_lldb_server_paths` 均为 function

#### Scenario: 向后兼容布尔标志存在

- **WHEN** 用例读取 `utils.platform`
- **THEN** `is_windows`、`is_mac`、`is_linux` 均为 boolean
- **AND** `platform.id` 为非空 string

### Requirement: ue 模块公共 API 冻结覆盖

回归套件 SHALL 验证 `ue` 模块及子模块的公共 API（表与函数）持续存在，防止重构误删。

#### Scenario: 公共表与函数存在

- **WHEN** API 冻结用例运行
- **THEN** `ue` 暴露的公共表（如 `FT_CPP`、`GLOBS_ALL`）为非空 table
- **AND** 公共函数（如 `clangd_cmd`、`launch_app`、`index_now`、`prepare_headless`）均为 function

#### Scenario: ue.config schema 默认值正确

- **WHEN** 用例读取 `ue.config` 默认值
- **THEN** `index.idle_cold_ms`、`context.ttl_s`、`cdb.steps`、`dap` 等关键键返回预期默认值
- **AND** 用户 `setup()` 覆盖后再 `reset_for_test()` 能恢复默认值

#### Scenario: ue.cdb 子模块行为稳定

- **WHEN** 用例调用 `ue.cdb.json`、`ue.cdb.paths`、`ue.cdb.shaders`
- **THEN** `template_entry`、`program`、`targets`、`augment`、`make_entry` 返回符合既有契约的结构

### Requirement: DAP 平台注册覆盖

回归套件 SHALL 验证 DAP 平台注册表与各平台模块的 `attach`/`launch` 导出。

#### Scenario: 平台注册与查找

- **WHEN** 用例对 `ue.dap.platforms` 注册测试处理器并查找
- **THEN** `register_attach` 后 `attach_handler` 返回可调用 function
- **AND** 未注册的 `launch_handler` 返回 nil
- **AND** `_reset_for_test` 可清空注册状态

#### Scenario: 各平台模块导出 attach/launch

- **WHEN** 用例遍历 `win64`、`mac`、`linux`、`ios`、`android`
- **THEN** 每个平台模块的 `attach` 与 `launch` 均为 function
- **AND** `ue.setup()` 后这些平台在 `ue.dap.platforms` 中均已注册

### Requirement: 工具函数加载覆盖

回归套件 SHALL 验证 `utils` 下关键工具模块可被 require 且核心导出存在。

#### Scenario: 工具模块可加载

- **WHEN** 用例 require `utils.code_search`、`utils.ue_goto`、`utils.log`、`utils.ue_paths`
- **THEN** 各模块成功返回 table
- **AND** 模块内被回归依赖的关键函数为 function

### Requirement: 套件失败可定位

回归套件 SHALL 在任意用例失败时输出足够定位的上下文，便于「开发完跑一遍」时快速排错。

#### Scenario: 失败输出包含归属与原因

- **WHEN** 任意领域用例失败
- **THEN** 输出包含 `describe > it` 归属、断言期望与实际值或错误堆栈摘要
- **AND** 整体退出码非零
