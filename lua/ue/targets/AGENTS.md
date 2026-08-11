# lua/ue/targets/ — Unreal target-driver layer

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

把 Unreal target platform 策略从 host OS 策略中拆开。这里的模块只表达
`Android` / `IOS` / `Mac` / `Win64` / `Linux` 各自的 target 规则：
UBT/UAT argv、RSP 归属判断、以及各 target 自有的生命周期 planner。

## 专属约定

- **host 与 target 正交**：本目录只回答 Unreal target 策略；宿主工具入口来自 `utils.platform/*`。
- **兼容性由 matrix 决定**：每个 driver 必须声明 `host_operations[host][operation] = true`；
  所有 build/package/device/install/launch/log/DAP 入口先经 `ue.targets.resolve`，不得以模块可加载、
  文件扩展名或 path 形状推测兼容性。
- **runtime dispatch 也归 target**：每个 driver 的 `runtime.launch/main_log/debug_log.strategy`
  决定通用 orchestrator 的策略；desktop executable suffix、editor app bundle 规则也写在对应 target，
  `utils/ue_launch.lua` / `utils/ue_logs.lua` 不得硬编码 target 名分支。
- **driver 彼此独立**：`android.lua` / `ios.lua` / `mac.lua` / `win64.lua` / `linux.lua`
  不得互相调用、读取彼此状态或作为 fallback。
- **`_common.lua` 必须 policy-free**：只允许放 argv/path/schema 校验、plan 组装、
  unavailable descriptor 之类无状态 helper；不得放 target 默认值、工具选择、产物策略。
- **纯规划 / 纯解析优先**：driver 返回 `{ executable, args, cwd, metadata }` 计划或
  结构化结果；不得在此层执行进程、读 Neovim UI、发通知。
- **既有副作用用 target hook 隔离**：为保持兼容而必须执行的 target-specific pre-build
  清理只能放对应 driver hook，并通过核心注入的窄 runtime 接口调用；hook 不注册命令、不开 UI、
  不读取其他 target 状态。新 Build/Package/Install/Launch 仍优先返回纯 plan 交给通用执行器。
- **Apple 分层严格**：`ios.lua` 独占 devicectl、签名预检 descriptor、stage app / bundle id
  逻辑；`mac.lua` 只实现 Mac target build/RSP 规则，不承载 iOS 生命周期。
- **不扩展 macOS→Android**：本变更只支持 macOS host 上的 Mac/IOS 目标。既有 Android SO
  PowerShell 兼容逻辑只允许位于 `android_windows.lua`，不得成为 macOS 依赖或 fallback。
- **DAP 注册也受 matrix 约束**：foreign target 模块可 import 不等于可执行；`ue.dap.platforms`
  只注册当前 host 声明支持的 attach/launch handler，IOS 未实现时不得借用 Mac handler。

## 改动 → 必跑回归

- 改 `targets/**` → `ue_target_drivers`
- 提交前仍按根规则跑全量

## 先读

`../../../openspec/changes/add-macos-ios-cdb-semantic-prepare/design.md`、
`../../../openspec/changes/add-ios-build-run-workflow/design.md`、
`../AGENTS.md`
