# lua/utils/ — 通用工具模块

> 继承 `../AGENTS.md`（lua 总规则）。只写增量。

## 用途

跨子系统复用的工具：`platform`（OS 分支唯一收口）、`log`（旋转日志）、`lsp_fallback`（gd/gr 兜底）、
`ue_goto/`（goto 解析栈）、`code_search/`（csearch）、`ue_paths`（路径分类）、`sidebar`/`cheatsheet`/
`restart`/`recent_projects`/`async_launcher`/`ue_watch`/`ue_launch`/`ue_logs`/`dirty_files`/
`task_registry`（后台任务列出/停止）、`android_device`（当前 Neovim 进程的 ADB serial 选择与路由）等。

## 专属约定

- **OS 分支只在 `platform/`**：其余 utils 读 `platform.is_*` 或 `platform.driver()`，不自己分支。→ 见 `platform/AGENTS.md`
- **Android 设备选择只走 `android_device.lua`**：新流程复用其 picker、进程内
  `vim.g.ue_android_device_serial` 与 `adb_args`；`vim.g` 不跨 Neovim 实例。`adb devices -l`
  发现命令及 DAP 活跃 session 内捕获 serial 后的生命周期命令除外。
- 写 `stdpath` 或 project cache 前先声明 ownership：纯诊断日志按 PID 隔离；跨进程集合用
  `ue.file_lock` 下重读+merge+原子替换；独立 key 优先一 key 一原子文件。
- **LSP 行为只走 `lsp_fallback.lua`**，不全局覆盖 `vim.lsp.handlers`。→ P3
- 纯函数模块（`ue_paths`、`ue_goto/location|semantic_context|semantic_protocol`）有行为回归，改契约前看断言。
- 单一职责、小文件：新功能优先新模块而非堆进现有大文件。
- **新增后台 job（`jobstart`/`vim.system`/`termopen`）接入 `task_registry`**：唯一允许的接入是在 job
  创建语句**之后**加一行 `pcall(require("utils.task_registry").register, { name, group, kind="job"|"system", handle })`。
  **不要**在 `on_exit`/完成回调里回写状态——状态是派生量，由 `task_registry.status()` 实时查句柄得出
  （派生状态架构从结构上消除竞态，见 change `ue-task-manager` design.md）。短命 `detach=true` 的
  `xdg-open`/`open`/`cmd start` 类不登记。DAP 会话不登记（K5）。

## 改动 → 必跑回归

- 改 `ue_goto/**` → `cpp_semantic_context` `cpp_semantic_client` `cpp_semantic_sidecar`
  `ue_goto_behavior` `utils`
- 改 `code_search/**` / `ue_paths.lua` → `ue_goto_behavior` `ue_paths` `utils`
- 改 `platform/**` → `platform`（另见子目录 `AGENTS.md`）
- 改被广泛复用的 helper（如 `log`、`ue_paths`）→ 提交前全量

## 先读

`../../docs/architecture-symbol-resolution.md`、`../../docs/architecture/overview.md` §5。

**治理 spec**（可观察行为的权威；与本文冲突时以 spec 为准）：
`../../openspec/specs/probe-feedback-loop/spec.md`、
`../../openspec/specs/task-management/spec.md`、
`../../openspec/specs/global-android-device-selection/spec.md`、
`../../openspec/specs/notification-history/spec.md`。
