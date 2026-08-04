## Why

上一轮虽然消除了 C/C++ 核心角色的同色冲突，但为了让每个角色都显著不同，引入了过多互不相关的 accent，并把 type/function/enum 全部加粗、parameter/namespace 斜体、macro 粗斜体。真实 UE 文件中因此出现“彩虹化”和大面积粗斜体，视觉权重高于代码结构本身，不符合 Rider、VS Code Dark+/Light+、Catppuccin 等成熟方案的克制层级。

## What Changes

- 将六主题 profile 改为“主题原生 palette + 成熟角色族”设计：type/namespace、field/enum、parameter/local 等允许在不破坏关键辨识度时复用色道，不再追求八个角色八种颜色。
- 参考 Rider 的低染色密度、VS Code Dark+/Light+ 的 type/callable/variable/constant 分层，以及 Catppuccin 的原生 semantic role，逐主题选择稳定基础 highlight group。
- 基础语义角色只设置 foreground；中和 clangd declaration/scope/readonly/static 等 modifier 的粗斜体，避免高优先级 extmark 把 dense UE 代码重新变成大面积粗斜体，仅 deprecated 保留 strikethrough。
- 更新六主题回归，冻结关键冲突矩阵、刻意共享的角色族、跨 Treesitter/LSP/completion 一致性和字形层级。

## Capabilities

### Modified Capabilities

- `cpp-semantic-highlighting`: 从“尽量逐角色独立 accent”收敛为“成熟主题角色族 + 状态字形”层级，同时保留关键语义对比和跨 surface 一致性。

## Impact

- 运行时：`lua/highlights.lua`
- 回归：`tests/cases/theme_spec.lua`
- 规格：`openspec/specs/cpp-semantic-highlighting/spec.md`
- 文档：`docs/changelog.md`
- 不改变主题白名单、默认主题、插件依赖或持久化格式。
