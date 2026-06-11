# headless-test-harness Specification

## Purpose

提供在 `nvim --headless` 无 UI 环境下运行的轻量测试框架：统一运行入口、最小断言与分组 API、按约定自动发现用例，以及 runtimepath 自举，使配置模块可在不加载完整 `init.lua` 的情况下被 `require` 与测试。

## Requirements

### Requirement: 统一 headless 运行入口

测试套件 SHALL 提供单一运行入口，使用 `nvim --headless` 在无 UI 环境下顺序执行全部注册的测试用例，并在结束时输出 PASS/FAIL 汇总。

#### Scenario: 一条命令跑全量回归

- **WHEN** 开发者执行统一运行入口（例如 `nvim -l tests/run.lua`）
- **THEN** 入口加载并执行 `tests/` 下所有注册测试用例
- **AND** 终端输出每个用例的 PASS/FAIL 状态与失败原因
- **AND** 末尾打印 `=== N/M passed, K failed ===` 形式的汇总行

#### Scenario: 全部通过时返回零退出码

- **WHEN** 所有测试用例断言均成功
- **THEN** 进程以退出码 `0` 结束

#### Scenario: 存在失败时返回非零退出码

- **WHEN** 任意测试用例断言失败或抛出错误
- **THEN** 进程以非零退出码（`1`）结束
- **AND** 失败用例的名称与错误信息先于汇总行打印

### Requirement: 断言与分组 API

测试框架 SHALL 提供最小可用的断言与分组能力，使每个用例可以独立声明、独立失败而不影响其他用例执行。

#### Scenario: 提供基础断言

- **WHEN** 用例调用框架断言（如 `assert_eq`、`assert_true`、`assert_type`、`assert_error`）
- **THEN** 断言失败时抛出包含期望值与实际值的可读错误
- **AND** 断言成功时不产生副作用

#### Scenario: describe/it 风格分组

- **WHEN** 用例使用 `describe(name, fn)` 与 `it(name, fn)` 组织
- **THEN** 框架以 `describe > it` 形式记录用例归属
- **AND** 汇总报告按分组聚合显示通过/失败计数

#### Scenario: 单个用例失败被隔离

- **WHEN** 某个 `it` 块抛出错误
- **THEN** 框架捕获该错误并标记该用例为 FAIL
- **AND** 继续执行后续用例，不中断整个运行

### Requirement: 测试自动发现

测试框架 SHALL 支持按约定自动发现并加载测试文件，新增用例无需修改运行入口。

#### Scenario: 按文件名约定发现用例

- **WHEN** 在测试目录下新增符合命名约定（如 `*_spec.lua`）的文件
- **THEN** 统一运行入口在下次执行时自动包含该文件
- **AND** 无需手动在入口脚本登记该文件

### Requirement: runtimepath 自举

测试框架 SHALL 在 headless 环境下自行将配置根目录加入 `runtimepath`/`package.path`，使 `require("ue")` 等模块解析不依赖完整 `init.lua` 加载。

#### Scenario: 无完整 init 也能 require 模块

- **WHEN** 测试入口以 `nvim -l` 启动且未加载完整插件管理器
- **THEN** 框架将配置根目录前置到 `runtimepath`
- **AND** 用例内 `require("ue")`、`require("utils.platform")` 等均可解析成功

### Requirement: 表/字符串包含断言

测试框架 SHALL 提供 `assert_contains` 断言，支持判断字符串是否含子串、列表是否含元素，失败时打印容器与期望项。

#### Scenario: 字符串包含

- **WHEN** 用例调用 `assert_contains("hello world", "world")`
- **THEN** 断言通过
- **AND** `assert_contains("hello", "xyz")` 失败并打印实际字符串与期望子串

#### Scenario: 列表包含

- **WHEN** 用例调用 `assert_contains({ "a", "b" }, "b")`
- **THEN** 断言通过
- **AND** 列表不含目标元素时失败并打印该元素

### Requirement: keymap 查询辅助

测试框架 SHALL 提供按 `(mode, lhs)` 查询当前已注册映射的辅助函数，便于 keymap 用例断言绑定存在与目标。

#### Scenario: 查询已存在映射

- **WHEN** 某 keymap 已注册，用例调用查询辅助 `get_keymap(mode, lhs)`
- **THEN** 返回该映射的信息（含 rhs 或 callback）
- **AND** lhs 的 `<leader>` 与空格前缀差异被规范化处理，使常见写法均可命中

#### Scenario: 查询不存在映射

- **WHEN** 用例查询一个未注册的 `(mode, lhs)`
- **THEN** 返回 nil
- **AND** 不抛出错误
