# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)
- `v1.9.0` → `docs/release_1.9.0.md` (tag pending explicit confirmation)

- `v1.9.1` → `docs/release_1.9.1.md` (tag pending explicit confirmation)
- `v1.9.2` → `docs/release_1.9.2.md` (tag pending explicit confirmation)
- `v1.9.3` → `docs/release_1.9.3.md` (tag pending explicit confirmation)
- `v1.10.0` → `docs/release_1.10.0.md` (tag pending explicit confirmation)
- `v1.11.0` → `docs/release_1.11.0.md` (tag pending explicit confirmation)
- `v1.11.1` → `docs/release_1.11.1.md` (tag pending explicit confirmation)
- `v1.11.2` → `docs/release_1.11.2.md` (tag pending explicit confirmation)

- `v1.11.3` → `docs/release_1.11.3.md` (tag pending explicit confirmation)

- `v1.12.0` → [docs/release_1.12.0.md](release_1.12.0.md) (incremental scope; tag pending)
- `v1.12.1` → [docs/release_1.12.1.md](release_1.12.1.md) (tag pending)
- `v1.12.2` → [docs/release_1.12.2.md](release_1.12.2.md) (diagnostic stage; tag pending)
- `v1.12.3` → [docs/release_1.12.3.md](release_1.12.3.md) (demand-driven recovery; tag pending)
- `v1.12.4` → [docs/release_1.12.4.md](release_1.12.4.md) (native junction verification; later ancestor-event fallback recorded; tag pending)
- `v1.12.5` → [docs/release_1.12.5.md](release_1.12.5.md) (stable directory writes and complete ancestor watches; tag pending)
- `v1.12.6` → [docs/release_1.12.6.md](release_1.12.6.md) (modified-document preflight and clean demand recovery; tag pending)
- `v1.12.7` → [docs/release_1.12.7.md](release_1.12.7.md) (automatic clean-document recovery; tag pending)
- `v1.12.8` → [docs/release_1.12.8.md](release_1.12.8.md) (padded search query cancellation; tag pending)
- `v1.12.9` → [docs/release_1.12.9.md](release_1.12.9.md) (durable search overflow recovery; tag pending)
- `v1.12.10` → [docs/release_1.12.10.md](release_1.12.10.md) (second qualified SuperUnity batch; tag pending)
- `v1.12.11` → [docs/release_1.12.11.md](release_1.12.11.md) (retain document-blocked original readers; tag pending)

- `v2.0.0` → [docs/release_2.0.0.md](release_2.0.0.md) (CodeDiff default review; Diffview retained; tag pending)
- `v2.1.0` → [docs/release_2.1.0.md](release_2.1.0.md) (daily editing and maintenance diagnostics; tag pending)

- `v2.2.0` → [docs/release_2.2.0.md](release_2.2.0.md) (IDE experience; local validation complete; tag pending)

- `v2.3.0` → [docs/release_2.3.0.md](release_2.3.0.md) (search, reading and window recovery; tag pending)

- `v2.3.1` → [docs/release_2.3.1.md](release_2.3.1.md) (daily file protection and discovery; tag pending)

- `v2.3.2` → [docs/release_2.3.2.md](release_2.3.2.md) (navigation and editing entry fixes; tag pending)

- `v2.4.0` → [docs/release_2.4.0.md](release_2.4.0.md) (memory document find and editor reuse; tag pending)

- `v2.5.0` → [docs/release_2.5.0.md](release_2.5.0.md) (document locations and copy actions; tag pending)

- `v2.6.0` → [docs/release_2.6.0.md](release_2.6.0.md) (development workbench and run-owned evidence; tag pending)

- `v2.7.0` → [docs/release_2.7.0.md](release_2.7.0.md) (named investigations and interruption continuity; tag pending)

## Unreleased

已将具名调查切片归档至 [2.7.0](release_2.7.0.md)。

### 2026-10-08 — 用工作台贯通开发入口、恢复与首次上手

**Task**
- 产品复盘后收敛入口：多个顶层入口与六类“恢复”概念让用户先要理解差异；改为以工作台为主线，并缩短首次上手与手册阅读路径。

**Implemented**
- `development_workbench` 首屏分为当前目标 / 下一步 / 最近结果 / 运行中任务 / 恢复五区；局部键 `g` 向导、`R` 恢复、`p` 命令中枢。恢复按意图组织，直接复用原 Workspace / WorkContext / SessionRestore / Recovery owner，不复制存储或逻辑。
- 新增 `utils/ue_onboarding`：按缺项依次走工程 → 平台/配置 → 设备/包名 → Prepare（单独确认）→ UEDoctor，取消即失效后续步骤；`ue.lua` 的原选择命令接受可选 flow guard，覆盖内层迟到回调与 Prepare 延迟启动。
- `USER_GUIDE.md` 只讲“想做什么 → 按什么”（592 → 326 行），边界说明迁到 `USER_GUIDE_LIMITS.md`；同步 Markdown/浮动速查与命令中枢 Recovery 分组；保留全部旧直达键。

**Pitfalls / Gotchas**
- 外层 picker 取消挡不住平台选择器的内层迟到回调（实验观测到取消后仍 fast swap 1 次），必须在内层与 Prepare launcher 处复核 guard。
- 包名选择要绑定发起时设备；Snacks 的 Esc 只切模式，不等于关闭向导 UI。
- 合批全量首轮 3178/3180：`ide_work_context_native` 两条用例仍按旧工作台主屏断言（调查备注行、主屏「继续已保存调查」）。这是入口有意迁移造成的过期断言，不是功能回归；改为断言主屏「当前调查」行，并经恢复菜单的 `UEWorkContext` 动作继续，原有恢复/备注详情断言保留。

**Validation**
- 26 个 MAP filter 全绿；cheatsheet/structure 冻结瘦身前 57 个命令、87 个键位、29 个组合键均仍可查。
- 真实 Neovim + Snacks 按键回放：工作台 → 恢复 → 找回关闭的构建日志 7 键；空配置 → 向导 → 取消 5 键，取消后 1800 ms 无新任务。
- 合批全量（含 B/C 与本条测试修正）：3180/3180，0 失败、0 跳过，包含 legacy。

**Follow-ups**
- 真实 UE 工程完整 fresh 上手（含设备/应用选择）、极窄窗口布局、其它宿主仍未验收。

### 2026-10-08 — Android 无 Python 的 UE 调试变量显示

**Task**
- 让 FString、FName、容器与指针在真实 Android DAP 变量面板中可读。

**Implemented**
- `_android_engine` 的 formatter 命令委派给新 `_ue_formatters`：对引擎自带 LLDB formatter 做非致命 `command script import`，始终保留原生 fallback，删除按 Python 目录推断能力的旧分支。
- 新增 `_ue_values` / `_ue_array`：attach 成功后安装会话级显示层，按真实 `readMemory` 解码 FString（UTF-16、空态）、TArray 有界元素、TMap/TSet Num、NULL UObject/SharedPtr，FName 显示 index + Number；continue/step/detach 作废旧观察。

**Pitfalls / Gotchas**
- 当前 lldb-dap 22.1.6 导入 Python 报 `No module named 'lldb'`（L0 外部工具链），引擎 Python formatter 无法生效。
- 真机上 typed array cast 让 adapter 以 0xC0000409 退出，该路线已删除；内部崩溃机制待验证。
- 正的弱指针 index/serial 不等于有效；不执行目标函数，不把源码字符串冒充已解码 FName。

**Validation**
- dap 252/252、platform 66/66、dap_failure_layer 100/100、ue_platform_boundary 20/20、android_ide 45/45；新增 `dap_ue_values_spec` 15 项。
- 真机同 BuildId：5 个非空 FString、61 个数组元素、FName 索引、TSet/TMap Num、NULL 指针可读；no-kill detach 后游戏存活、TracerPid=0。

**Follow-ups**
- Python 成功分支、有效 UObject 名称、FName 名称解析、真实弱指针、复杂元素数组、GUI 展开仍待验证。

### 2026-10-08 — 真实工程体验基线（只测量）

**Task**
- 在真实 Android/Test 工程上测导航命中率、索引规模与耗时、重复 Prepare 与首次上手，按数据决定下一轮优先级。

**Implemented**
- 无生产代码改动；原始证据与可复跑驱动保存在被忽略的本地证据目录。

**Pitfalls / Gotchas**
- 测量驱动反复 `:edit` 同一文件会让 clangd 短暂脱离（1→0→约 500 ms 后 1），该批数据已作废重测。
- 非当前构建分支（`WITH_EDITOR=0`）与不在 build 内的插件样本不能计为产品缺陷。

**Validation**
- 30 样本：gd 11/30、LSP 引用 11/30、头源切换 24/30；11 个 cpp 起点全部成功，19 个头文件起点全部失败。
- 当前 build 16434 输入、1212 条发布 CDB（997 UBT Unity + 215 exact），覆盖 missing/extra 均 0；**真实二次合并 0**（304 组 verification-not-cached），不满足 C11 阶段验收。
- 后台索引：首次追赶 1612.6 s，热启动 23.4–62.2 s；重复 Prepare 120.7 s，主 CDB 未变、clangd 未重启，current/hot 产物有写入（输入是否不变待验证）。

**Follow-ups**
- P0：头文件 gd 被 `merged-cdb-predates-active-selection` 时间门禁拒绝；头文件 gr 无编译命令（`compile-command-missing`）。
- P0：恢复真实二次合并（C11）。
- P1：头源切换 6/30 跳到 `.gen.cpp` 或无关头文件；新 TU 首次 gd 等待 9–27 s。
