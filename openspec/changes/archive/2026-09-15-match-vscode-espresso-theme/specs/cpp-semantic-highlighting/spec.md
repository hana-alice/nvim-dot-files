## MODIFIED Requirements

### Requirement: C/C++ 核心语义角色必须形成克制的视觉层级

系统 SHALL 在六个公开主题中为 C/C++ 提供基于成熟 IDE 配色分层的稳定角色族。type/class/struct 与 field/property 的 foreground MUST 不同；field/property 与 parameter 的 foreground MUST 不同；除下述 VS Code Espresso 映射外，field/property 与 ordinary variable 的 foreground MUST 不同；function/method 与 ordinary variable 的 foreground MUST 不同；enum member 与 type 的 foreground MUST 不同；macro 与 namespace/type 的 foreground MUST 不同。系统 MAY 让 namespace 与 type、enum member 与 field、parameter 与 ordinary variable 共享 foreground，以避免无语义价值的八色“彩虹化”。普通 local 与 parameter SHALL 保持低视觉权重。

Sonokai Espresso SHALL 遵循 VS Code Sonokai Espresso 0.2.9 的角色色：type/namespace `#81d0c9`、field/property 与 ordinary variable `#e4e3e1`、parameter `#f08d71`、function `#a6cd77`、enum member/macro `#9fa0e1`。这项明确的主题映射允许 field/local 同色；不把其他主题的对比要求强加到上游 VS Code 原色。内建类型与 storage modifier 属于语法样式，MAY 保留 VS Code 的 italic；命名类型与普通语义角色仍遵循下述字形约束。

基础 namespace、type、field、parameter、variable、function、enum member 与 macro role MUST NOT 被全局强制 bold、italic 或 strikethrough。系统 MUST 中和 clangd declaration/definition、deduced、readonly/static/abstract/virtual、scope 与其他常见 modifier 的 foreground 和粗斜体，避免高优先级 extmark 重新提高常规正文权重；deprecated SHALL 仅通过 strikethrough 表示，且 MUST NOT 改写角色 foreground。

#### Scenario: 查看结构体及其字段

- **WHEN** 用户在任一公开主题下查看包含 struct/class、field/property、parameter 与 local variable 的 C/C++ 代码
- **THEN** type 与 field 可区分；field 与 local family 按主题 profile 区分（VS Code Espresso 的 field/local 共享白色、parameter 为橙色），且基础角色不会因大面积粗斜体抢占代码结构

#### Scenario: 查看枚举、宏与命名空间

- **WHEN** 用户查看 function/method、enum member、macro 和 namespace
- **THEN** callable 与 ordinary variable 可区分、enum member 不使用 type 色、macro 不使用 namespace/type 色

#### Scenario: 查看声明与状态

- **WHEN** clangd 为角色附加 declaration/definition、readonly/static/abstract/virtual、scope 或 deprecated modifier
- **THEN** 常见 modifier 不改变角色 foreground 或基础字形，deprecated 仅叠加 strikethrough
