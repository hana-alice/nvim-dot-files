# curated-theme-entrypoints Specification

## Purpose

把本项目拥有的主题选择 surface 固定为一份策展式白名单，确保 picker、命令
补全、键位入口与持久化恢复不会重新暴露旧主题或未注册 variant，同时只保留
当前白名单所需的最小主题来源（插件声明、lock entries、本地 `colors/`）。
边界：本 spec 管「哪些主题名对用户可见、如何解析持久化状态」，不管具体
配色数值本身的美学设计。

## Requirements

### Requirement: 所有主题入口共享同一白名单，且集合严格受控

`:Theme [name]`、`:ThemePicker` 与相关键位 SHALL 复用同一注册表和 picker；
任何入口 MUST NOT 绕到列举 runtimepath 全部 colorscheme 的上游 picker。
系统 SHALL 以单一有序注册表定义公开主题集合，直接设置只接受该注册表中的
canonical name；旧 alias 与未注册的 theme/flavor/variant name MUST 被拒绝，
拒绝时 SHALL 给出可见错误，且不加载或持久化该值。

#### Scenario: 设置未注册入口
- **WHEN** 用户执行 `:Theme <name>`，`<name>` 不在当前白名单注册表中
- **THEN** 系统拒绝该值、给出可见错误，且不加载或持久化它

#### Scenario: 查询主题 completion
- **WHEN** `:Theme` 请求 completion candidates
- **THEN** 返回且仅返回注册表中的 canonical name，不多不少

### Requirement: 持久化主题不能扩大公开集合，非法 state 必须回退并迁移

持久化 state SHALL 仅作为白名单内的当前选择使用，MUST NOT 被加入 completion
或 picker。state 缺失、含旧值、未知值或已删除 alias 时，启动 SHALL 在尝试
加载前回退到注册表中约定的默认主题，并把 state 迁移为该 canonical name。

#### Scenario: 旧 state 迁移
- **WHEN** state 保存的名称不在当前白名单注册表中
- **THEN** 启动不尝试加载该名称，而加载默认主题并重写 state

### Requirement: 白名单主题的来源必须保持可加载，且不多不少

系统 SHALL 保留白名单中每个主题所需的最小来源（插件声明 / lock entries /
本地 `colors/`）；仅服务已删除主题的插件声明、lock entries 和本地 colorscheme
文件 MUST 被移除。当某个 variant（如特定配色分支）需要通过设置插件全局变量
才能生效时，该设置 SHALL 在实际加载该主题前强制执行，覆盖外部代码对同一
全局变量的修改。

#### Scenario: 逐项加载
- **WHEN** 回归依次应用白名单中的每个 canonical name
- **THEN** 每次加载均成功；映射到同一插件的多个 variant 分别持久化为各自
  独立的 canonical current identity

#### Scenario: 审计主题依赖
- **WHEN** 检查项目 plugin declarations、lock file 和 `colors/`
- **THEN** 只存在白名单主题所需的依赖，已下线主题的插件/lock/colorscheme
  不再作为项目主题来源存在

## 选型与踩坑

- **选型**：当前白名单恰为六项：`monokai_ristretto`（默认）、`rider-light`、
  `ubuntu-terminal`、`unokai`、`catppuccin`、`sonokai-espresso`（Sonokai
  插件的 Espresso variant，通过启动前强制 `g:sonokai_style = "espresso"`
  实现，配色对照 VS Code Sonokai Espresso 0.2.9）；Sonokai 的 Default /
  Atlantis / Andromeda / Shusia / Maia 等其他 variant 不作为独立公开入口。
  Tokyo Night、Kanagawa、Apprentice、Porcelain White 等历史主题已下线，
  不再作为项目主题来源存在。
- **选型**：所有主题入口（命令、picker、键位）共享一份注册表，而不是各自
  维护候选列表——否则某个入口绕开白名单直接读 runtimepath，会让「已下线
  主题」通过侧门重新出现，白名单形同虚设。
- **选型**：持久化 state 只作已验证选择的存储，不参与 completion/picker
  候选构成——防止一个曾经合法但后来被下线的旧值通过 state 泄露回可见
  candidate 列表。
- **踩坑**：VS Code 风格的强制粗斜体/斜体覆盖如果不在主题加载后每次重放
  （启动恢复、picker 预览、`ColorScheme` 事件重新应用），会在切换主题后
  残留成上一个主题的覆盖痕迹；因此 variant 专属的语法覆盖 SHALL 在每次
  实际加载后重放，并在切到其他主题后不残留。
- **重要事项**：本 capability 只锁定「对用户可见的主题名集合」与「持久化
  解析规则」，具体配色数值的选型与截图对照证据见各主题上线时的归档
  change（`openspec/changes/archive/` 下与主题相关的条目）。
