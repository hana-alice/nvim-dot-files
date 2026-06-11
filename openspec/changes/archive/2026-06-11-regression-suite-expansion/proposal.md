## Why

首版回归套件（`config-regression-suite` / `headless-test-harness`）只覆盖了 `ue` 模块、平台驱动、DAP 注册、少量 utils 加载，约 107 项断言。但配置里大量「日常会用、坏了会立刻影响体验」的功能没有被守护：**快捷键绑定**（85 条 `vim.keymap.set`，含 DAP 功能键、`<leader>` 系列、Windows 粘贴）、**用户命令注册**（69 个 `UE*` 命令）、**options/autocmd 行为**（cindent、usf/ush→hlsl、混行尾 reload）、**workarounds 注册表完整性**、**纯函数 utils 行为**（fs/proc/ue_paths/ranking/pair_picker/location）。这些目前只能靠人工点检，回归风险高。本次扩充把覆盖面从「模块能加载」推进到「关键功能行为正确」，让「开发完跑一遍」真正可信。

## What Changes

- **新增快捷键回归**：断言关键 keymap 在对应模式下存在且映射到预期命令/行为（DAP 功能键 F5/F9/F10/F11 在 n/i/t/v 多模式、`<leader>d*`、`<leader>v*` sidebar、`<leader>u*` UE、`<leader>s*` 搜索、Windows `<C-v>` 粘贴、`gd`/`gr`/`gc`）。
- **新增用户命令注册回归**：断言全部 69 个 `UE*` 命令 + `Restart`/`RestartDetect`/`Workaround*`/`UEDef*` 在 `ue.setup()` 后均通过 `vim.fn.exists(":Cmd")==2`。
- **新增 options/autocmd 行为回归**：断言 `expandtab/shiftwidth=4`、`number`、`sessionoptions`；`.usf/.ush` 文件类型解析为 `hlsl`；C 家族 FileType 触发 `cindent=true` 且 `smartindent=false`；commentstring 回退（hlsl→`// %s`）。
- **新增 workarounds 注册表回归**：断言注册表能发现全部 workaround 文件、frontmatter 必填字段齐全、`list()`/`status()` 形状正确、无 `error` 项。
- **新增 utils 纯函数行为回归**（不只是加载）：`ue.core.fs`（norm/join/relative_to/is_absolute_path/common_ancestor）、`ue.core.proc.first_executable`、`utils.ue_paths`（is_blocked/is_searchable/filter）、`utils.ue_goto.ranking`（.cpp 排在 .h 前）、`utils.ue_goto.pair_picker`（配对判定）、`utils.ue_goto.location`（dedup/normalize_path）的输入→输出断言。
- **新增稳定性/健壮性回归**：关键模块重复 require 幂等、`ue.setup()` 可重复调用不报错、`ue.config.setup()`→`reset_for_test()` 多轮后无状态泄漏、DAP 平台多次 `_reset_for_test` 干净。
- **扩展 harness 能力**（按需）：补充 `assert_contains`（表/字符串包含）、keymap 查询辅助 `get_keymap(mode, lhs)`，供新用例复用。
- **同步文档**：在 `docs/testing-regression.md` 增补新增用例域与覆盖矩阵。

## Capabilities

### New Capabilities
- `keymap-command-regression`: 覆盖 keymap 绑定与用户命令注册的回归校验，确保快捷键与 `UE*` 命令在 headless 下可被发现且映射符合预期。
- `editor-behavior-regression`: 覆盖 options/autocmd/filetype/workarounds 等编辑器行为层的回归校验，守护「nvim 功能稳定性」类配置不被改坏。

### Modified Capabilities
- `config-regression-suite`: 扩充既有套件的覆盖口径——从「模块能加载 + 公共 API 冻结」增加到「utils 纯函数行为断言」与「重复调用/状态隔离的稳定性断言」，相关 Requirement 行为范围扩大。
- `headless-test-harness`: 框架新增断言（`assert_contains`）与 keymap 查询辅助能力，断言与分组 API 的范围扩展。

## Impact

- 新增用例文件（`tests/cases/` 下，自动发现，无需改 `run.lua`）：
  - `keymaps_spec.lua`、`commands_spec.lua`、`options_spec.lua`、`autocmds_spec.lua`、`workarounds_spec.lua`、`fs_proc_spec.lua`、`ue_paths_spec.lua`、`ue_goto_behavior_spec.lua`、`stability_spec.lua`。
- 小幅扩展 `tests/harness/init.lua`（新增断言与 keymap 辅助），向后兼容既有用例。
- 受影响代码：仅以「只读 require + 断言 + 查询 keymap/命令存在性」访问现有模块（`lua/config/**`、`lua/ue/**`、`lua/utils/**`、`lua/workarounds/**`），不修改运行时行为。
- 依赖：不引入新第三方依赖，纯 Lua。
- 运行入口与退出码约定不变：`nvim --headless -l tests/run.lua` / `scripts/run_regression.ps1`。
- 注意：keymap 校验需要加载 `lua/config/keymaps.lua`（它在非完整启动下未必自动执行），用例需显式 `dofile`/`require` 触发绑定后再断言——这是本次的主要技术点，在 design.md 详述。
