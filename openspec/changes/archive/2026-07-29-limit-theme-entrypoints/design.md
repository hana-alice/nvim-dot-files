## Context

主题有三类来源：外部插件（Monokai、Catppuccin，以及待删除的 Tokyo Night/Kanagawa）、仓库本地 `colors/*.lua`（Rider Light、Ubuntu Terminal，以及待删除的 Apprentice/Porcelain White）、Neovim runtime 内置 Unokai。当前 `lua/theme.lua` 另行维护 labels、plugin mapping、aliases，并把持久化文件中的任意名称重新加入列表，因此即使注册表删项，旧 state 也可把它重新暴露。LazyVim extras 还可能占用 `<leader>uC` 打开未过滤的原生 colorscheme picker。

## Goals / Non-Goals

**Goals:**

- 单一有序注册表定义五个 canonical theme、显示名称和按需加载插件。
- 所有项目拥有的主题入口只展示并接受这五项。
- 旧持久化值不能扩大白名单，且启动时安全迁移到默认项。
- 删除仅服务于旧主题的插件和本地文件。

**Non-Goals:**

- 不修改五个主题本身的 palette 或 highlight 语义。
- 不 fork LazyVim、Catppuccin、Monokai，也不新增主题依赖。
- 不试图删除 Neovim runtime 自带的其他 `:colorscheme` 文件；约束的是本项目提供的主题入口。

## Decisions

### D1：有序 `THEMES` 数组是唯一公开主题真相

`lua/theme.lua` 使用固定数组，每项为 `{ name, label, plugin? }`；completion、picker、合法性检查和 plugin lazy-load 均从它派生。相比多张并行 map，这能避免名称、label 与插件映射漂移，并天然冻结用户要求的顺序。

### D2：不保留旧 alias

`normalize_name` 只 trim，不再把 `white`、`ubuntu`、`rider` 或 Catppuccin flavor alias 映射到 canonical name。原因是“入口只保留五个主题”同时要求直接设置不能继续提供隐形旧入口；用户或脚本必须使用五个 canonical name。

### D3：持久化 state 只消费白名单值

`startup()` 仅在 saved name 位于注册表时返回它，否则返回默认 `monokai_ristretto`。`load_startup()` 发现非空旧值时立即把 state 文件迁移为默认值。列表生成不再读取 state，因此损坏值或旧值都不能进入 picker/completion。

### D4：Catppuccin canonical identity 与实际 flavor 分离

执行 `:colorscheme catppuccin` 后插件可能把 `vim.g.colors_name` 设为 `catppuccin-mocha`。`current()` 将任意 `catppuccin-*` 运行时名称折叠为公开 identity `catppuccin`，仅用于 picker 当前项标记；这些 flavor 不成为可选择入口。

### D5：覆盖 `<leader>uC` 而不是依赖 extras 当前状态

项目同时绑定 `<leader>ut` 与 `<leader>uC` 到 `ThemePicker`，并以 VeryLazy runtime override + `nowait=true` 固定优先级。这样未来启用 Snacks/FZF theme extra 时，上游全量 colorscheme picker也不会绕过白名单。

### D6：禁用上游 Tokyo Night spec，保留 Catppuccin

LazyVim 基础 spec 自带 Tokyo Night 与 Catppuccin。项目通过同 plugin key 声明 Tokyo Night `enabled=false`；Catppuccin 是五项之一，继续复用上游 spec。Kanagawa 的本地声明直接删除，Monokai 保留。相应 lock entries 删除，避免依赖面与公开集合漂移。

## Risks / Trade-offs

- [直接执行原生 `:colorscheme <runtime-name>` 仍可加载 Neovim 内置其他主题] → 明确 capability 边界为项目主题入口（`:Theme`、`ThemePicker`、leader keys）；不篡改原生命令或 runtimepath。
- [旧自动化使用 alias 会失败] → 这是有意的 breaking 收敛；文档列出五个 canonical name，错误通过现有 `utils.log.notify_error` 可见。
- [上游重新绑定 `<leader>uC`] → 本地 VeryLazy override 与 keymap regression 固定最终路由。
- [旧持久化主题插件已删除导致启动失败] → 在尝试加载前先白名单校验并选择 Monokai Ristretto。

## Migration Plan

1. 先切换注册表、默认值和 state 校验，确保旧 state 有安全回退。
2. 覆盖所有主题键位入口并更新 completion/picker tests。
3. 删除旧 plugin declarations、lock entries 与本地 colorscheme 文件。
4. 运行五主题逐一加载、theme/smoke/keymaps/commands/cheatsheet filters 和全量回归。
5. 回滚时恢复旧注册表、插件声明、lock entries 和本地文件；已迁移的 state 将保持 `monokai_ristretto`，仍是旧版本可识别值。

## Open Questions

无。
