# keymap-command-regression Specification

## Purpose

定义针对本 Neovim 配置中快捷键绑定与用户命令注册的回归测试覆盖范围：验证关键 keymap 在
加载后于对应模式存在且指向预期命令或行为，并验证配置定义的用户命令在相应 setup 调用后均已
注册，确保「开发完跑一遍」即可发现键位与命令层面的回归。不管具体键位分配是否合理，只管
「声明的绑定确实生效」。

## Requirements

### Requirement: 快捷键绑定回归必须覆盖真实加载后的状态

回归套件 SHALL 验证关键 keymap 在加载 `lua/config/keymaps.lua` 后，于对应模式下存在且映射
到预期命令或行为；校验前 SHALL 设置 leader 并调用 `require("ue").setup()`，使依赖命令就绪。
涉及插件延迟加载或 buffer 附加才生效的键位（如 Git 相关入口）SHALL 在对应加载/附加完成后
另行验证最终行为，防止继承入口覆盖迁移结果被误判为通过。

#### Scenario: 覆盖多模式与依赖 setup 的键位
- **WHEN** keymap 用例加载完成，且相关插件延迟加载、buffer 已附加
- **THEN** 关键 keymap（如 DAP 功能键、leader 系列、核心编辑/导航键）在其声明的模式下均有
  映射，并指向预期命令
- **AND** 依赖延迟加载才生效的入口（如 Git 键位）SHALL 反映加载完成后的最终路由，而非
  初始的临时/继承状态

### Requirement: Visual 替换必须消费当前选择而非旧 marks

Visual 替换 SHALL 从当前 Visual anchor、cursor 与 selection type 捕获文本和行范围，不能依赖
上一次完成选择的 marks；进入替换命令后插入点 SHALL 位于 replacement 字段。

#### Scenario: 首次与后续不同选区
- **WHEN** 用户首次选择文本或改变选区后执行 Visual replace
- **THEN** SHALL 使用本次选区，不抛无效行号错误、不使用旧选区，替换后不修改搜索 pattern

### Requirement: 用户命令注册回归

回归套件 SHALL 验证配置定义的用户命令在相应 setup 调用后均已注册
（`vim.fn.exists(":Cmd") == 2`），任一命令缺失时用例 SHALL FAIL 并打印缺失命令名。

#### Scenario: UE 命令全量注册
- **WHEN** 用例调用 `require("ue").setup()` 后查询
- **THEN** 全部 `UE*` 命令均 `exists == 2`；任一缺失即 FAIL 并报告命令名

### Requirement: 快捷键帮助必须可搜索且保留分类

浮动 cheatsheet SHALL 提供实时搜索入口，搜索 SHALL 同时覆盖快捷键、描述和原始分类，并在
结果界面保留两级分类；用于展示成对大小写命令的分隔符 SHALL 不妨碍直接组合查询。

#### Scenario: mixed-case 成对快捷键可直接发现
- **WHEN** 用户在 cheatsheet 浮窗搜索输入框中输入成对键位的组合（如 `wW`）
- **THEN** 结果直接包含该成对键位，并显示其分类路径

### Requirement: 系统窗口标题命名必须安全且可恢复

配置 SHALL 允许为当前 Neovim/Neovide 系统窗口设置会话级名称，并 SHALL 提供恢复 Neovim 自动
标题的明确路径。自定义名称进入 `'titlestring'` 时 SHALL 按字面显示，不得把用户输入当作
statusline 表达式执行；终端控制字符 SHALL 被移除，长度 SHALL 有界且不切坏 UTF-8。

#### Scenario: 标题输入安全且有界
- **WHEN** 名称含 `%{...}`、换行或终端控制字符
- **THEN** 百分号按字面显示，控制字符被折叠为空格，标题长度有界且不切坏 UTF-8

## 选型与踩坑

- **踩坑**：Git 相关键位如果只在 `keymaps.lua` 加载后立即校验，会因为 LazyVim 的延迟映射
  和 buffer-local Git 映射尚未生效而得到误判「通过」的假阳性——根因是继承入口（终端默认
  Git 键位）在延迟加载完成前仍然生效，掩盖了迁移结果；处置为要求回归套件在插件延迟加载和
  buffer 附加完成后另行验证最终路由。
- **重要事项**：具体键位到命令的映射表（如哪个 leader 前缀对应哪个命令）属于实现细节，不
  在本 spec 固化；spec 只约束「声明了的映射必须真实生效、且在依赖就绪后才可信」这条底线。
- **选型（2026-09-30，用户明确）**：体验提升以**键盘为中心**，不对标 IDE 的鼠标 UI。
  做法是「一个可搜索入口 + 状态栏常驻提示」：`<leader>P`（`:UEHub`）列出当前 target 的全部动作
  并显示其快捷键，`<leader>uu`（`:UETarget`）集中查看/切换项目·平台·设备·包名，`<leader>uk`
  执行上一次失败给出的修复命令；不做可点击工具栏/按钮。
- **选型**：`<F5>` 在无调试会话时运行当前 target 的循环（Android：编 SO → 部署 → 调试启动），
  会话中仍是 continue；`<S-F5>` 停止。target 专属动作与字段由 target driver 的声明式 `hub(state)`
  提供，通用 hub 不含 target 字面量（守护：`ue_platform_boundary`）。
