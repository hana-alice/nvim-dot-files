# Headless 回归测试套件

> 本文档是本仓库**权威的回归测试方式**。每次开发完成后跑一遍，确认无回归。
> 完成的硬标准（Definition of Done）在根 `CLAUDE.md`；本文件是其回归条目的权威细节。

## 改动后回归政策（分范围）

任何 `.lua` 运行时代码或 `tests/` 用例改动，**在视为完成前 MUST 跑对应范围回归并全绿**。
按改动类型跑**最小必跑范围**即可（控制成本），但有两条兜底：
**① 提交/合并前必跑全量；② 影响面不确定就升级到全量，不猜窄 filter。**

### 改动 → 必跑 spec filter 映射

| 改动位置 | 最小必跑 filter |
|---|---|
| `lua/config/keymaps.lua` / 命令定义 | `keymaps` `commands` |
| `lua/utils/window_title.lua` | `window_title` `keymaps` `commands` `cheatsheet` |
| `lua/utils/android_device.lua` / Android ADB device 路由 | `android_device` `dap` `ue_context` |
| `lua/ue/config.lua`（schema） | `ue_config` `smoke` |
| `lua/ue.lua` 项目选择 / context 解析 / workflow dispatch | `ue_project_context` `ue_api` `smoke` `ue_platform_boundary` |
| `lua/ue/project_state.lua` / `lua/ue/file_lock.lua` / 共享持久状态 | `multi_instance_state` |
| `lua/ue/cdb/**` | `ue_cdb` |
| `lua/ue/dap/**` / `lua/utils/platform/**` | `dap` `platform` `ue_platform_boundary` |
| `lua/ue/index/**` / `lua/ue/clangd_commands.lua` / controlled CDB generators | `index_generation` `cpp_semantic_index` `clangd_commands` `ue_api` `ue_platform_boundary` |
| `lua/ue/targets/**` / `lua/ue/workflows/**` / `lua/ue/target_tasks.lua` | `ue_target_drivers` `ue_target_integration` `ue_target_tasks` `ue_workflows` `ue_platform_boundary` `platform` `commands` `stability` |
| `lua/utils/ue_goto/**` / C++ `gd` / semantic sidecar | `cpp_semantic_context` `cpp_semantic_client` `cpp_semantic_sidecar` `ue_goto_behavior` `utils` `ue_platform_boundary` |
| `lua/utils/code_search/**` / `ue_paths.lua` | `ue_goto_behavior` `ue_paths` `utils` `ue_platform_boundary` |
| `lua/config/options.lua` / `autocmds.lua` | `options` `autocmds` |
| `lua/theme.lua` / `lua/highlights.lua` / `colors/**` | `theme` `smoke` |
| `lua/utils/stall_probe.lua` | `stall_probe` |
| `lua/utils/core_health*.lua` / `scripts/nvim_core_health.lua` | `core_health` |
| `lua/workarounds/**` | `workarounds` `smoke` |
| `lua/ue.lua` façade / workflow 边界 | `ue_platform_boundary` `structure` |
| 文档 / 规则 / 知识库结构 | `structure` |
| **跨子系统 / 公共 helper / 重构 / 拿不准** | **全量（不带 filter）** |

> 与 `tests/AGENTS.md` 的 CHANGE-TO-FILTER MAP 保持一致；新增/重命名 spec 时两处同步。

### 配套要求

- **新增功能必须补测试**：新增功能域 / 用户命令 / 快捷键 / 公共 API 时，同步新增或更新对应 `*_spec.lua`。
- **冻结清单同步**：`commands_spec.lua` 的 `UE_COMMANDS`、`structure_spec.lua` 的目录清单等，
  在相关项变化时必须同步，否则回归会 FAIL（这是有意的防误删契约）。
- **changelog 联动**：改动完成后在 `docs/changelog.md` 追加记录，其 Validation 字段写明
  **所跑回归范围（filter 或全量）与结果**。

## 一键全量回归

```
nvim --headless -l tests/run.lua
```

## 本机真实能力健康检查

全量回归主要证明契约、纯逻辑和 fixture 行为；真实 startup、Tree-sitter parser、搜索 backend
与 clangd/CDB 前置条件使用独立的只读 health runner：

```sh
nvim --headless -l scripts/nvim_core_health.lua
nvim --headless -l scripts/nvim_core_health.lua --json
nvim --headless -l scripts/nvim_core_health.lua --filter syntax
```

`FAIL` 表示 deterministic 基础能力失败；`DEGRADED` 表示基础能力通过，但 csearch、钉死版本
clangd 或 live workspace 等外部能力被 `BLOCKED`。它补充而不替代本页的全量回归。

Windows 本机便捷入口（仅转发，不含测试逻辑）：

```
pwsh -File scripts/run_regression.ps1
```

退出码约定：

- `0`：全部用例通过
- `1`：任意用例失败 / 加载错误 / 子进程旁路测试失败

末尾会打印汇总行：

```
=== N/M passed, K failed ===
```

失败用例会在汇总之前优先打印，格式为：

```
FAIL  <describe> > <it>
        └─ <文件:行>: <断言信息>: expected <X>, got <Y>
```

## 只跑某一组用例（开发中快速迭代）

```
nvim --headless -l tests/run.lua dap      # 只跑文件名含 "dap" 的 *_spec.lua
FILTER=platform nvim --headless -l tests/run.lua
pwsh -File scripts/run_regression.ps1 -Filter ue_config
```

带 filter 时**不执行** legacy 旁路（见下），便于聚焦新用例。

## 目录结构

```
tests/
├── run.lua              # 统一入口：自举 rtp、自动发现、汇总、退出码
├── harness/init.lua     # 纯 Lua 框架：断言 + describe/it + 报告 + 自举
└── cases/
    ├── smoke_spec.lua            # 配置加载冒烟 + ue.setup() 命令注册
    ├── android_device_spec.lua   # Android device picker + 进程内 serial + adb -s 路由
    ├── multi_instance_state_spec.lua # 项目/target 隔离 + 跨进程原子/merge/lease
    ├── platform_spec.lua         # utils.platform 四驱动接口契约
    ├── ue_target_drivers_spec.lua # host/target 隔离 + IOS plan/parser/provenance
    ├── ue_target_integration_spec.lua # ue.lua registry dispatch + target 隔离
    ├── ue_target_tasks_spec.lua  # 结构化 argv 的异步执行边界
    ├── ue_api_spec.lua           # ue 公共表/函数冻结
    ├── ue_config_spec.lua        # ue.config schema 默认值/override/reset
    ├── ue_cdb_spec.lua           # ue.cdb.json/paths/shaders 契约
    ├── dap_spec.lua              # ue.dap.platforms 注册 + 各平台 attach/launch
    ├── utils_spec.lua            # utils.code_search/log/ue_paths/ue_goto 加载
    ├── keymaps_spec.lua          # 快捷键绑定（DAP 功能键多模式 / leader / gd/gr/gc / Win <C-v>）
    ├── commands_spec.lua         # 70 个 UE* 命令 + Restart/Workaround* 注册（冻结清单）
    ├── window_title_spec.lua     # 系统窗口标题 literal/sanitize/reset/prompt 契约
    ├── options_spec.lua          # expandtab/shiftwidth/number/sessionoptions
    ├── autocmds_spec.lua         # usf→hlsl、cindent 切换、commentstring 回退
    ├── workarounds_spec.lua      # 注册表发现/无 error/frontmatter/status 形状
    ├── fs_proc_spec.lua          # ue.core.fs/proc 纯函数行为
    ├── ue_paths_spec.lua         # utils.ue_paths is_blocked/is_searchable/filter
    ├── cpp_semantic_context_spec.lua # CDB / dependency provenance / context fingerprint
    ├── cpp_semantic_client_spec.lua  # process manager / stale token / overlay / context lifecycle
    ├── cpp_semantic_sidecar_spec.lua # NDJSON / libclang USR / overload / dep+rsp+unity
    ├── ue_goto_behavior_spec.lua # C++ 不缓存/不 fallback + location 去重
    └── stability_spec.lua        # 重复 require/setup 幂等、多轮 reset 无泄漏
```

## 覆盖矩阵

| 功能域 | 用例文件 | 覆盖口径 |
|--------|----------|----------|
| 配置加载 | smoke_spec | 关键模块 require + setup 不报错 |
| Android device | android_device_spec | `adb devices -l` 解析、名称+serial picker、进程内 serial、install/launch/logcat/DAP `-s` 路由 |
| 多实例状态 | multi_instance_state_spec | live selection 隔离、project bucket、target 原子对、共享集合 merge、writer lease |
| 平台驱动 | platform_spec | 四驱动接口形状一致 |
| ue API | ue_api_spec | 公共表/函数冻结 |
| ue.config | ue_config_spec | 默认值/override/reset |
| ue.cdb | ue_cdb_spec | json/paths/shaders 契约 |
| DAP | dap_spec | 平台注册 seam + attach/launch 导出 |
| **快捷键** | keymaps_spec | 绑定存在 + 指向预期命令（不触发动作） |
| **用户命令** | commands_spec | 全部 UE*/Restart/Workaround* 已注册 |
| **窗口标题** | window_title_spec | literal titlestring、安全清理、命令与 prompt/reset 语义 |
| **options** | options_spec | 关键 option 取值 |
| **autocmd/filetype** | autocmds_spec | usf→hlsl、cindent、commentstring |
| **workarounds** | workarounds_spec | 注册表完整性 + frontmatter |
| **utils 纯函数** | fs_proc/ue_paths/ue_goto_behavior | 输入→输出行为断言 |
| **稳定性** | stability_spec | 幂等 + 状态隔离 |

### keymap 用例的前置约定

headless `nvim -l` **不会**自动加载 `lua/config/keymaps.lua`（它通常在 LazyVim 的 VeryLazy 事件加载）。因此 keymap/命令用例需在文件头部按固定顺序前置：

```lua
vim.g.mapleader = " "
vim.g.maplocalleader = " "
require("ue").setup()
pcall(dofile, cfg .. "/lua/config/keymaps.lua")
```

leader 必须先于 `dofile` 设置，否则 `<leader>xx` 会以字面 `<leader>` 记录。用 harness 的 `get_keymap(mode, lhs)` 查询绑定（已规范化 leader 与 termcode 差异）。

### 命令冻结清单维护约定

`commands_spec.lua` 内的 `UE_COMMANDS` 是 70 个 `UE*` 命令的**冻结清单**。新增或重命名 `UE*` 命令时**必须同步**此清单——这是有意的「防误删」契约：清单与实际注册不一致即 FAIL。



## 如何新增一个测试用例

1. 在 `tests/cases/` 下新建 `<域名>_spec.lua`（必须以 `_spec.lua` 结尾，会被自动发现）。
2. 文件顶部：

   ```lua
   local t = require("tests.harness")
   t.bootstrap()
   ```

3. 用 `describe` / `it` 组织，用 `assert_*` 断言：

   ```lua
   t.describe("我的功能", function()
     t.it("做了某件事", function()
       t.assert_eq(actual, expected, "可选说明")
     end)
   end)
   ```

4. 直接再跑一次 `nvim --headless -l tests/run.lua`，新文件会被自动纳入，**无需改 `run.lua`**。

### 可用断言

| 断言 | 含义 |
|------|------|
| `assert_eq(actual, expected, msg?)`  | `==` 相等，失败时打印 expected/actual |
| `assert_true(v, msg?)`               | 真值 |
| `assert_false(v, msg?)`              | 假值 |
| `assert_nil(v, msg?)`                | 必须为 nil |
| `assert_type(v, "table", msg?)`      | `type(v)` 匹配 |
| `assert_match(s, pattern, msg?)`     | 字符串匹配 Lua pattern |
| `assert_error(fn, msg?)`             | fn 调用必须抛错；返回捕获到的错误 |
| `assert_contains(container, item, msg?)` | string 含子串 / list 含元素 |

### keymap 查询辅助

| 辅助 | 含义 |
|------|------|
| `get_keymap(mode, lhs)` | 按 `(mode, lhs)` 查当前映射，命中返回 map 表（含 rhs/callback），否则 nil；已规范化 `<leader>` 与 termcode |

### 状态隔离约定

- 涉及全局状态的模块（`ue.config`、`ue.dap.platforms`），用例尾部必须复位：
  `ue.config.reset_for_test()` / `ue.dap.platforms._reset_for_test()`。
- 单个 `it` 抛错只标记该用例 FAIL，不会中断其余用例。

## 覆盖口径

本套件采用 **「功能域 + API 冻结 + 加载冒烟」** 作为覆盖口径，而非行覆盖率：

- 关键模块能在 headless 下被 require（不报错）。
- `ue` 公共表/函数、`ue.config` schema、平台驱动接口、DAP 平台注册等**契约不被重构误删**。
- 新增功能时**约定**同步新增 `*_spec.lua`，把覆盖完整性变成开发习惯。

**不覆盖**：需要真机 / adb / active UE workspace / 网络的端到端流程。C++ sidecar 使用本机
libclang fixture 自动验证；active UE build 的只读验证走 `scripts/ue_cpp_semantic_smoke.lua`。

## Legacy 脚本旁路

`tests/run.lua` 末尾会 fork 子进程执行仍属**纯 headless 且稳定**的 legacy `ue_goto` 脚本：

- 纳入：`test_jumper_headless`。
- 已删除：以 arity / syntax filter / ranking / pair winner 选择 C++ overload 的旧脚本；这些行为与
  compiler-identity authority invariant 冲突。
- 排除（需外部资源 / 开发中）：`test_jumper_real`（需 clangd）、`test_jumplist_fix`（需 socket）、`test_dependent_name`。

跳过旁路：`NO_LEGACY=1 nvim --headless -l tests/run.lua`。

## 与旧入口的关系

- `scripts/headless_smoke.lua`：保留为兼容入口，可继续 `nvim --headless -l scripts/headless_smoke.lua` 直接运行；其断言已等价迁入 `tests/cases/ue_*_spec.lua`、`platform_spec.lua`、`dap_spec.lua`。
- `scripts/run_all_tests.ps1`：保留的 jumper / dependent-name 便捷入口；新权威入口为
  `tests/run.lua` / `scripts/run_regression.ps1`。
