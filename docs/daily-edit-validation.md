# 日常编辑体验验收（2026-10-03）

## report-first 处置

开始改动前读取了真实 state 目录的 `ue_probes.json`。语义性能与导航 topic 中，
`provider|complete`、`invalid-semantic-context|entity|identity-missing|complete`、
`unavailable|context|semantic-tu-unavailable|complete` 的失败计数超过旧处置计数。
本次记录为**不处理、继续待验证**：这些属于编译数据库/语义导航 owner，历史记录缺少
可重现的具体 subject，不能靠编辑体验改动或后续成功采样证明修复；全工程索引性能也仍未验收。
既有 dirty flood 和 warm 性能记录沿用历史 deferred 状态。不改真实证据或处置计数。

## 启动摘要取舍

`probe-feedback-loop` 第一条要求任何未读证据启动时主动提示，包含成功采样。
因此保留每会话必要摘要，不实现跨会话“只有首次新失败才提示”的筛选。
默认改为状态栏可见的维护者诊断摘要；可切回 INFO 通知，不能静默关闭 report-first。

## 验证

上一会话的独立全量入口 `nvim --headless -l tests/run.lua`：**2510/2510 passed，0 failed，0 skipped**。
本次恢复会话修复审查发现后，设置 `NVIM_TEST_REQUIRE_NATIVE=1` 重跑同一全量入口：
**2517/2517 passed，0 failed，0 skipped，退出码 0**。下表的 `unsaved` 为本次组合回归；
其他既有定向数字保留其原验证范围，最终全量覆盖当前全部实现。
定向回归另行执行，结果如下（每项均 0 failed / 0 skipped）：

| filter | 通过数 | 证明范围 |
|---|---:|---|
| `probe` | 58/58 | 低打扰呈现、report-first、展示与处置分离、原有持久化 |
| `ue_config` | 11/11 | schema 合并与默认值 |
| `cpp_format` | 4/4 | 有/无工程配置、菜单取消与过期选区、真实 conform/clang-format 和 UE 模板 |
| `unsaved` | 13/13 | 事件缓存、隐藏 API 修改与 undo、删除/卸载、真实写盘、保存失败、原生外部 UI 确认及变化守卫、只读状态栏 |
| `daily_edit` | 1/1 | 真实配置 UIEnter/VeryLazy 后 cf/qq/uh、命令及 autoformat=false |
| `keymaps` | 64/64 | 既有与改动键位 |
| `commands` | 129/129 | 用户命令与冻结清单 |
| `cheatsheet` | 170/170 | 两个速查表 surface |
| `review_editor` | 9/9 | 交互与工具链策略 |
| `smoke` | 19/19 | 模块与命令加载 |
| `android_device` / `android_ide` / `ue_context` | 17/17、45/45、14/14 | hub 影响范围 |
| `dap` | 237/237 | hub 所引用的调试动作与原有调试契约 |
| `ue_api` / `ue_platform_boundary` | 66/66、17/17 | facade 公共 API 与 owner 边界 |
| `stability` | 26/26 | 幂等、资源与行数门禁 |
| `structure` | 78/78 | 文档/规则/治理 spec 引用 |

AST bare-globals lint：11 个改动 Lua 文件通过。新增 Lua 文件经已有 StyLua 格式化且
`--check` 通过；Python 实测工具 `py_compile` 通过。对本次 28 个改动文件的通用
`scripts/check_secrets.sh` 扫描通过；这不替代未来提交/推送时的本机专属 denylist 门禁。
`git diff --check` 通过。`lua/ue.lua` 为 **10346 行**，低于冻结上限 10562；新增文件均少于 800 行。

内联提示证据见 [实测报告](evidence/daily-edit-inlay.md)。它挂有真实 Neovim 外部 UI 管道，
证明 grid 绘制与提示可见性；未测物理 GUI/GPU 帧率，不能泛化为真实 UE 全工程性能保证。

## 已完成与未完成范围

1. 启动默认不弹内部日志，以状态栏维护诊断提示，配置可切 INFO。按 report-first 保留每会话
   未读摘要；用户提出的跨会话“只提示一次新失败”与规格冲突，因此没有实现。
2. C-family 的 `<leader>cf` 缺配置时跳过并提供显式 UE 风格选项，自动格式化仍关闭。
   模板不是官方 Epic 配置，clang-format 选区有语法扩展可能；真实 UE 全工程宏布局未验收。
3. 6007 行 fixture + 真实 clangd + UI grid 实测已完成，保留默认内联提示；实际 UE 头/PCH/CDB、
   索引高负载和 Neovide GPU 未验证。
4. `未保存:N` 缓存和 `<leader>qq` / `:UEQuit` 的全部文件列表、保存/查看/放弃选项已完成。
   原配置实测 `confirm=true`，逐文件确认但没有集中列表。直接 `:q` / `:qa` / GUI 退出仍沿用原生
   路径；`QuitPre` 实测不能可靠区分 qa/qa!，未添加会干扰强制退出的全局拦截。

**被证伪的判断留底**：单次进入 buffer 后计数为 1 不能证明 BufModifiedSet 能覆盖全部编辑；
BufEnter 会掩盖遗漏。隐藏 API 修改要用缓冲区订阅，直接 option 赋值要用 OptionSet，undo 还要
在 on_lines 结束后单次调度校正。相关用例现已覆盖这些实际路径。

## 改动文件

| 范围 | 文件 |
|---|---|
| 启动诊断 | `init.lua`、`lua/utils/probe.lua`、`lua/ue/config.lua` |
| 编辑与状态栏 | `lua/utils/cpp_format.lua`、`lua/utils/unsaved.lua`、`lua/plugins/ue.lua`、`lua/plugins/statusline.lua`、`lua/config/keymaps.lua`、`lua/ue.lua` |
| 入口发现 | `lua/utils/ue_hub.lua`、`lua/utils/cheatsheet.lua`、`docs/ue_lazyvim_cheatsheet.md`、`docs/USER_GUIDE.md` |
| 回归 | `tests/cases/cpp_format_spec.lua`、`tests/cases/unsaved_spec.lua`、`tests/cases/unsaved_confirm_spec.lua`、`tests/cases/daily_edit_spec.lua`、`tests/cases/probe_spec.lua`、`tests/cases/commands_spec.lua` |
| 工具与证据 | `tools/measure_inlay_hints.py`、`docs/epic.clang-format`、`docs/evidence/daily-edit-inlay.md`、本文 |
| 治理与记录 | `tests/AGENTS.md`、`docs/testing-regression.md`、`memory/project_overview.md`、`docs/architecture/overview.md`、`openspec/specs/probe-feedback-loop/spec.md`、`openspec/specs/editor-behavior-regression/spec.md`、`docs/changelog.md`、`docs/release_2.1.0.md` |

## 恢复会话的独立审查

独立审查另行复现并修复了三项缺陷，原全量通过记录不能证明这些遗漏路径正确：

- `:bdelete!` / API unload 后列表为空但计数残留 1：新用例在原实现先红 6/7，修复后绿 7/7。
  BufDelete 既发生于卸载也发生于取消列出，在事件结束后校正，保留加载中的隐藏修改。
- 中文确认助记键不能正常选择放弃：保留中文文案，采用 ASCII `y/n`，回车仍默认取消。
- 确认等待期间新增、编辑或重命名文件仍可能执行 `qa!`：新用例先红 7/8，修复后绿 8/8。
  确认后重新核对全部脏文件的 ID、名称和 changedtick，变化即取消退出并保留修改。

实际修改涉及 `lua/utils/unsaved.lua`、`tests/cases/unsaved_spec.lua`、USER_GUIDE 与编辑器 spec；
`tests/cases/unsaved_confirm_spec.lua` 另用真实 ext_linegrid UI 与 `nvim_input` 验证了 5 条路径：
`y` 放弃、`n` 取消、回车默认取消，以及确认等待期间的真实 timer/RPC 编辑后 `y` 不退出。
组合 `unsaved` filter **13/13 passed，0 failed，0 skipped**；未替换原生 confirm，
只捕获 `qa!` 保留断言状态，不将其表述为实际进程退出或物理前端验收。
标准库 UI 助手复用现有测量工具，超时只清理本测试拥有的子进程。
本次另重验 `cpp_format` 4/4、`daily_edit` 1/1，改动 Lua AST lint 11 个文件、
新增 Lua 6 个文件的 StyLua 检查和 Python 测量工具编译均通过。

架构导航已补充日常编辑 owner。历史 30 条记录归档至 [v2.1.0](release_2.1.0.md)，
原验证范围和未完成事项原样保留；提交、推送继续经过本机隐私门禁，tag 仍待明确授权。
未增加依赖；未跟踪的 `.nvimlog` 未纳入交付。
