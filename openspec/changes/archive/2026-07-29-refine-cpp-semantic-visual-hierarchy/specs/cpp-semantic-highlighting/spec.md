## RENAMED Requirements

- FROM: `### Requirement: C/C++ 核心语义角色必须可辨`
- TO: `### Requirement: C/C++ 核心语义角色必须形成克制的视觉层级`

## MODIFIED Requirements

### Requirement: C/C++ 核心语义角色必须形成克制的视觉层级

系统 SHALL 在六个公开主题中为 C/C++ 提供基于成熟 IDE 配色分层的稳定角色族。type/class/struct 与 field/property 的 foreground MUST 不同；field/property 与 parameter/ordinary variable 的 foreground MUST 不同；function/method 与 ordinary variable 的 foreground MUST 不同；enum member 与 type 的 foreground MUST 不同；macro 与 namespace/type 的 foreground MUST 不同。系统 MAY 让 namespace 与 type、enum member 与 field、parameter 与 ordinary variable 共享 foreground，以避免无语义价值的八色“彩虹化”。普通 local 与 parameter SHALL 保持低视觉权重。

基础 namespace、type、field、parameter、variable、function、enum member 与 macro role MUST NOT 被全局强制 bold、italic 或 strikethrough。系统 MUST 中和 clangd declaration/definition、deduced、readonly/static/abstract/virtual、scope 与其他常见 modifier 的 foreground 和粗斜体，避免高优先级 extmark 重新提高常规正文权重；deprecated SHALL 仅通过 strikethrough 表示，且 MUST NOT 改写角色 foreground。

#### Scenario: 查看结构体及其字段

- **WHEN** 用户在任一公开主题下查看包含 struct/class、field/property、parameter 与 local variable 的 C/C++ 代码
- **THEN** type 与 field 可区分，field 与 local family 可区分，且基础角色不会因大面积粗斜体抢占代码结构

#### Scenario: 查看枚举、宏与命名空间

- **WHEN** 用户查看 function/method、enum member、macro 和 namespace
- **THEN** callable 与 ordinary variable 可区分、enum member 不使用 type 色、macro 不使用 namespace/type 色

#### Scenario: 查看声明与状态

- **WHEN** clangd 为角色附加 declaration/definition、readonly/static/abstract/virtual、scope 或 deprecated modifier
- **THEN** 常见 modifier 不改变角色 foreground 或基础字形，deprecated 仅叠加 strikethrough

### Requirement: 语义颜色必须跨解析 surface 一致

系统 SHALL 对同一 C/C++ 角色统一设置 Treesitter capture、clangd LSP semantic token，并在 LSP CompletionItemKind 有对应项时统一 Blink/nvim-cmp completion kind。clangd token 到达前后，同一 token 的语义 foreground 与基础字形 MUST NOT 因 Treesitter/LSP source 切换而改变；completion 中的 Struct/Class/Field/Property/Function/Method/EnumMember/Constant/Module/Variable SHALL 与编辑区对应角色使用同一 foreground。LSP 标准没有 Parameter 与 Macro completion kind，系统 MUST NOT 伪造这两个 kind。

#### Scenario: clangd semantic token 到达

- **WHEN** C/C++ buffer 先由 Treesitter 着色，随后 clangd 发布 semantic tokens
- **THEN** type、field、parameter、function 等角色保持同一 foreground 和克制的基础字形，仅允许 modifier 叠加状态字形

#### Scenario: 打开代码补全

- **WHEN** completion 菜单展示 Struct、Field、Method、EnumMember、Module 或其他受管 kind
- **THEN** kind highlight 与编辑区对应语义角色使用同一 foreground，且不额外继承角色粗斜体
