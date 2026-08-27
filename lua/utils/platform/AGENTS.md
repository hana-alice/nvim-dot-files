# lua/utils/platform/ — OS 分支唯一收口

> 继承 `../AGENTS.md`（utils）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

平台驱动注册表：`init`（id / is_windows|mac|linux / driver() / 兼容标志）+ 四个具体驱动
`windows` `macos` `linux` `stub`，以及不做 OS 探测的 `shell` argv/quote helper。共享基础接口统一，
宿主专属工具作为可选 capability。
**这是全仓唯一允许做 OS 分支的地方。**

## 专属约定 / 接口契约

- **共享基础同形状**：每个驱动 `id` 与模块名一致，且实现 `shell/shell_entry`、path/open/reveal、
  `default_target`、clangd/lldb/python candidates、`launch_process_plan`、`follow_file_plan` 与 UE
  build/UAT entry（有契约回归 `tests/cases/platform_spec.lua`）。
- **shell 是第三个独立维度**：target 不选择 shell；host driver 用 `shell_entry(kind)` 选择
  `cmd` / `powershell` / `posix` 的可执行文件，`shell.lua` 只负责 quote 与 argv 组装，不探测 OS、
  不决定 executable。macOS/Linux 调用方不得出现 PowerShell executable。
- **专属 capability 不伪装**：`xcrun/security/plutil` 只由 macOS 驱动暴露；PowerShell、
  `debug_log_plan`、`pch_build_plan` 只由 Windows 驱动暴露。其他驱动不得添加返回 `unavailable`
  的同名假方法；调用方以 method presence + resolver 得到结构化 unavailable。
- **其余代码不做 OS 分支**：读 `platform.is_*` 或调 `platform.driver()`，新增 OS 差异**只在此扩**。
- 向后兼容标志 `is_windows/is_mac/is_linux` 为 boolean，`id` 为非空 string——勿改类型。
- 新增共享基础方法 → 四个驱动同步实现（含 `stub`）；新增宿主专属工具 → 只在拥有该工具的
  驱动实现，并补 ownership/缺失 capability 回归。

## 改动 → 必跑回归

`platform`；因被 DAP/CDB 等广泛依赖，**提交前全量**。

## 先读

`../../../docs/plans/2026-05-06-multi-platform-foundation.md`（Phase A 驱动拆分）。

**治理 spec**（可观察行为的权威；与本文冲突时以 spec 为准）：
`../../../openspec/specs/host-platform-driver/spec.md`、
`../../../openspec/specs/platform-tool-resolution/spec.md`、
`../../../openspec/specs/shell-command-planning/spec.md`。
