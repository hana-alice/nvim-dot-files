# Project Overview · AI 持久化开发入口

> 受众：在本仓持续开发的 AI agent 与人类贡献者。
> 这是 **memory/** 区的入口：稳定项目知识 + 「先读什么」导航。
> 出处优先：本文件只做导航与速查，权威细节在各出处。

## 这是什么

hana-alice 的 Neovim 配置（公开镜像 `hana-alice/nvim`），定位为
**专为 Unreal Engine 5 大型 C++ 工程优化的开发环境**：3 分钟全量索引、
亚 100ms goto-definition、一键 Android headless DAP attach、错误全落盘。

LazyVim 作为**库**而非成品；真正引擎是 `lua/ue.lua`（单文件巨模块）+
`lua/ue/`、`lua/utils/`、`lua/workarounds/`。

## 先读什么（SESSION START 顺序）

新 context 进来、动代码前**按序读**：

1. **根 `AGENTS.md`（单一内容源）** — Claude 与 GPT/Codex 共用的 SESSION START 协议 +
   Definition of Done（完成的硬标准）。根 `CLAUDE.md` 内容仅为 `@AGENTS.md` 导入 stub。
2. **`docs/CONSTRAINTS.md`** — 禁止 / 踩过的坑 / 约束（权威索引）。
3. **本文件** — 项目总览 + 子系统速查。
4. **当前改动目录的本地规则** — 每个主要目录一份 `AGENTS.md`（内容源）+ 一份 `CLAUDE.md`
   （`@AGENTS.md` stub）。Codex 读 `AGENTS.md`；Claude 读 `CLAUDE.md` 并由 stub 展开同一内容。
   目录无本地规则时回落最近祖先目录。

### 读取范围纪律（避免过度扫描）

- SESSION START 前置在**每个新 context 只执行一次**；同一 context 内已经读过且未变化的规则或文档，不因每个小任务重复读取。
- 本地规则只读**实际将修改目录**所适用的最近 `AGENTS.md`；不得遍历、批量读取无关子系统的 AGENTS/spec 文档。
- OpenSpec 只读取并验证当前 change 及其直接影响的主规格；仅在用户要求全局审计或影响面确实无法界定时使用 `openspec validate --all`。
- 全量回归是提交/合并前的**执行门禁**，不等于需要预先阅读全部测试、spec 或 agent 规则；先按实际影响面读取，再按门禁运行测试。
- 只有目标文件、约束或依赖关系发生变化，或出现需要消歧的新证据时，才扩大读取范围。

## 子系统速查

| 子系统 | 位置 | 本地规则（内容源） | 一句话 |
|---|---|---|---|
| UE 引擎中枢 | `lua/ue.lua` + `lua/ue/` | `lua/ue/AGENTS.md` | 索引 / CDB / DAP / 命令注册的中枢 |
| 多实例状态 | `lua/ue/project_state.lua` + `file_lock.lua` | `lua/ue/AGENTS.md` | 进程内选择 + canonical project bucket + 跨进程 writer lease |
| clangd 语义覆盖 | `lua/ue/index/` | `lua/ue/index/AGENTS.md` | current/hot/full controlled BackgroundIndex + generation 单调选择 |
| CDB 流水线 | `lua/ue/cdb/` | `lua/ue/cdb/AGENTS.md` | compile_commands.json 生成/裁剪/注入 |
| DAP 调试 | `lua/ue/dap/` | `lua/ue/dap/AGENTS.md` | codelldb + Android platform 模式 |
| Android device | `lua/utils/android_device.lua` | `lua/utils/AGENTS.md` | 名称+serial picker；当前 Neovim 进程 serial；统一 `adb -s` |
| Android SO 快速迭代 | `lua/ue/targets/android.lua` + `android_windows.lua` + `scripts/ue_android_so_*.ps1` | `lua/ue/targets/AGENTS.md` + `scripts/AGENTS.md` | Windows-only PowerShell compatibility path；root 或已验证的 debuggable app-private transport；不支持 macOS→Android |
| UE target drivers | `lua/ue/targets/` | `lua/ue/targets/AGENTS.md` | Android/IOS/Mac/Win64/Linux 目标策略彼此隔离；`host_operations` matrix + runtime strategy 是组合真相 |
| goto 解析栈 | `lua/utils/ue_goto/` | `lua/utils/ue_goto/AGENTS.md` | proven-TU canonical USR + module AST 唯一 body；非 C++ compatibility fallback |
| 代码搜索 | `lua/utils/code_search/` | `lua/utils/code_search/AGENTS.md` | csearch 亚秒级 grep（兜底，非主路） |
| 核心健康审计 | `lua/utils/core_health*.lua` + `scripts/nvim_core_health.lua` | `lua/utils/AGENTS.md` + `scripts/AGENTS.md` | 隔离、只读、可机器判定的启动/编辑/AST/搜索/clangd/CDB/target plan 证据 |
| 平台驱动 | `lua/utils/platform/` | `lua/utils/platform/AGENTS.md` | 唯一允许做 OS 分支的地方；host 选 shell executable，shell helper 只组 argv/quote |
| workaround 注册表 | `lua/workarounds/` | `lua/workarounds/AGENTS.md` | 上游 bug 补丁，带 frontmatter |
| 配置层 | `lua/config/` | `lua/config/AGENTS.md` | keymaps / options / autocmds / lazy |
| 插件层 | `lua/plugins/` | `lua/plugins/AGENTS.md` | per-plugin setup（snacks-only） |
| 回归测试 | `tests/` | `tests/AGENTS.md` | headless 套件 + 分范围回归映射 |

> 每个主要目录同时有一份 `CLAUDE.md`（内容为 `@AGENTS.md` 导入 stub），供 Claude 读取。

详见 `docs/architecture/overview.md`（数据流 / 平台层 / 构建流水线 / 归属边界）。Android SO
快速部署按能力选择 root 或已验证的 debuggable app-private transport；正常 APK 安装和未 strip
主机符号文件仍是正式流程与调试真相。当前 matrix：macOS 只执行 Mac/IOS，Windows 只执行
Win64/Android，Linux 只执行 Linux；Mac 与 IOS target 独立，Android PowerShell transport 继续
保持 Windows-only；iOS DAP 在 macOS 上通过独立 legacy MobileDevice/debugserver handler 执行，
不 fallback 到 Mac process attach。

## 知识库各区

| 区 | 入口 | 放什么 |
|---|---|---|
| memory | 本文件 | 稳定速查 / 项目总览 / 先读顺序 |
| decisions | `decisions/README.md` | 架构决策记录（ADR）导航 |
| lessons | `lessons/README.md` | 平台怪癖 / 调试硬知识 |
| architecture | `docs/architecture/overview.md` | 架构总览 |

## 开发纪律（完成的硬标准）

权威在根 `AGENTS.md` 的 Definition of Done（Claude 侧经 `CLAUDE.md` 的 `@AGENTS.md` 展开）；摘要：

1. **改完跑回归**：按改动范围跑对应 filter（映射见 `tests/AGENTS.md`），提交前全量。
2. **改完记 changelog**：`docs/changelog.md` 追加一条，Validation 写所跑回归范围。
3. **收尾走 milestone**：semver 触发 + 四件套（见 `docs/CONSTRAINTS.md` §三 C8）。
