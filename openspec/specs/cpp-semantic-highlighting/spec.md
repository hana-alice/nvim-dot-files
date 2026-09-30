# cpp-semantic-highlighting Specification

## Purpose

统一六个公开主题中的 C/C++ 核心语义角色（struct/class、field/property、parameter、
variable、function、enum member、macro、namespace），使这些角色在 Treesitter、clangd
semantic token 与补全 surface 上保持可辨且一致，并在主题切换后可重放。不管具体 RGB 取值
的美学决策，只管跨 surface 一致性、切换重建与视觉层级三条底线。

## Requirements

### Requirement: 语义颜色必须跨解析 surface 一致

系统 SHALL 对同一 C/C++ 角色统一设置 Treesitter capture、clangd LSP semantic token，并在
completion kind 有对应项时统一 completion kind 颜色。clangd token 到达前后同一 token 的
foreground MUST NOT 因 source 切换而改变；LSP 标准没有 Parameter/Macro completion kind，
系统 MUST NOT 伪造这两个 kind。

#### Scenario: clangd semantic token 到达
- **WHEN** C/C++ buffer 先由 Treesitter 着色，随后 clangd 发布 semantic tokens
- **THEN** type、field、parameter、function 等角色保持同一 foreground 和克制的基础字形，仅
  允许 modifier 叠加状态字形

### Requirement: 主题切换后必须重建语义对比

系统 SHALL 在每次 `ColorScheme` 后按当前主题 profile 重建语义角色，不得把上一个主题的 RGB
泄漏到新主题。六个白名单主题 MUST 全部满足核心对比矩阵；主题白名单和默认主题
(`monokai_ristretto`) MUST 保持不变。

#### Scenario: 连续预览多个主题
- **WHEN** 用户在 ThemePicker 中连续预览不同公开主题
- **THEN** 每次预览都使用当前主题 palette 派生角色色，且关键角色对比仍成立

### Requirement: C/C++ 核心语义角色必须形成克制的视觉层级

系统 SHALL 在六个公开主题中为 C/C++ 提供基于成熟 IDE 配色分层的稳定角色族：type/class/struct
与 field/property 的 foreground MUST 不同；field/property 与 parameter MUST 不同；除 VS Code
Sonokai Espresso 的明确上游映射外，field/property 与 ordinary variable MUST 不同；
function/method 与 ordinary variable MUST 不同；enum member 与 type MUST 不同；macro 与
namespace/type MUST 不同。系统 MAY 让 namespace 与 type、enum member 与 field、parameter 与
ordinary variable 共享 foreground，避免无语义价值的"彩虹化"。基础角色 MUST NOT 被全局强制
bold/italic/strikethrough；clangd 的 declaration/definition、readonly/static/abstract/virtual
等常见 modifier SHALL 被中和，不得改写角色 foreground 或提高粗斜体权重；deprecated 仅通过
strikethrough 表示。

#### Scenario: 查看结构体及其字段
- **WHEN** 用户在任一公开主题下查看包含 struct/class、field/property、parameter 与 local
  variable 的 C/C++ 代码
- **THEN** type 与 field 可区分；field 与 local family 按主题 profile 区分（VS Code Espresso
  的 field/local 共享白色、parameter 为橙色），基础角色不因大面积粗斜体抢占代码结构

## 选型与踩坑

- **选型**：VS Code Sonokai Espresso 0.2.9 的角色色被直接采纳为该主题的明确映射
  （type/namespace `#81d0c9`、field/property 与 variable 共享 `#e4e3e1`、parameter
  `#f08d71`、function `#a6cd77`、enum member/macro `#9fa0e1`），不强行套用其他主题的
  「field 与 variable 必须不同」规则——理由是尊重上游原色，不把跨主题一致性要求强加到单个
  主题的既有设计上。
- **选型**：不追求八种角色各自独占一色（"彩虹化"），允许 namespace/type、enum
  member/field、parameter/variable 三对角色共享颜色，因为额外区分对这三对没有语义价值，反而
  增加视觉噪音。
- **重要事项**：内建类型与 storage modifier 属于语法样式，MAY 保留 VS Code 的 italic；命名
  类型与普通语义角色仍遵循字形约束（不被全局强制粗斜体）。
