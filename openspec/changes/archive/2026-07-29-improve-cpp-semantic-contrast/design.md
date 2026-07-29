## Context

`lua/highlights.lua` 已在 `ColorScheme` 后统一补齐 Treesitter/LSP group，但现有规则主要直接复制 `Type`、`Identifier`、`Function` 等基础 group。field/property 与 parameter 都来自 `Identifier`，在 Sonokai Espresso 当前分别得到同一个 `#f08d71`；Monokai Ristretto 中它们甚至都接近正文色。另有三个一致性缺口：Treesitter 已使用 `@variable.parameter`，通用层仍只设置旧 `@parameter`；clangd 会发 `@lsp.type.variable.cpp`，通用层没有显式处理；completion 的 Field/Property kind 仍由主题上游各自映射，与编辑区可能不同。

本地 `rider-light` 与 `ubuntu-terminal` 自带完整角色映射，之前被通用层跳过，但其中 Rider 的 type 与正文同色、Ubuntu 的 field 与正文同色，也不满足本次“六主题一致可辨”的目标。与其分别修改两个大型 colorscheme，更适合让通用层成为白名单主题加载后的最终、可测试语义层。

## Goals / Non-Goals

**Goals:**

- 六个公开主题中，type/class/struct、field/property、parameter、function/method、enum member、macro、namespace 与普通 variable 具有稳定且可辨的角色。
- Treesitter、clangd semantic token、Blink/nvim-cmp completion 对同一角色使用同一 foreground。
- 复用每个主题自己的基础 palette，保持主题身份，不硬编码一套跨主题 RGB。
- 每次 `ColorScheme` 后可重放，且 headless 可验证。

**Non-Goals:**

- 不更改主题白名单、默认主题或上游 colorscheme 文件。
- 不改变 clangd token 生成、LSP handler、Treesitter query 或字体配置。
- 不保证所有非白名单原生 `:colorscheme` 的完整配色质量。

## Decisions

### D1：按主题 palette source 定义角色，而不是复用单一 Identifier

`lua/highlights.lua` 增加小型 per-theme profile，profile 只引用主题加载后已经存在的基础 highlight group，例如 Type、Identifier、Function、Constant、Number、Special、Macro、Include。运行时读取这些 group 的实际属性，再派生角色 group；不复制 RGB，也不修改插件 palette。

每个 profile 明确指定：type、field、parameter、variable、function、enum member、macro、namespace 的来源。选择时优先保证相邻角色 foreground 不相同；normal variable 保持正文色，避免大型 C++ 文件过度彩色。

### D2：一个角色同时覆盖三层 surface

每个角色一次性写入：

1. Treesitter capture（含当前 `@variable.parameter` / `@variable.member` 和旧兼容 capture）；
2. clangd `@lsp.type.*` 及 `.cpp` 变体；
3. LSP CompletionItemKind 标准实际存在的 `CmpItemKind*` 与 `BlinkCmpKind*` completion kind（例如 Module/Struct/Field/Method/EnumMember/Constant）。Parameter 与 Macro 没有标准 completion kind，不创建伪 group。

这样 LSP 未就绪时的 Treesitter、LSP token 到达后和补全菜单不会显示三套含义冲突的颜色。

### D3：modifier 只负责字形，不覆盖 role foreground

通用层显式设置 declaration/definition 为 bold、readonly/static 为 italic、deprecated 为 strikethrough，但不为 generic modifier 设置 foreground。Neovim 会叠加 semantic token extmarks，role type token 继续提供颜色，modifier 只提供强调，避免 declaration 突然变成另一种角色。

### D4：所有白名单主题都经过最终语义层

移除 Rider Light 与 Ubuntu Terminal 的 early return。它们仍定义完整 UI 和语言特定 palette；通用层只在 `ColorScheme` 完成后收敛 C/C++ 核心角色及 completion kind。相比在两个 700+ 行本地 colorscheme 和四个外部主题中分别维护，此方案有单一真相和统一回归。

## Risks / Trade-offs

- [某主题基础 group 彼此本就同色] → profile 为该主题选择不同的现有 palette source，并以回归断言关键角色 foreground 不相同。
- [italic 字形在终端字体中不明显] → 关键区分以 foreground 为主，bold/italic 只作第二通道。
- [语言特定 capture 被通用 group 覆盖] → 仅覆盖核心通用/C++ semantic groups，不触碰 Markdown、JSON、CSS 等 filetype-specific capture。
- [semantic modifier extmark 覆盖 role] → modifier 不设 foreground，只叠加字形；真实 clangd token 用 `vim.inspect_pos` 验证。

## Migration Plan

1. 增加 profile 与统一角色应用 helper，移除本地主题跳过逻辑。
2. 扩充六主题回归并运行 theme/smoke 与全量测试。
3. 在当前 Neovide 重载 `highlights` 并对真实 clangd C++ buffer 检查 class/property/parameter token。
4. 回滚时只需恢复 `lua/highlights.lua` 旧映射；主题 state 与插件无需迁移。

## Open Questions

无。
