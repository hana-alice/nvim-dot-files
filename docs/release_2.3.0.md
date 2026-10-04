# hana-alice/nvim 2.3.0 — 搜索、连续阅读与窗口找回

> 版本：2.3.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-04
> 类型：Minor；新增统一窗口入口、完整搜索条件恢复与按需阅读调查。
> 发布流程：本地实施、required-native 门禁、独立复验与文档归档完成；提交/推送按既有收尾授权执行，tag 待明确请求。

## 0. 一句话概括

让找文件、查内容、读引用/调用关系和关闭窗口后的找回形成可以预览、取消、继续的流程。

## 1. 已实现的交付范围

- `<leader>wM` / `UEWorkspace` 找回跨 tab 窗口、隐藏 buffer、搜索结果、任务和日志；关闭窗口不等于停止任务。
- Ctrl-Q 被动保存结果，保留当前构建 quickfix 的 ID、内容、侧栏与跨 tab 阅读位置。
- 文件路径粘贴支持空格、引号、正反斜杠与行/byte-column；Ctrl-Y 分享位置，Alt-V 垂直分屏。
- 搜索有明确范围、类型/路径过滤、命中精度和结束状态；模式无效、零结果与不完整结果分别可见。
- 最近搜索和完整条件历史覆盖 csearch/rg，跨实例锁内合并；文件选择使用独立异步清单，F5 显式刷新。
- 引用/header/Peek 按同一操作 owner 交付；CPP 定义预览仍需编译器身份证明；调用与继承关系按需逐层展开，显式返回原阅读点。
- 手册、速查、主规格、架构与回归映射同步；搜索 facade 与重复 pipe 生命周期收敛到独立模块。

## 2. 验证与未完成范围

最终 required-native 全量：**2835/2835，0 failed，0 skipped，exit 0**。
失败反例、原生交互、静态检查与预算见 [搜索与导航验收](search-navigation-validation.md)，
用户操作见 [使用手册](USER_GUIDE.md)。

本版本的原生工具和 RPC UI 证据来自小型 fixture，不代表完整 UE 工程搜索/索引性能、
物理 GUI 或 Linux 实机验收。SuperUnity 实际二次合并与输入覆盖机制未变更，
完整性能恢复、前批 UE 类型易读显示、真实 Editor 测试、Actor/Component 编译和 Blueprint 仍未完成。
历史 probe 缺原 subject 的三条复发继续保留，fixture 通过不关闭这些记录。

## 3. 本次工作归档

### 2026-10-04 — 让搜索、阅读与关闭窗口后的工作可继续

**Task**

执行已批准的搜索/导航体验规划，增加关闭窗口后的统一找回入口，并按既有授权脱敏、同步、归档、提交和推送。

**Implemented**

- `workspace.lua` 的 `UEWorkspace` / `<leader>wM` 查询现有窗口、隐藏 buffer、qf 历史、任务与日志；`pin()` 被动保存结果，保持当前构建列表和跨 tab 阅读位置。
- `search_picker.lua` 抽取旧 facade 实现；`code_search/location.lua`、`stream_reader.lua`、`search_ui.lua` 统一命中精度、EOF、错误、截断、取消与主循环状态反馈。
- `search_controls.lua` 接通独立 scope/masks；`file_query.lua` 支持路径粘贴、byte-column 往返、Ctrl-Y 复制和 Alt-V 分屏；`search_process.lua` 复用实际 Snacks rg argv/transform。
- `search_recipe.lua`、`search_history_store.lua` 保存完整搜索条件、恢复实际最近搜索、锁内合并多实例写入；`file_inventory.lua` 提供异步独立文件快照与 F5 刷新。
- `ue_goto/reading*.lua`、`relations.lua` 接通守卫后的引用、header、compiler-proven Peek、按需关系调查及显式返回；`ue.lua` 的 GTAGS 入口在副作用前检查 owner。
- 同步使用手册、两份速查、架构、知识库、回归 filter 映射与五份主 spec；没有活跃 OpenSpec change，沿用直接同步主规格的流程。

**Pitfalls / Gotchas**

- pin 不能淘汰正在阅读的最旧 qf，也不能通过 `chistory` 重置其他 tab 的 qf view；修复用局部身份守卫，不加全局 cursor guardian。
- 搜索完成须等待两条 pipe EOF；模式/范围变化即使 query 相同也属于新请求；fast-event 状态更新先调度到主循环再校验 generation。
- 恢复历史不接受未经 allowlist 的 rg inline 执行参数；同名路径身份遵循实际 host driver。
- 关系展开按 node 取消；render location 与 provider opaque item 分离；确认 close 后再次检查源、目标和新意图；CPP extension/context chooser 保留 compiler proof。

**Validation**

- 最终 required-native 全量 **2835/2835，0 failed，0 skipped，exit 0**，含 legacy；52 个源码/fixture SHA256 在测试期间一致。
- 独立实现与增量审查 APPROVED；49 个改动 Lua AST、28 个新增 Lua StyLua、3 个 Python AST、五份主 spec strict 与 diff check 通过。
- 搜索原生 12 阶段、搜索交互 14 组、导航原生 30 场景及 A11 完整旅程通过；旧生命周期六例与原异步 references 断言保留，详情见验收页。
- 最终 66 文件全文、author/committer metadata 与提交说明的私有 denylist/通用 secret 扫描 exit 0；正常 commit/ref/push hooks 保持启用。
- 已完成小范围与原生交互证据、失败反例、预算和实测边界见 [搜索与导航验收](search-navigation-validation.md)。
- 已直接同步 `task-management`、`ue-code-search`、`editor-behavior-regression`、`cpp-contextual-definition-navigation`、`multi-instance-state-isolation` 的重要选型。

**Follow-ups**

- 大型 UE 工程搜索/文件清单/关系图耗时与 RSS、完整 SuperUnity 性能、物理 GUI 与前批 UE 类型/Editor/Blueprint 验收继续保留。
- 本批版本归档与提交/公开分支推送按既有授权执行；tag 待明确请求。
