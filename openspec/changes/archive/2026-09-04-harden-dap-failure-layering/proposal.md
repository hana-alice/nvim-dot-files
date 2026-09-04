# 提案：DAP 五层能力契约（preflight + 带 layer 的失败分类）

## Why

DAP 调试链需要**每月修一次**，成本不在数量而在形态：34 条 DAP 坑（K1–K61）里
**只有 8 条是本仓自己的 bug，19 条（目标 OS 策略 9 条 + 调试引擎 10 条）是外部契约**，
且全部在 attach 现场以无信息量报错暴露（`attach failed: lost connection` /
`The parameter is incorrect`），每条要花数小时现场取证才能定位到层。

两条本月最贵的坑（K56 app uid 无权 ptrace、K58 SELinux `shell_data_file` 可读不可执行）
各自离自诊断只差**一条 5 秒设备命令**。同时 124 个 `dap` 用例全是纯函数 / 源码断言，
**没有任何用例能回答「这条路线现在还通不通」**——真正的回归探测器是用户本人，在他最需要
调试的那一刻。第三，代码把**单台设备的结论写死**（sandbox 布局、`run-as` 可用、
NDK 27 LLDB 18、该 OEM SELinux 策略），所以换设备/换 Android 版本就等于换一个月。

## What Changes

- **新增 5 层能力契约（L0–L4）并让所有 agent 第一次读就看到**：契约同时落到根
  `AGENTS.md`（三端唯一内容源）、`docs/CONSTRAINTS.md`、`lua/ue/dap/AGENTS.md` 与治理 spec；
  `structure` 回归守护其可发现性（缺失即 FAIL）。
- **新增 `ue.dap.failure` 失败分类模块**：DAP 失败必须携带
  `{layer, owner, evidence, remedy}` 四元组；**报出处置前必须先报层**。
- **新增 `:UEDAPPreflight`**：attach 前按 L0→L4 异步探测，逐层给判定 + 确切拒绝命令；
  L2（目标 OS 策略）为红时**拒绝启动 attach**，而不是让它在 L3 以 `lost connection` 暴露。
- **能力探测取代写死的设备结论**：`run-as` 可用性、app uid exec 权限、SELinux 模式、
  ptrace 可行性等由探测得出，**MUST NOT** 假设某一台设备的答案。
- **新增 `:UEDAPSmoke`**：按需触发的真机端到端验证，产出**脱敏**证据（遵 K55），
  使回归探测器从用户变成本仓。
- 沿 L1/L2/L3 缝拆分 `lua/ue/dap/android.lua`（现 2430 行 / 82 函数 / 71 处 adb 调用），
  使上述 4 项可评审、可 headless 测。

## Capabilities

### New Capabilities

- `dap-failure-layering` — 五层归属契约、失败四元组、preflight 前置门禁、能力探测取代
  写死结论、真机 smoke 证据契约。

### Modified Capabilities

- `android-dap-attach` — attach 前置门禁与能力探测：新增「attach 必须先过 L2 能力门禁」
  与「设备能力必须探测而非假设」两条 requirement；既有 app-uid / 复用快路径
  requirement 改为由探测结果驱动，不再表述为对单台设备的固定结论。
- `android-dap-attach-diagnostics` — 既有「分层定位 attach 失败」由**文档级**排查顺序
  升级为**可执行**层判定（`:UEDAPPreflight` 的机器可读判定），并要求诊断输出携带 layer。
- `dap-platform-dispatch` — dispatch 层失败也必须携带 layer/owner，不得发出无层错误。
- `local-subsystem-rules` — 层契约必须出现在 `lua/ue/dap/AGENTS.md`（本地规则内容源）。
- `project-constraints-doc` — 层契约与「失败先报层」进入 CONSTRAINTS 权威索引。
- `spec-authority-loop` — SESSION START 增加「DAP 类改动先读层契约」一步，使三端 agent
  第一次读就看到。

## Impact

- **代码**：新增 `lua/ue/dap/failure.lua`、`lua/ue/dap/preflight.lua`、
  `lua/ue/dap/capability.lua`；改 `lua/ue/dap/android.lua`、`lua/ue/dap.lua`、
  `lua/ue/dap/platforms.lua`、`lua/ue/dap/ios.lua`（错误发出点）；`lua/ue.lua` 注册两条新命令
  （注意 `lua/ue.lua` 卡在 10562 行冻结 ratchet，新逻辑不得落在该文件）。
- **规则/文档**：根 `AGENTS.md`、`docs/CONSTRAINTS.md`、`lua/ue/dap/AGENTS.md`、
  `memory/project_overview.md`、`lessons/README.md`、`docs/TOOLING.md`、`docs/changelog.md`。
- **测试**：`tests/cases/dap_spec.lua`、`structure_spec.lua`、`commands_spec.lua`（命令冻结清单
  82 → 84）、新增 `tests/cases/dap_failure_layer_spec.lua`；`tests/AGENTS.md` filter 映射同步。
- **依赖**：无新依赖。宿主工具链约束（C1：LLVM 22.1.6+ forward-only、NDK 27 LLDB 18）不变。
- **不改**：K30 serial-form 路线、app-uid 运行形态、K3 信号处置、K37 slide 承重性——
  本 change 只改**发现与验证**，不改已被证据背书的 attach 路线本身。
