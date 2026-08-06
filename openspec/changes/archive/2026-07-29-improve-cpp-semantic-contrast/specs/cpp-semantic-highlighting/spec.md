## ADDED Requirements

### Requirement: C/C++ 核心语义角色必须可辨

系统 SHALL 在六个公开主题中为 C/C++ 的 type/class/struct、field/property、parameter、function/method、enum member、macro、namespace 与普通 variable 提供稳定角色配色。type/class/struct 与 field/property 的 foreground MUST 不同；field/property 与 parameter 的 foreground MUST 不同；function/method 与普通 variable 的 foreground MUST 不同；enum member 与 type、macro 与 namespace 的 foreground MUST 不同。普通 local variable SHALL 保持低视觉权重，声明、定义、readonly/static 与 deprecated 状态 SHALL 通过 bold、italic 或 strikethrough 作为第二视觉通道。

#### Scenario: 查看结构体及其字段

- **WHEN** 用户在任一公开主题下查看包含 struct/class 名、field/property 与 parameter 的 C/C++ 代码
- **THEN** struct/class、field/property 与 parameter 使用三个可区分的 foreground，普通 variable 不与 function/method 混淆

#### Scenario: 查看枚举、宏与命名空间

- **WHEN** 用户查看包含 enum member、macro 和 namespace 的 C/C++ 代码
- **THEN** enum member 不使用 type foreground，macro 不使用 namespace foreground

### Requirement: 语义颜色必须跨解析 surface 一致

系统 SHALL 对同一 C/C++ 角色统一设置 Treesitter capture、clangd LSP semantic token，并在 LSP CompletionItemKind 有对应项时统一 Blink/nvim-cmp completion kind。clangd token 到达前后，同一 token 的语义 foreground MUST NOT 因 Treesitter/LSP source 切换而改变；completion 中的 Struct/Class/Field/Property/Function/Method/EnumMember/Constant/Module/Variable SHALL 与编辑区对应角色一致。LSP 标准没有 Parameter 与 Macro completion kind，系统 MUST NOT 伪造这两个 kind。

#### Scenario: clangd semantic token 到达

- **WHEN** C/C++ buffer 先由 Treesitter 着色，随后 clangd 发布 semantic tokens
- **THEN** type、field、parameter、function 等角色保持同一 foreground，仅允许 modifier 叠加字形

#### Scenario: 打开代码补全

- **WHEN** completion 菜单展示 Struct、Field、Method、EnumMember、Module 或其他受管 kind
- **THEN** kind highlight 与编辑区对应语义角色使用同一 foreground

### Requirement: 主题切换后必须重建语义对比

系统 SHALL 在每次 `ColorScheme` 后按当前主题 profile 重建语义角色，不得把上一个主题的 RGB 泄漏到新主题。六个白名单主题 MUST 全部满足核心对比矩阵；主题白名单和默认主题 MUST 保持不变。

#### Scenario: 连续预览多个主题

- **WHEN** 用户在 ThemePicker 中连续预览不同公开主题
- **THEN** 每次预览都使用当前主题 palette 派生角色色，且关键角色对比仍成立

#### Scenario: 恢复默认主题

- **WHEN** 用户切回 `monokai_ristretto`
- **THEN** 语义角色恢复为 Monokai Ristretto profile，默认主题和持久化语义不变
