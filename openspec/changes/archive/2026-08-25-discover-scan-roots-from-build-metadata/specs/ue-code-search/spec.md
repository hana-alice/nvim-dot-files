## ADDED Requirements

### Requirement: 索引输入集 SHALL 覆盖全部模块声明（范围完整性）

csearch / 文件 picker 的索引输入集（`workspace_all.files`）SHALL 覆盖项目内**全部模块声明**
（`*.Build.cs` / `*.uplugin` / `*.uproject`）所在目录下的源文件。系统 MUST NOT 因扫描根推导
遗漏某个模块目录而使其源文件永久不可搜——这类遗漏无法由重建修复（重建仍按同一错误范围枚举），
与「索引过期」是不同的故障类别。

理由：现有 freshness 契约用 `workspace_all.files` 的内容指纹回答「被索引的集合**变化**了吗」，
它**无法**回答「这个集合一开始就**漏**了吗」——集合漏了但稳定不变时指纹恒等，freshness 永远判
fresh，用户看到的是「搜过了，没有」而非「没搜到那里」。因此范围完整性必须是独立于 freshness 的
契约。扫描根的推导规则见 `project-scan-root-discovery`。

#### Scenario: 新增模块目录后可被搜到

- **WHEN** 项目内新增一个含 `*.Build.cs` 的模块目录，随后运行 `:UEPrepare`
- **THEN** 该模块的源文件 SHALL 出现在 `workspace_all.files` 中
- **AND** `<leader>/` SHALL 能搜到其中的符号与文本
- **AND** 用户 SHALL NOT 需要手写 `.ueprepare-scan-paths` 才能让它可见

#### Scenario: 范围遗漏不得被 freshness 判为 fresh 而掩盖

- **WHEN** 某模块目录因扫描根未覆盖而从未进入 `workspace_all.files`，且该集合此后保持不变
- **THEN** 仅凭 freshness 指纹相等 SHALL NOT 被视为「索引完整」
- **AND** 范围完整性 SHALL 由扫描根推导契约独立保证（见 `project-scan-root-discovery`）

#### Scenario: 完整性与新鲜度同时成立才算索引可信

- **WHEN** 判断当前索引是否可信
- **THEN** 系统 SHALL 同时满足：① 范围完整（覆盖全部模块声明）与 ② 内容新鲜（指纹相等）
- **AND** 二者任一不成立时 MUST NOT 宣称索引可信
