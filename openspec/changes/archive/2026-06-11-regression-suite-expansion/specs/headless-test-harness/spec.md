## ADDED Requirements

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
