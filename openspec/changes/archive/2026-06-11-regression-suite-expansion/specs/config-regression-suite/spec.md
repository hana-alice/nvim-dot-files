## ADDED Requirements

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

#### Scenario: utils.ue_goto 排序与配对行为

- **WHEN** 用例调用 `utils.ue_goto.ranking.rerank_locations` 对含 `.h` 与 `.cpp` 的 location 列表排序
- **THEN** `.cpp` 排在 `.h` 之前
- **AND** `utils.ue_goto.pair_picker.pick_safe_winner` 对一个 header+cpp 配对返回该 cpp，对两个无关文件返回 MISS
- **AND** `utils.ue_goto.location.dedup_locations` 能去除重复 location

## MODIFIED Requirements

### Requirement: 工具函数加载覆盖

回归套件 SHALL 验证 `utils` 下关键工具模块可被 require 且核心导出存在，并在可能时对纯函数追加行为断言（见「utils 纯函数行为覆盖」）。

#### Scenario: 工具模块可加载

- **WHEN** 用例 require `utils.code_search`、`utils.ue_goto`（其子模块）、`utils.log`、`utils.ue_paths`
- **THEN** 各模块成功返回 table
- **AND** 模块内被回归依赖的关键函数为 function

#### Scenario: 纯函数模块同时校验行为

- **WHEN** 被加载的模块属于纯函数类（`ue.core.fs`/`ue.core.proc`/`utils.ue_paths`/`utils.ue_goto.ranking`/`pair_picker`/`location`）
- **THEN** 除加载断言外，还按既定输入断言其输出符合契约
