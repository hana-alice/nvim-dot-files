## MODIFIED Requirements

### Requirement: 工具函数加载覆盖

回归套件 SHALL 验证 `utils` 下关键工具模块可被 require 且核心导出存在，并在可能时对纯函数追加行为断言（见「utils 纯函数行为覆盖」）。

#### Scenario: 工具模块可加载

- **WHEN** 用例 require `utils.code_search`、`utils.ue_goto`（其子模块）、`utils.log`、`utils.ue_paths`
- **THEN** 各模块成功返回 table
- **AND** C++ 语义导航的 `semantic_context`、`semantic_protocol`、`semantic_client` 与 `semantic_sidecar` 关键导出为 function

#### Scenario: 纯函数模块同时校验行为

- **WHEN** 被加载的模块属于纯函数类（`ue.core.fs`/`ue.core.proc`/`utils.ue_paths`/`utils.ue_goto.location`/`semantic_context`/`semantic_protocol`）
- **THEN** 除加载断言外，还按既定输入断言其输出符合契约

### Requirement: utils 纯函数行为覆盖

回归套件 SHALL 对 `utils` 与 `ue.core` 下的纯函数进行输入→输出断言（而不仅是「模块能加载」），守护其行为契约。

#### Scenario: ue.core.fs 路径函数行为

- **WHEN** 用例调用 `ue.core.fs`
- **THEN** `norm("a\\b\\")` == `"a/b"`、`join("a","b")` == `"a/b"`
- **AND** `is_absolute_path("/a")` 与 `is_absolute_path("C:/a")` 均为 true、`is_absolute_path("a/b")` 为 false
- **AND** `relative_to("/a", "/a/b")` == `"b"`、`common_ancestor({"/a/b","/a/c"})` == `"/a"`

#### Scenario: ue.core.proc.first_executable 行为

- **WHEN** 用例调用 `ue.core.proc.first_executable({})`
- **THEN** 返回 nil
- **AND** 传入全不可执行的候选列表时返回 nil

#### Scenario: utils.ue_paths 过滤行为

- **WHEN** 用例调用 `utils.ue_paths`
- **THEN** `is_blocked` 对含 `/intermediate/`、`/binaries/`、`/.git/` 的路径返回 true，对普通源码路径返回 false
- **AND** `is_searchable("foo.cpp")` 为 true、`is_searchable("foo.txt")` 为 false
- **AND** `filter({...})` 返回的新列表只保留可搜索路径且保持顺序

#### Scenario: utils.ue_goto semantic context 与 location 行为

- **WHEN** 用例解析 compilation database、compiler-emitted dependency evidence 与多个 proven context
- **THEN** context fingerprint 绑定 active build、origin TU、exact argv/cwd、toolchain 与 evidence
- **AND** 零/一/多个 proven context 分别产生 `unavailable` / `resolved` / `ambiguous-context`，不得按 basename、目录距离或最近使用猜选
- **AND** `utils.ue_goto.location.dedup_locations` 能去除重复 location
