## Context

当前实现已经把 Treesitter、clangd semantic token 和 completion 对齐，但 `ROLE_STYLES` 给基础角色普遍附加 bold/italic，且若干 profile 为了满足过强的 pairwise-difference 测试而从诊断或字面量色组借色。结果是结构可辨，却缺少成熟 IDE 主题常见的“少量色族 + 明确权重”层次。

本机可直接审计的参考实现包括：

- VS Code Dark+/Light+：type/namespace 共用 type 色；function 使用 callable 色；variable/parameter 共用变量色；constant/enum 形成常量色族。
- Rider Light：普通 type、parameter、local 保持接近正文；field/constant 用紫色族，function 用 teal，macro 用 metadata 色，整体染色密度较低。
- Catppuccin：type=yellow、field=lavender、parameter=maroon、variable=text、function=blue、enum member=teal、macro=mauve/pink，基础角色默认不靠粗斜体区分。
- Monokai/Sonokai：保留其 aqua/green/orange-purple/pink 的经典语法色族，不注入主题外 RGB。

## Goals / Non-Goals

**Goals**

- 在六个公开主题中形成克制、一致、可读的 C/C++ 视觉层级。
- 保留 type↔field、field↔parameter、function↔variable、enum↔type、macro↔namespace 等关键区别。
- 允许成熟方案中合理的共享：namespace↔type、enum↔field、parameter↔variable。
- 让基础角色 foreground 承担类别识别，字形只承担状态信息。

**Non-Goals**

- 不把六个主题改造成同一套 RGB。
- 不要求所有角色两两异色。
- 不修改非 C/C++ 的主题映射、UI chrome、字体家族或字号。
- 不新增 colorscheme 或依赖。

## Decisions

### D1 — 采用角色族，而非八色分类

角色组织为四个主要色族和两个特殊色族：

1. type family：type/class/struct + namespace；namespace 可与 type 同色。
2. data family：field/property + enum member；两者可同色，但均须区别于 type。
3. local family：parameter + ordinary variable；两者可同色，保持低权重。
4. callable family：function/method，须区别于 ordinary variable。
5. macro family：macro，须区别于 namespace/type。
6. 状态 channel：仅 deprecated 保留通用 strikethrough；declaration/scope/readonly/static 等状态由上下文、语言结构和 IDE 专属 UI 承担，不给正文全局加粗斜体。

这样与 Dark+/Light+、Rider 和 Catppuccin 的成熟分层一致，也避免为了测试制造无语义价值的彩虹。

### D2 — 每个 profile 只引用主题原生基础组

不硬编码统一 RGB。profile 从主题自身的基础 highlight group 取 foreground：

- Monokai Ristretto：Aqua(type)、Tag(field/enum)、Orange(parameter/local)、Green(callable)、Purple(macro)。
- Rider Light：正文(type/local)、Purple(field/enum)、Teal(callable)、Yellow metadata(macro)。namespace 使用低权重 comment 色。
- Ubuntu Terminal：Cyan(type)、Purple(field/enum)、Orange(parameter/local)、Green(callable)、Pink(macro)。
- Unokai：Orange(type)、Cyan(field/enum)、Normal(local)、Green(callable)、Pink(macro)。
- Catppuccin：Yellow(type)、Lavender(field)、Maroon(parameter)、Text(variable)、Blue(callable)、Teal(enum)、Mauve(macro)。
- Sonokai Espresso：Aqua(type)、Orange(field/enum)、Normal(parameter/local)、Green(callable)、Purple(macro)。

### D3 — 基础角色禁用强制粗斜体

所有 role target 与 completion kind 只携带 foreground。基础语义不再强制 bold/italic，避免：

- type/function/enum 在大型 C++ 文件中过度加粗；
- parameter/namespace 全局斜体导致字形噪声；
- macro 粗斜体抢占控制流和诊断的视觉优先级。

### D4 — 中和高优先级 modifier 字形，仅保留 deprecated

clangd 会为大量 token 叠加 declaration、readonly、abstract、classScope/globalScope 等高优先级 extmark。若这些 group 设 bold/italic，即使基础 role 已恢复常规字重，真实 UE buffer 仍会出现大片粗斜体。因此：

- declaration / definition / deduced / readonly / static / abstract / virtual 以及 function/class/file/global scope 等 modifier：空 highlight，不带 foreground 或字形。
- deprecated：strikethrough，不带 foreground。

这保留角色色并把常规正文维持在单一字重；deprecated 仍使用跨 IDE 都成熟的删除线约定。

## Risks / Trade-offs

- parameter 在 Rider、Sonokai 中可能与 local variable 同色；这是有意采用成熟方案的低染色密度，参数仍可由语法位置和 modifier 识别。
- namespace 与 type 在多数深色主题中同色；二者同属命名/类型结构层，不应消耗额外 accent。
- field 与 enum member 在部分主题中共享 data/constant 色；它们不会在同一语法位置直接竞争，且仍与 type、local 明确分离。

## Validation

- 六主题真实加载并检查 foreground family。
- Treesitter、clangd、Blink/nvim-cmp 对应 surface 同色。
- 基础 role 无 bold/italic/strikethrough；常见 clangd modifier 完全中和，deprecated 仅有 strikethrough 且无 foreground。
- `ColorScheme` 连续切换不泄漏前一主题状态。
- 在当前 Neovide 的真实 clangd UE C++ buffer 热加载检查视觉密度。
