# hana-alice/nvim 2.12.2 — 全局 Scratch 与 picker 一次 Esc 取消

> 版本：2.12.2
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-27
> 类型：Patch；同步已说明的 Scratch/picker 交互，并保留工作区失败诊断。
> 发布流程：按用户授权同步、脱敏归档、拉取/rebase、提交并推送；tag 待明确请求。

## 1. 本次交付范围

- Scratch 跨项目与分支共享 Markdown 笔记，count 前缀仍选择独立笔记；开启窗口软折行，旧历史保持可用。
- 通用 picker 输入窗口在插入或普通模式下，按一次 Esc 即取消。
- 工作区窗口复用回归保留有界分派栈与等待结果，原有行为断言不变；不将诊断采样当作根因证明。
- 新增两个实际 Snacks 交互回归，覆盖共享、自动保存、计数、旧历史、软折行与两种输入模式取消；持久化写入隔离到测试目录。
- 同步编辑器行为主规格，与现有用户手册对齐。

## 2. 验证与剩余范围

提交前串行全量 `nvim --headless -l tests/run.lua`：**4402/4402 通过、0 失败、2 SKIP**。
两项跳过：未提供私有 GTAGS 原生证明输入；当前宿主具备 PCH 能力，不适用不支持场景。

定向回归通过：`review_editor` 11/11、`ide_workspace_reuse` 10/10、`smoke` 19/19、
`commands` 167/167、`keymaps` 85/85，共 292/292。三个改动 Lua 文件的 AST 检查及编辑器行为
主规格 strict 校验通过；独立代码与隐私复审通过，私有及通用扫描通过。
归档后 `structure` 85/85 通过，编辑器行为主规格再次通过 strict 校验。

未独立实测 Git 分支切换；分支共享已核对已安装 Snacks 的文件键实现与本次配置。

工作区交接延迟的具体根因仍待独立复现与验证；本次只保留诊断，不声称已修复该问题。
本次不迁移、删除或合并已有 Scratch 文件，历史笔记仍可从原入口选择。
原始运行日志和本机调用栈保留在本地，公开归档只记录通用行为与验证结果。

## 3. 本次工作归档

### 2026-10-27 — 全局 Scratch 与 picker 一次 Esc 取消

**Task**
- 收尾本地 Snacks 配置与工作区回归诊断改动，同步规格、验证后归档提交。

**Implemented**
- `lua/plugins/snacks.lua`：Scratch 不再按 cwd/branch 分割，保留 count 独立笔记；启用窗口软折行。
- 通用 picker 输入窗口的 Esc 在插入与普通模式下均直接 cancel。
- `tests/cases/ide_workspace_reuse_spec.lua` 保存有界分派调用栈与等待结果，保留原有布局、光标和文档断言。
- `tests/cases/review_editor_spec.lua` 新增实际 Snacks 交互回归，覆盖共享与自动保存、count 分离、旧历史、软折行和两种输入模式取消；文件写入隔离到测试目录。
- 同步 `openspec/specs/editor-behavior-regression/spec.md`；既有用户手册已说明这组交互，无需重复修改。

**Pitfalls / Gotchas**
- 分派栈与等待结果只是诊断证据，不能据此断言 typeahead 饥饿或 macOS CI 失败根因已确定。
- Scratch 共享只改变默认文件选择，不迁移、删除或合并旧笔记；旧历史继续可选。

**Validation**
- 定向回归通过：`review_editor` 11/11、`ide_workspace_reuse` 10/10、`smoke` 19/19、`commands` 167/167、`keymaps` 85/85，共 292/292。
- 三个改动 Lua 文件的 AST 全局变量检查通过；编辑器行为主规格 strict 校验通过。
- 提交前串行全量 `nvim --headless -l tests/run.lua`：4402/4402，零失败、2 SKIP（私有 GTAGS 原生证明输入未提供；当前宿主具备 PCH 能力，不适用不支持场景）。
- 独立代码与隐私复审通过；私有及通用扫描通过。
- 归档后 `structure` 85/85 通过，编辑器行为主规格再次通过 strict 校验。

**Follow-ups**
- 工作区交接延迟的具体根因仍待独立复现与验证。
- 未独立实测 Git 分支切换；分支共享依据已安装 Snacks 的文件键实现与本次 `branch = false` 配置核对。
