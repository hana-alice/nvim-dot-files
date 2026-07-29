# Architecture Overview · 架构总览

> **docs/architecture/** 区：项目架构的高层视图。
> 出处优先：本文件给「全景 + 归属边界」，深度细节在各专题文档，不复制原文。
> 关联：`docs/architecture-symbol-resolution.md`（符号解析栈）、
> `docs/architecture-vs-lazyvim.md`（相对 LazyVim 的增量）、`docs/TOOLING.md`（工具链）。

## 0. 一句话

把一个万级 cpp 文件的 UE5 工程，塞进一个 24 小时跑、无人值守也不静默挂的 Neovim 开发环境：
3 分钟全量索引、亚 100ms goto-definition、一键 Android headless DAP、错误全落盘。

## 1. 主要子系统（major subsystems）

| 子系统 | 代码 | 职责 | 归属边界 |
|---|---|---|---|
| UE 引擎中枢 | `lua/ue.lua` + `lua/ue/` | 索引 / CDB / DAP / 命令注册总入口 | 公共 API 挂 `M.*`；命令在 `ue.setup()` 注册 |
| CDB 流水线 | `lua/ue/cdb/` | compile_commands.json 生成/裁剪/shader/inject | 纯函数 + 子进程；写前 skip-if-unchanged |
| 配置 schema | `lua/ue/config.lua` | `index/context/clangd/dap/cdb` 默认值 + override | `get/setup/options/reset_for_test` |
| 核心工具 | `lua/ue/core/` | fs / proc 纯函数 | 无副作用，可 headless 断言 |
| DAP 调试 | `lua/ue/dap/` | codelldb 适配 + 各平台 attach/launch | `platforms` 注册表是唯一 dispatch seam |
| Android device | `lua/utils/android_device.lua` | `adb devices -l` 枚举、会话级 serial 选择、`adb -s` argv | `vim.g.ue_android_device_serial` 是交互操作真相；活跃任务捕获 serial |
| 符号解析栈 | `lua/utils/ue_goto/` + `lsp_fallback.lua` | gd/gr 的 5 层 fallback | clangd 权威；TS 只省调用；csearch/gtags 兜底 |
| 代码搜索 | `lua/utils/code_search/` | csearch 亚秒级 grep | 兜底非主路；clangd MISS 时才用 |
| 平台驱动 | `lua/utils/platform/` | OS 分支唯一收口 | 四驱动同接口；其余代码不做 OS 分支 |
| workaround 注册表 | `lua/workarounds/` | 上游 bug 隔离补丁 | 带 frontmatter；`:WorkaroundList` 可见 |
| 配置层 | `lua/config/` | keymaps/options/autocmds/lazy | LazyVim 自动加载，勿在 init 重复 require |
| 插件层 | `lua/plugins/` | per-plugin setup | snacks-only；不集成 copilot |

## 2. 数据流（data flow）

- **索引/CDB**：`:UEPrepare` → UBT `-SkipBuild` 取编译参数 → `ue/cdb/*` 生成/裁剪/inject
  compile_commands.json → cindex 建 csearch 索引 → clangd reload。全程 async + 进度 UI。
- **goto-definition**：`gd` → `treesitter 早退判定` → `cache(~70% 命中)` → `clangd LSP(权威)`
  → `csearch` → `gtags`，逐层 fall-through，最终兜底 toast「no def」。详见
  `docs/architecture-symbol-resolution.md`。
- **Android device**：`<Space>uA` / 首次 Android 操作 → `utils.android_device` 异步执行
  `adb devices -l` → picker 展示名称 + serial → `vim.g.ue_android_device_serial`；install / launch /
  logcat / 新 DAP session 捕获该值并统一形成 `adb -s <serial> ...`。
- **DAP**：`UEDAP*` 命令 → `ue.dap.platforms` 按当前平台 dispatch → 具体平台 `attach/launch`
  → codelldb（Win64/Android）。Android 走 platform 模式 + serial connect URL；K30 URL 与本次
  session 捕获的 ADB serial 必须一致，切换全局值不改变活跃 session 的 poll/cleanup。

## 3. 平台分层（platform layers）

- `lua/utils/platform/`：`windows/macos/linux/stub` 四驱动，统一接口（shell / open_path /
  cmd_quote / default_*_paths）。**这是唯一允许 OS 分支的地方**——其余代码读 `platform.is_*`
  或调 `driver()`，不自己分支。
- DAP 平台层 `lua/ue/dap/<platform>.lua`（win64/mac/linux/ios/android）经 `platforms` 注册表接入。

## 4. 构建流水线（build pipeline）

- 外部工具链版本钉死见 `docs/CONSTRAINTS.md §三 C1`（clangd/LLVM 22.1.x、codelldb 1.12.2、
  NDK lldb-server、Neovim 0.10+）。
- CDB 生成器（`tools/*.py` + `lua/ue/cdb/*`）：super-unity / prune / inject，写前比对跳过。
- csearch 索引：`tools/cindex-uefilter`（Go fork）`-files-from` 干净建索引。
- 端到端搭建流程见 `docs/skills/ue-ide-bootstrap.md`。

## 5. 关键归属边界（ownership boundaries）

- **OS 分支**只在 `lua/utils/platform/`。
- **Android 设备选择**只在 `lua/utils/android_device.lua`；调用点消费 selected serial，
  活跃长流程只消费启动时捕获的 serial，禁止中途重读 global 后跨设备。
- **LSP 行为改动**只走 `lua/utils/lsp_fallback.lua` 或 `lua/workarounds/clangd/*`（禁全局 handler 覆盖）。
- **上游 bug 补丁**只进 `lua/workarounds/<scope>/<name>.lua`（禁 inline monkey-patch）。
- **goto 精度**只信 clangd（TS 不给答案，csearch/gtags 只兜底）。
- **启动顺序**固定，见 `docs/CONSTRAINTS.md §三 C3` 与 `init.lua`。

## 6. 开发纪律入口

完成的硬标准在根 `CLAUDE.md` 的 Definition of Done（回归 / changelog / milestone）。
进入任意子系统目录先读其 `CLAUDE.md`（无则回落最近祖先）。
