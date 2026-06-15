## Context

首版回归套件已落地（`tests/run.lua` 自动发现 `tests/cases/*_spec.lua`，harness 提供 `describe/it` + 断言 + `quit`/`cquit 1`，当前 113 项全绿）。本次在同一框架上扩充覆盖面，无需改运行入口。

已用 headless 探针确认的关键事实（决定实现方式）：

1. **keymaps 不会在 `nvim -l` 下自动加载**：LazyVim 通常在 VeryLazy 事件 require `config.keymaps`，headless `-l` 路径不触发。直接 `dofile(".../lua/config/keymaps.lua")` 可成功执行并注册映射（探针确认 `ok=true`）。
2. **leader 前缀必须先设置**：`vim.g.mapleader`/`maplocalleader` 必须在 `dofile(keymaps)` 之前设为 `" "`，否则 `<leader>db` 会以字面 `<leader>` 记录而非 ` db`。探针确认设置后 `nvim_get_keymap("n")` 中 lhs 为 `" db"`，rhs 为 `<Cmd>UEDAPToggleBreakpoint<CR>`。
3. **`<leader>u*` 覆盖依赖 VeryLazy / vim_did_enter**：`apply_ue_runtime_overrides()` 在 `vim.v.vim_did_enter == 1` 时立即执行。headless `-l` 下 `vim_did_enter` 已为 1（探针确认），故 `dofile(keymaps)` 后 `<leader>ub`→`UEBuild` 立即生效。
4. **命令依赖 `ue.setup()`**：`UEBuild` 等需先 `require("ue").setup()`；`WorkaroundList` 需 `require("workarounds").setup()`。探针确认 setup 前 `WorkaroundList exists=0`。
5. **`vim.filetype.match` 可用于断言 usf→hlsl**；FileType autocmd 需手动 `vim.api.nvim_exec_autocmds("FileType", { buffer = b })` 或设 `vim.bo.filetype` 触发后再读 `vim.bo.cindent`。

约束（CLAUDE.md / openspec/config.yaml）：中文产出物、不改运行时逻辑、不引依赖、纯 Lua、复用现有 helper、Windows 单条命令风格。

## Goals / Non-Goals

**Goals:**

- 把覆盖面从「模块能加载 + API 冻结」扩展到「快捷键/命令注册 + options/autocmd 行为 + workarounds 完整性 + utils 纯函数行为 + 稳定性幂等」。
- 所有新用例复用现有 harness 与自动发现；新增用例零改 `run.lua`。
- harness 增补 `assert_contains` 与 `get_keymap` 辅助，向后兼容既有用例。
- 同步更新 `docs/testing-regression.md` 覆盖矩阵。
- 保持全量绿、退出码语义不变。

**Non-Goals:**

- 不模拟真实按键触发（不 `feedkeys` 执行 DAP/sidebar 动作）——只校验「绑定存在 + 指向预期命令/行为」，避免引入交互与外部依赖。
- 不测试第三方插件（blink/snacks/lazy）内部行为，只测我方配置对它们的接线是否注册。
- 不追求行覆盖率数字，沿用「功能域 + 行为断言」口径。
- 不改动 `lua/config/**` 等被测代码。

## Decisions

### 决策 1：keymap 用例显式 `dofile(config/keymaps.lua)` 并前置 leader/setup

- 用例文件顶部固定序：`vim.g.mapleader=" "` → `require("ue").setup()` → `dofile(cfg.."/lua/config/keymaps.lua")` → 断言。
- 用 `pcall(dofile, ...)` 防止单文件加载错误拖垮整个 run；加载失败本身即一条 FAIL。
- 理由：探针证明这是 headless 下让绑定生效的可靠路径，且不依赖完整插件栈。
- 备选：解析 keymaps.lua 源码静态匹配 `map(...)` → 否决，脆弱且无法验证实际注册结果。

### 决策 2：harness 新增 `get_keymap(mode, lhs)`，规范化 leader 写法

- 实现：调用 `vim.api.nvim_get_keymap(mode)`，把传入 lhs 的 `<leader>`/`<localleader>` 替换为实际 leader（空格），同时把 termcode 形式（`<F5>`/`<C-v>`）用 `nvim_replace_termcodes` 规范后比较，命中返回该 map 表，否则 nil。
- 理由：`nvim_get_keymap` 返回的 lhs 是「已展开 leader、保留 `<F5>` 字面」的混合形态，辅助函数统一这些差异，让用例可用直观写法断言。
- 备选：用例各自处理差异 → 否决，重复且易错。

### 决策 3：命令校验区分 setup 依赖来源

- `commands_spec.lua` 分三组：`require("ue").setup()` 后校验全部 `UE*`；`dofile(keymaps)` 后校验 `Restart`/`RestartDetect`/`UEDefStatus`；`require("workarounds").setup({auto_apply=false})` 后校验 `Workaround*`。
- UE 命令清单从 `lua/ue.lua` + `lua/ue/*.lua` 抽取（69 个），在用例中以显式列表维护（新增命令需同步——这是有意的「冻结清单」约定，防止误删）。
- 理由：明确每组命令的注册前置，避免「命令缺失」误报实为「没调对应 setup」。

### 决策 4：options/autocmd 用例用真实 buffer + autocmd 触发

- options：`dofile(cfg.."/lua/config/options.lua")` 后直接读 `vim.opt.xxx:get()` / `vim.bo`。
- filetype：`vim.filetype.match({ filename = "x.usf" })` 断言 `hlsl`。
- cindent：新建 scratch buffer，设 `vim.bo[buf].filetype = "cpp"`（触发 FileType autocmd），读回 `vim.bo[buf].cindent/smartindent/cinoptions`。
- commentstring：直接调用配置中的回退表逻辑或对 hlsl buffer 设 filetype 后读 `vim.bo.commentstring`。
- 理由：用可观察的运行时状态断言，而非源码静态读取。

### 决策 5：workarounds 完整性用注册表 API + 文件计数交叉验证

- `require("workarounds")` 内部 `list()` 返回发现结果；用例另用 `vim.fn.glob(cfg.."/lua/workarounds/*/*.lua")` 数文件（排除 init/TEMPLATE/README），断言 `#list() >= 文件数`、无 `error` 项、必填字段齐全。
- 理由：既验证发现机制，又用独立来源（文件系统）交叉校验，避免注册表自洽但漏发现。

### 决策 6：utils 行为断言迁移/复用既有 legacy 逻辑

- `ranking`/`pair_picker`/`location` 的断言直接复刻 `scripts/test_ranking_sort.lua`、`test_pair_picker.lua` 中已验证的输入→输出（不依赖 clangd），作为同进程纯函数断言纳入新 `*_spec.lua`，与 legacy 子进程旁路形成「纯函数同进程 + 复杂场景子进程」双覆盖。
- 理由：纯函数无需 fork 子进程，同进程更快且报错定位更直接。

### 决策 7：稳定性用例聚焦幂等与状态隔离

- 重复 require 比较引用相等（Lua `package.loaded` 缓存保证）；`ue.setup()` 重复调用；`ue.config` 多轮 setup/reset；`ue.dap.platforms` 多次 `_reset_for_test`。
- 理由：这些是「改完一处导致别处状态泄漏」最常见的回归点，低成本高价值。

## Risks / Trade-offs

- [keymaps.lua 含 `LazyVim.*` / `Snacks.*` 全局引用，headless 下可能 nil] → 探针已确认 `dofile` 成功（这些引用在函数闭包内，注册阶段不解引用）；若个别 map 的闭包在加载期就调用全局，用 `pcall(dofile)` 兜底并把失败记为 FAIL，便于发现。
- [命令冻结清单需手工维护] → 有意为之，作为「防误删」契约；design/docs 注明新增命令要同步清单。
- [FileType autocmd 依赖 options.lua 已注册 augroup] → 用例先 `dofile(options.lua)` 再触发 buffer，保证 augroup 存在；用独立 augroup 名避免与真实会话冲突（headless 无真实会话）。
- [leader 设置污染全局] → headless 进程一次性，且本就需要 leader=空格；不影响其他用例（各用例自带前置）。
- [新增用例增加运行时长] → 纯函数/查询型断言极快；keymap dofile 一次性；总增量预计 < 1s，可接受。
- [与 legacy 子进程旁路重复覆盖 ranking/pair_picker] → 视为冗余加固而非浪费；纯函数同进程版本报错更直接。

## Migration Plan

1. 扩展 `tests/harness/init.lua`：新增 `assert_contains`、`get_keymap`，导出，跑现有 113 项确认无回归。
2. 逐个新增 `tests/cases/*_spec.lua`（keymaps/commands/options/autocmds/workarounds/fs_proc/ue_paths/ue_goto_behavior/stability），每加一个跑一次 `tests/run.lua` 确认绿。
3. 更新 `docs/testing-regression.md` 覆盖矩阵与新用例说明。
4. 全量跑 `nvim --headless -l tests/run.lua` 与 `scripts/run_regression.ps1`，确认全绿、退出码正确。
5. 制造一个临时失败用例验证 FAIL 输出含新断言信息，验证后删除。
- 回滚：删除新增 `*_spec.lua` 与 harness 增量即可，无运行时改动。

## Open Questions

- 命令冻结清单是否应自动从源码抽取而非手写？倾向首版手写（显式、可控），后续可加一个「源码扫描 vs 清单」的一致性用例作为增强。
- keymap 断言粒度：是否需覆盖全部 85 条？倾向覆盖「高价值 + 易回归」子集（DAP 功能键全模式、leader 各域代表键、Windows 粘贴、gd/gr/gc），全量逐条价值递减，列入 tasks 时给出明确清单。
