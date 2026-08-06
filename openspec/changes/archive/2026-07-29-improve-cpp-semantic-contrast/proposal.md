## Why

当前 C/C++ 高亮把 field/property 与 parameter 复用同一颜色来源，部分主题还把 field 与普通 identifier、macro 与 keyword、enum member 与 type 压成相同颜色，导致 UE 大型函数和结构体中的语义层次不清。需要统一六个白名单主题的语义角色对比，并覆盖 Treesitter、clangd semantic token 与补全菜单，避免同一角色在不同 surface 上漂移。

## What Changes

- 为 C/C++ 建立统一的语义角色矩阵，至少区分 type/class/struct、field/property、parameter、local variable、function/method、enum member、macro 与 namespace。
- 同时覆盖 Treesitter 新旧 capture、clangd LSP semantic token 与 Blink/nvim-cmp kind highlight，确保语义来源切换时颜色不跳变。
- 对六个白名单主题使用各自现有 palette 的颜色来源，不新增主题或依赖；声明/定义、readonly 与 deprecated 等 modifier 保留可辨识的字形强调。
- 增加主题回归，逐个加载六个主题并冻结关键角色之间的前景色对比和 completion 一致性。

## Capabilities

### New Capabilities

- `cpp-semantic-highlighting`: 规定 C/C++ 语义角色在六个白名单主题、Treesitter/LSP 与补全 surface 上的视觉区分和重载行为。

### Modified Capabilities

- 无。

## Impact

- 修改 `lua/highlights.lua` 的通用 semantic highlight 层。
- 扩展 `tests/cases/theme_spec.lua` 与 `docs/changelog.md`。
- 不引入依赖，不改变主题白名单、默认主题或 LSP handler。
