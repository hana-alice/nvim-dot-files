# hana-alice/nvim 1.0.0 — UE5 工程师的 Neovim 定制报告

> 版本: 1.0.0
> 仓库: https://github.com/hana-alice/nvim
> 平台: Windows 11 + Neovide GUI (主) / WSL2 (辅)
> 基底: LazyVim + lazy.nvim + blink.cmp + snacks.nvim + nvim-dap
> 定位: **专为 Unreal Engine 5 大型 C++ 工程优化的开发环境**
> 报告日期: 2026-04-24

---

## 0. 一句话概括

把一个 11593 个 cpp 文件、单 CDB 解压后 757 个 -D 宏每条目、单次冷索引动辄 17 分钟以上、
goto-definition 经常 8 秒不响应、Android 真机调试要靠手动起 lldb-server 的 UE5 工程，
塞进一个 24 小时跑、无人值守也不会静默挂掉的 Neovim 开发环境里。

3 分钟全量索引、亚 100ms goto-definition、一键 Android headless attach、
所有错误都会落盘 — 这是 1.0.0 的交付承诺。

---

## 1. 仓库结构与设计原则

```
nvim/
├── init.lua
├── lua/
│   ├── ue.lua                  # UE5 集成中枢 (单文件 ~7500 行, 故意 monolithic)
│   ├── ue/dap.lua              # UE 专用 DAP adapter (codelldb wrapper)
│   ├── utils/
│   │   ├── platform.lua        # 唯一允许做 OS 分支的地方
│   │   ├── log.lua             # 旋转式调试日志 (v2)
│   │   ├── ue_goto/            # 单一职责的 goto-definition jumper 子系统
│   │   ├── code_search/        # csearch 集成
│   │   ├── recent_projects.lua
│   │   └── lsp_fallback.lua
│   ├── workarounds/            # 物理隔离的第三方 plugin 补丁目录
│   │   ├── snacks/             # 6 个 picker 相关 patch
│   │   ├── lazyvim/
│   │   └── neovide/
│   ├── plugins/                # lazy.nvim 插件 spec
│   ├── theme.lua / highlights.lua
│   └── config/
├── tools/                      # Python: clangd 索引 pipeline
│   ├── inject_definitions_to_cdb.py
│   ├── build_unity_cdb.py
│   └── build_clangd_index.py
├── scripts/                    # PowerShell: 一键全量重跑
│   ├── run_unity_full.ps1
│   └── test_log.lua
└── docs/
    ├── ue_lazyvim_cheatsheet.md
    └── release_1.0.0.md        # 本文件
```

设计原则:

1. **monolithic 优先**:  ue.lua 单文件 ~7500 行，不强行拆分。理由是 UE 的 build/index/run/debug
   流程之间互相 leak 状态 (project root, 配置, 通知 channel, lock 文件)，拆分后会出现
   "改 A 模块得动 B 模块 hash" 的循环依赖。规则写在 skill ue-lua-engine-only-maintenance。

2. **isolated workarounds**: lua/workarounds/ 是一个物理隔离目录，**只**装"对第三方插件的
   monkey-patch / 临时 fix"。每个 patch 一个文件 + 一段触发条件注释。upstream 修了就删
   一个文件，绝对不会污染主 config。

3. **OS 分支只在 utils/platform.lua**: 任何地方写 `vim.fn.has('win32')` 都视为反模式。
   全部走 `require('utils.platform').is_windows()`。

4. **改键 = 改两份**: lua/config/keymaps.lua 和 docs/ue_lazyvim_cheatsheet.md 强制同步，
   规则写在 skill lazyvim-keymap-dedup-and-cheatsheet-sync。

5. **错误必须落盘**: 见第 5 节，旋转日志架在 vim.notify ERROR 之上，不静默 swallow。

6. **跨平台 Python 的 PYTHONHOME 必清**: vim.system 调 Python 时 strip PYTHONHOME/PYTHONPATH，
   因为父进程可能由 uv-managed Python 启动 (3.11)，但 Win 系统 Python 是 3.12，
   不清就 SRE module mismatch 报错。

---

## 2. UE 集成的核心特性

### 2.1 命令面 (38 个 :UE* 命令)

按用途分组:

**Build / Launch / Install (Android)**
```
:UEBuild / :UEBuildAndroid    # UnrealBuildTool 调用, 进度通知, 错误集中
:UEInstallAndroid             # adb install
:UELaunch                     # adb shell am start
:UELogToggle / :UEDebugLogToggle  # adb logcat 嵌入式 buffer
```

**索引 (clangd)**
```
:UEPrepare / :UEPrepareSync   # 生成 CDB (调 GenerateClangDatabase)
:UEExportCompileCommands      # 同上别名
:UEGenerateFromRSP            # 从 .obj.rsp 反推 CDB
:UEIndexHot                   # 热索引 (~13 modules, 约 2 min 目标)
:UEIndexFull                  # 全量索引 (super-unity 3 min)
:UEIndexNow / :UEIndexStatus  # 查状态
:UEBuildPCH                   # 预编译 SharedPCH
:UEClearCache                 # 清缓存
```

**Android headless 调试 (UE 1.0 招牌特性)**
```
:UEAndroidDAPLaunch           # 全自动: adb push lldb-server -> 启动 -> attach
:UEAndroidDAPAttach           # 已运行进程的 attach
:UEAndroidDAPContinue / Pause
:UEAndroidDAPStepOver / In / Out
:UEAndroidDAPToggleBreakpoint
:UEAndroidDAPToggleUI         # nvim-dap-ui 切换
:UEAndroidDAPREPL             # lldb 命令行
:UEDAPDiag                    # 整套 attach 链路诊断
:UEResetLayout                # DAP UI 错乱时一键重置
```

**项目 / 配置**
```
:UEPaths / :UESetProject / :UESetPlatform / :UESetAndroidPackage
:UECheatsheet / :UECheatsheetEdit
:UEGrepGroupingToggle / :UEGrepTraceToggle / :UEGrepTraceShow / :UEGrepDiagDump
```

### 2.2 关键架构决策

- **DAP 调试器** 不直接暴露给 ue.lua —— 走 `require('ue.dap').<api>` 的 M 表，
  这样 progress_update 这类 cross-cutting concerns 改一处覆盖 12+ 个 attach/launch 错误点
  (commit fea71ba 利用了这个设计，加了一行就把日志覆盖到全部 DAP 错误路径)。

- **monolithic ue.lua** 的内部分区靠注释带和 INDEX_FN 等命名前缀做软边界。

---

## 3. clangd / 索引子系统 — 1.0 的真正硬骨头

这一节是整个 1.0 投入产出比最高的部分，单独展开。

### 3.1 问题规模

UE5 工程 (UnrealEngine official):
- 11593 个 cpp 翻译单元
- 单条 CDB entry 在补完 -D 后达到 757 个宏定义
- SharedPCH 11 个，每个 PCH 覆盖 38–384 个 cpp
- 24 物理核 / 94GB RAM 机器上，naive `clangd-indexer --executor=all-TUs --concurrency=24`
  会 OOM 反弹 (16-core 的实测耗时反而比 12-core 多 6 分钟)

### 3.2 性能成果 (1.0 终态)

| 阶段                                  | wall time | idx 大小  | 完整度  |
|---------------------------------------|-----------|----------|---------|
| 起点 baseline (8-core, naive)         | 23.1 min  | 432 MB   | 90.4%   |
| 12-core unity                         | 17.1 min  | 432 MB   | 90.4%   |
| **super-unity 50/8c (1.0 默认全量)**  | **3.0 min** | **434 MB** | **≥90.4%** |
| Hot 增量 (13 modules, F 任务待实测)    | 目标 ≤2 min | -      | 局部     |

**全量加速比 7.7×, CPU 使用率仅 12% — 用 12% 的 CPU 时间得到 ≥ 之前完整度的索引。**

### 3.3 4 步 idempotent pipeline

`scripts/run_unity_full.ps1` 是入口，4 步全部可重复跑:

```
slim   ->  CDB 去除 ThirdParty / Generated 噪音
pch    ->  预编译 SharedPCH
unify  ->  build_unity_cdb.py 把 11593 cpp 折成 23 super-unity TU
prune  ->  inject_definitions_to_cdb.py 按 module 注入 -D / -I (757 个宏/entry)
```

### 3.4 super-unity 架构

每个 super-unity TU 的内容形如:

```cpp
// ---- ModuleA (8 API macros) ----
#undef MODULEA_API
#define MODULEA_API DLLEXPORT
#include ".../Module.ModuleA.cpp"
// ---- ModuleB (12 API macros) ----
#undef MODULEB_API
#define MODULEB_API DLLEXPORT
#include ".../Module.ModuleB.cpp"
...
```

为什么这样写 (3 次迭代血泪):
- v1: chunk[0] args → -I 缺，0% 索引成功
- v2: union -I → _API 宏冲突 (`unknown type name BUILDSETTINGS_API`)
- v3: union -I + per-module #undef/#define _API 块 → 成功

CDB args = ALL chunk members 的 -I 并集 (Public/Private/Classes/Internal/UHT 全集)，
-D 用 chunk[0] 的 (其他 module 的 _API 已被 source 内 #define 覆盖)。

### 3.5 路过的所有坑 (沉淀为 skill)

- `clangd-indexer-ue-defs-injection` — UE 的 -D 宏注入流程
- `ue-cdb-missing-new-files` — CDB 漏新文件诊断
- `ue-cdb-response-file-expansion` — UBT 的 .obj.rsp 展开
- `clangd-pch-precompile` — PCH 预编译
- `clangd-restart-after-index-rebuild` — index 完事重启 clangd 的静默失败反模式
- `clangd-instant-goto-disambiguation` — sub-100ms goto-def 架构
- `racing-goto-definition` — racing-pattern goto
- `clangd-at-definition-bail` — 光标已在定义处时 early-bail
- `treesitter-pre-lsp-early-bail` — treesitter 先排除"LSP 也答不上"的位置

特别提一下 **clangd-indexer 不读 hot.json 的 stage trick**:
clangd-indexer 的 positional arg 是 source filter 不是 CDB —— 它沿 cwd 向上找
compile_commands.json。所以"传别的 cdb 文件"这种做法全部失效，**唯一**可靠 workaround
是 stage subset 到独立目录 + cwd=stage_dir。这条 pitfall 第 19 条已写入 sessions 档案。

### 3.6 编辑期延迟优化 (ue_goto 子系统)

`utils/ue_goto/` 把 goto-definition 拆成 6 个单一职责模块:
```
provider.lua   # 收集候选 (LSP + treesitter + ctags)
ranking.lua    # UE 启发式排序 (ImplFile > HeaderFile, 同 module > 跨 module)
syntax_filter.lua  # treesitter 排除注释 / 宏体
symbol.lua / location.lua  # 数据结构
pair_picker.lua  # snacks picker 二选一 UI
jumper.lua     # 单一入口
ui.lua
```

效果: cold preamble 9.58s 也能撑过去，因为 jumper 在 LSP 没 ready 时
**先**走 treesitter 局部分析 + ctags fallback，绝不让用户面对 8 秒的"卡死"。

---

## 4. Headless / Android DAP 子系统

### 4.1 问题域

UE5 Android 调试在传统 IDE 里 (Android Studio / VS Android workload) 痛点:
- 必须先把 lldb-server push 到设备指定路径
- 必须知道 abi (arm64-v8a / armeabi-v7a) 和 API level
- 必须 adb forward 端口
- attach 时 process pid 还得自己 `adb shell pidof com.example.mygame`
- ASLR offset 算错就断点全失效

### 4.2 1.0 实现

`lua/ue/dap.lua` 在 codelldb 上做了一层 wrapper:

```
:UEAndroidDAPLaunch 单步流程:
  1. 检测当前 :UESetAndroidPackage 设置的包名
  2. adb shell getprop 拿 abi + API level
  3. 选对应 lldb-server, adb push 到 /data/local/tmp/
  4. adb shell chmod, 起 lldb-server -- listen :12345
  5. adb forward tcp:12345 tcp:12345
  6. 等进程起来或 attach 已运行 pid
  7. codelldb attach + ASLR offset 自动算
  8. nvim-dap-ui 自动布局
  9. 任何一步失败 -> log.notify_error("ue.dap", ...) 落盘 + 屏幕通知
```

`progress_update(msg, level)` 是这一层的核心 cross-cutting 函数 —— 同时
把消息推到 fidget 进度条 + 落盘 nvim-debug.log + ERROR 时 vim.notify。
v2 logger 改了这一个函数就把全部 12 个 attach/launch 错误点都接入了日志系统
(commit fea71ba)。

### 4.3 诊断命令

`:UEDAPDiag` 一次性输出:
- adb 是否在 PATH
- 当前 connected device list
- 包名解析结果
- lldb-server 是否已 push, 大小是否匹配
- 端口是否 forward
- 目标进程当前 pid
- ASLR base 地址
- 最近 5 条 ue.dap scope 的 log tail

`:UEResetLayout` —— DAP UI 错乱时 (常见 nvim-dap-ui 状态机被 picker 抢窗口)
一键重置回 sidebar/repl/scope 标准布局。

---

## 5. 调试日志子系统 (1.0 的 silent failure 终结者)

### 5.1 设计

`lua/utils/log.lua` (v2, 583 行, commit ddd9193) — 旋转文件日志:
- 路径: `%LOCALAPPDATA%\nvim-data\nvim\nvim-debug.log` + `.1`–`.5` (2MB / 5 backups)
- 默认 level: WARN (ERROR/WARN 必落盘)
- 5 个命令: `:NvimLog` `:NvimLogPath` `:NvimLogClear` `:NvimLogLevel` `:NvimLogScope`
- 结构化: `log.error_ctx(scope, msg, {k=v, k=v})` 输出 sorted k=v
- fast-event safe: 在 libuv timer / job callback 里自动 queue + vim.schedule(flush)

### 5.2 接入面

38 处 `vim.notify(..., ERROR)` 已替换为 `log.notify_error(scope, msg)`，
覆盖 11 个模块 (theme, workarounds, sidebar, yazi, ue_logs, ue_launch,
windows config, snacks, ue, ue.dap)。

`log.wrap_job{cmd, cwd, on_*, notify_callback_throw=true}` 包 jobstart，
默认开 `notify_callback_throw` —— 回调里抛异常**禁止**静默吞，必须落盘。

### 5.3 用户价值

凌晨索引跑完 / Android attach 失败 / 第三方插件偷偷崩了一个 callback ——
睁眼第一件事 `:NvimLog` 就能看到完整时间线，不再有"我记得它报过错但找不到了"。

---

## 6. snacks.nvim picker 的 6 个 workarounds

`lua/workarounds/snacks/`:
1. `picker_str_byteindex_oob.lua` — LSP 给的 position 越界时不要 crash (commit 7ee9769)
2. `picker_first_open_freeze.lua` — 第一次开 picker 卡 N 秒
3. `projects_picker_freeze.lua` — projects picker 在 Neovide 上冻死
4. snacks-picker-source-override 系列 (源码改不了的 source 默认值)
5. snacks-picker-pseudo-tree-grouping (两级伪树形分组)
6. snacks-picker-layout-and-pin-actions

每个都有对应 skill 文档，upstream fix 后整文件删除即可。

---

## 7. 跨平台 / 工程化基线

- **Win + WSL2** 双跑: WSL 端读 NTFS 时 listdir 慢, inject_definitions_to_cdb.py
  做了 module 级 cache, 省 90%+ I/O
- **csearch** 集成: utils/code_search/, ripgrep 在 11593 cpp 上不够快时的备份
- **recent_projects.lua** + sessions 自动恢复
- **rider-light colorscheme** (commit 11cdfba) — 给做 UE 工具同事用 Rider 主题的人无缝过渡
- **cindent for C/C++/HLSL/C#/Java/GLSL** (commit c35c86a)
- **52 个 lua 文件** 全部通过 `lint_no_bare_globals` (skill lua-bare-global-detection)

---

## 8. 已知短板 (1.0 没解决, 留给 1.1+)

1. **9.6% ThirdParty -I 缺失** — UBT GenerateClangDatabase 没吐 oodle / zlib / mimalloc /
   ICU 这一批 ThirdParty 头的 -I。修法是 fork UBT 或 inject 后处理。50 个 fatal 全在这。
2. **:UEIndexHot 端到端实测耗时未量化** (F 任务)
3. **clangd 17→19 升级评估** 待做 (预期再 -10~15%)
4. **inject 阶段 3 min 占比** —— 每 module 仍要 listdir + read rsp，可批量化
5. **远端预产 .idx + 启动时下发** —— CI 基建，<10s 启动是终极目标
6. **Linux 端从未实测** (虽然 platform.lua 留了接口)

---

## 9. 1.0 之后能做到什么 — 展望

下面这些不是空想，每条都对应当前架构上的明确扩展点。

### 9.1 编辑器侧 — sub-50ms goto-definition for **任意** UE 符号

当前:
- racing-goto-definition + treesitter pre-bail 已经把"大多数 cpp 内符号"压到 100ms 以内
- ue_goto/jumper 的 6 模块切片让"先 ts/ctags 后 LSP" 的策略可灵活调

下一步:
- 把 super-unity .idx 拆成 **module-级 micro-idx** (每 module 独立 .idx 文件)
- nvim 启动时只 mmap 当前 active module + 邻居 module 的 micro-idx
- 当用户 goto 到陌生 module 时 lazy mmap 那个 micro-idx (~10ms)
- 用 jumper 先返回 treesitter 候选, micro-idx ready 后再 refine
- **目标: 任意 UE 符号 cold-jump < 50ms, hot-jump < 10ms**

### 9.2 索引侧 — 真增量 + 远端协作

当前 :UEIndexHot 的 13 module 选法是基于"当前 active buffer + CORE 模块"。
缺一个 git-aware 增量层:

下一步:
- watch git diff HEAD..main, 把 changed file 所在 module 自动加入 hot set
- 远端 CI nightly 跑 super-unity full, 产物上传 OSS
- nvim 启动时 hash 比对，缺失 module 才 trigger 本地 incremental
- **目标: 90% 工作日里, 用户根本不需要主动跑 :UEIndexFull**

### 9.3 Android DAP — "插上线就能调"

当前 `:UEAndroidDAPLaunch` 已经是 9 步全自动，但前提是用户记得 `:UESetAndroidPackage`。
下一步:
- 自动从 .uproject + Android/.../GameActivity 推断包名
- 多设备 picker (snacks)，记忆上次选择
- 真机 GPU profiling: adb shell dumpsys gfxinfo 接到 trouble.nvim 显示
- **conditional breakpoint by ASLR-aware symbol** (现在还得手动算偏移)
- 启动 adb logcat 自动联动 — DAP attach 时 :UEDebugLogToggle 自动开启包名 filter
- 配合 hermes-agent 的 `android-shader-unpack` skill, **断点命中时自动
  dump 当前 frame 的 shader 二进制**做 round-trip 调试

### 9.4 跨工具协同 — RenderDoc / pix / GPU profiler 嵌入

当前 hermes 这边有 `renderdoc-mcp-file-ipc` skill, qrenderdoc 实例可以走文件 IPC 控制。
nvim 1.1 可以:
- `:UERenderDocCapture` — 触发当前帧 capture，自动打开 qrenderdoc
- `:UERenderDocGotoEvent <eid>` — qrenderdoc 跳到指定 event, nvim 同步打开 shader 源码
- DAP 命中 RHICmdList::* 断点时自动联动 qrenderdoc 高亮对应 GPU event
- **想象**: 一个 vsplit, 左边 nvim 看 cpp 源码, 右边 qrenderdoc 显示对应的 GPU 状态。
  同步光标。

### 9.5 烘焙 / 资源 pipeline 集成

`android-shader-unpack` / `binary-parser-root-cause-review` 这套 skill 已经
在打包侧深耕。1.1 可以把这些拉进 nvim:
- `:UEBakeAndDebug` — 一键: cook content -> install -> launch -> dap attach -> 命中
  shader hash 时 auto-unpack -> 在 nvim buffer 里直接看反汇编

### 9.6 AI 辅助 (hermes-agent 协同)

当前 nvim 仓和 hermes-agent 是两套独立工具，通过 skills + sessions 文档桥接。
下一步可以做:
- `:UEAskHermes` — 选中 cpp 一段，发给 hermes-agent, 用项目 sessions 上下文
  (UE renderer / Nanite / clangd indexing 的 skill) 做 review
- nvim 错误 (从 nvim-debug.log) 自动喂给 hermes，让 hermes 直接修 ue.lua
- **跨会话**: hermes 每次跑完任务在 nvim 这边产生一个 quickfix list

### 9.7 工程化 — 多人共享配置

现在配置是 hana-alice 个人仓。1.1 / 2.0 可以:
- 把 `lua/ue.lua` + `tools/` + `scripts/` 抽成独立 plugin
  (e.g. `hana-alice/nvim-unreal`)
- 让其他 UE 团队成员 `LazyExtras` 一键启用
- workarounds/ 的 patch 改走 pull request 而非个人维护

### 9.8 性能基线 — 把所有数字钉进 CI

当前 3.0 min full / 100ms goto-def 这些数字是手测的。1.0 之后:
- `scripts/perf_baseline.ps1` 跑标准 workload, JSON 输出
- GitHub Actions matrix (Win + WSL) nightly 跑
- 退化 > 10% 自动开 issue
- README 顶上挂个实时 badge: `index: 3.1min ↓ goto: 87ms ↓`

---

## 10. 致谢与坐标

- 上游: LazyVim, lazy.nvim, snacks.nvim, blink.cmp, nvim-dap, nvim-dap-ui, codelldb,
  fidget.nvim, gitsigns, treesitter, trouble.nvim, dropbar
- 工具: clangd 22.1 trunk, UnrealBuildTool, Python 3.12, ripgrep, csearch
- 配置作者: hana-alice <hana-alice@users.noreply.github.com>
- 仓库: https://github.com/hana-alice/nvim
- 许可证: 见仓库 LICENSE

---

## 附录 A — skill 索引 (本仓沉淀的 70+ 条工程经验)

按域分组，全在 `~/AppData/Local/hermes/skills/software-development/`:

UE / clangd:
  ue-lua-engine-only-maintenance, ue-cdb-missing-new-files,
  ue-cdb-response-file-expansion, ue-renderer-cpu-gpu-cross-verify,
  ue5-rdg-addpass-reading, clangd-indexer-ue-defs-injection,
  clangd-pch-precompile, clangd-restart-after-index-rebuild,
  clangd-instant-goto-disambiguation, clangd-at-definition-bail,
  racing-goto-definition, treesitter-pre-lsp-early-bail

Neovim / Neovide / LazyVim:
  lazyvim-config-audit, lazyvim-keymap-dedup-and-cheatsheet-sync,
  windows-nvim-xdg-consolidation, neovide-orphan-nvim-cleanup,
  neovim-startup-profiling-windows, neovim-async-progress-notifications,
  neovim-module-self-verification, neovim-precise-jumper-contract,
  windows-neovim-theme-plugin-integration, local-neovim-colorscheme-integration,
  running-nvim-remote-reload, nvim-jobstart-logged, nvim-remote-error-dump,
  nvim-rotating-debug-logger, lazy-plugin-monkeypatch-workaround,
  lua-bare-global-detection, tiered-god-module-split, isolated-workarounds-directory

snacks.nvim picker:
  snacks-picker-windows-pitfalls, snacks-picker-source-override,
  snacks-picker-pseudo-tree-grouping, snacks-picker-layout-and-pin-actions,
  snacks-projects-picker-mru, snacks-live-finder-abort-handling,
  csearch-snacks-live-finder-integration

工程化:
  systematic-debugging, test-driven-development, requesting-code-review,
  progressive-instrumentation-for-neovide-freezes,
  rg-windows-ntfs-large-cpp-workspace, ntfs-bulk-small-files,
  context-compaction-recovery, subagent-driven-development

---

*1.0.0 — 2026-04-24*
