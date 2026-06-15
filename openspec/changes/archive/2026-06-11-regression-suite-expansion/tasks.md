## 1. harness 能力扩展

- [x] 1.1 在 `tests/harness/init.lua` 新增 `assert_contains(container, item, msg?)`：支持字符串子串与列表元素，失败打印容器与期望项
- [x] 1.2 在 harness 新增 `get_keymap(mode, lhs)`：调用 `nvim_get_keymap`，规范化 `<leader>`/`<localleader>`→实际 leader、termcode（`<F5>`/`<C-v>`）经 `nvim_replace_termcodes` 比较，命中返回 map 表否则 nil
- [x] 1.3 导出新接口并跑现有全量（`nvim --headless -l tests/run.lua`）确认 113 项无回归

## 2. 快捷键回归用例

- [x] 2.1 新建 `tests/cases/keymaps_spec.lua`，文件头固定前置：设 `vim.g.mapleader=" "`/`maplocalleader=" "` → `require("ue").setup()` → `pcall(dofile, cfg.."/lua/config/keymaps.lua")`
- [x] 2.2 断言 DAP 功能键 `<F5>/<F6>/<F9>/<F10>/<F11>/<S-F11>` 在 `n/i/t/v` 四模式均有映射，且 `<F5>`→`UEDAPContinue`、`<F9>`→`UEDAPToggleBreakpoint`、`<F10>`→`UEDAPStepOver`
- [x] 2.3 断言 leader 代表键：`<leader>db`→`UEDAPToggleBreakpoint`、`<leader>dc`→`UEDAPContinue`、`<leader>da` 含 `UEDAPAttach`、`<leader>vv`/`<leader>vb`/`<leader>vg` 存在、`<leader>ub`→`UEBuild`、`<leader>ul`→`UELaunch`
- [x] 2.4 断言核心键：`gd`/`gr`/`gc`(n,x)/`gcc` 存在；Windows 下 cmdline `<C-v>`→`<C-r>+`、insert `<C-v>`→`<C-r><C-o>+`（非 Windows 跳过该子断言）

## 3. 用户命令注册回归用例

- [x] 3.1 新建 `tests/cases/commands_spec.lua`，维护 69 个 `UE*` 命令冻结清单常量
- [x] 3.2 `require("ue").setup()` 后断言清单内全部 `UE*` 命令 `vim.fn.exists(":Cmd")==2`，缺失打印命令名
- [x] 3.3 `pcall(dofile, keymaps.lua)` 后断言 `Restart`/`RestartDetect`/`UEDefStatus` 已注册
- [x] 3.4 `require("workarounds").setup({auto_apply=false})` 后断言 `WorkaroundList`/`WorkaroundStatus`/`WorkaroundEnable`/`WorkaroundDisable` 已注册

## 4. options / autocmd 行为用例

- [x] 4.1 新建 `tests/cases/options_spec.lua`，`dofile(options.lua)` 后断言 `expandtab=true`、`shiftwidth/softtabstop/tabstop=4`、`number=true`、`relativenumber=false`、`list=false`、`sessionoptions` 含 buffers/tabpages/winsize/skiprtp
- [x] 4.2 新建 `tests/cases/autocmds_spec.lua`，断言 `vim.filetype.match` 对 `x.usf`/`x.ush` 返回 `hlsl`
- [x] 4.3 在 autocmds 用例新建 scratch buffer 设 `filetype=cpp` 触发 FileType autocmd，断言 `cindent=true`、`smartindent=false`、`cinoptions=="g0,:0,l1,(0,W4,t0,j1,J1"`
- [x] 4.4 断言 hlsl commentstring 回退为 `// %s`（设 hlsl buffer filetype 后读 `vim.bo.commentstring`，或直接验证回退表逻辑）

## 5. workarounds 完整性用例

- [x] 5.1 新建 `tests/cases/workarounds_spec.lua`，`require("workarounds").setup({auto_apply=false})` 后用 `vim.fn.glob` 数 `lua/workarounds/*/*.lua` 文件数，断言 `#list() >= 文件数`
- [x] 5.2 断言注册表无任何 `error` 项；遍历条目断言必填字段（name/scope/symptom/introduced/removal_condition）齐全、`enabled` 为 boolean
- [x] 5.3 断言 `status(<任一已注册名>)` 返回含 `name/scope/applied` 的 table；`status("不存在")` 返回 nil

## 6. utils 纯函数行为用例

- [x] 6.1 新建 `tests/cases/fs_proc_spec.lua`：断言 `ue.core.fs` 的 `norm`/`join`/`is_absolute_path`(/a, C:/a, a/b)/`relative_to`/`common_ancestor`，以及 `ue.core.proc.first_executable({})==nil`
- [x] 6.2 新建 `tests/cases/ue_paths_spec.lua`：断言 `is_blocked`（intermediate/binaries/.git → true；普通源码 → false）、`is_searchable`（.cpp→true，.txt→false）、`filter` 保序且只留可搜索项
- [x] 6.3 新建 `tests/cases/ue_goto_behavior_spec.lua`：断言 `ranking.rerank_locations` 把 .cpp 排在 .h 前、`pair_picker.pick_safe_winner`（header+cpp→该 cpp，无关两文件→MISS）、`location.dedup_locations` 去重

## 7. 稳定性 / 幂等用例

- [x] 7.1 新建 `tests/cases/stability_spec.lua`：断言 `ue`/`ue.config`/`utils.platform`/`utils.ue_paths` 连续两次 require 返回同一引用
- [x] 7.2 断言 `require("ue").setup()` 连续两次无异常，且 `UEBuild`/`UEDAPAttach` 两次后仍 `exists==2`
- [x] 7.3 断言 `ue.config` 三轮 `setup()`→`reset_for_test()` 后 `index.idle_cold_ms` 恢复 120000、末轮 `dap.lldb_dap_path` 为 nil
- [x] 7.4 断言 `ue.dap.platforms` 连续两次 `_reset_for_test` 后注册/查询正常、未注册项返回 nil

## 8. 文档与验证

- [x] 8.1 更新 `docs/testing-regression.md`：新增用例域、覆盖矩阵、命令冻结清单维护约定、keymap 断言前置说明
- [x] 8.2 运行 `nvim --headless -l tests/run.lua`，确认全部用例 PASS、退出码 0
- [x] 8.3 制造一个临时失败用例（如断言一个不存在的 keymap），确认 FAIL 输出含 `describe > it` 与 expected/actual，退出码 1，验证后删除
- [x] 8.4 运行 `scripts/run_regression.ps1`，确认本机一键路径与退出码转发正确
- [x] 8.5 用 `FILTER=keymaps` / `-Filter keymaps` 抽查 filter 仍只跑匹配用例且不触发 legacy 旁路
