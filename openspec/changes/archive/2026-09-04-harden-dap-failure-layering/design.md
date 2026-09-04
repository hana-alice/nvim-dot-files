## Context

见 `proposal.md` §Why。设计层需要知道的现状与约束：

- **失败发出点分散**：`lua/ue/dap/android.lua`（2430 行 / 82 函数 / **71 处 adb 调用**）、
  `lua/ue/dap.lua`（2463 行）、`ios.lua`（741 行）、`platforms.lua` 各自 `P.error(...)` /
  `log.notify_error(...)` / `vim.notify(...)`，没有统一出口，无法在一处加层归属。
- **`lua/ue.lua` 卡在 10562 行冻结 ratchet**（`stability_spec.lua` 守护，只能降不能升），
  所以新逻辑**不得**落在该文件；命令注册可以，但实现必须在 `lua/ue/dap/` 下。
- **`ue_platform_boundary` 门禁**：target-generic 模块内出现 `adb` / `dumpsys` 等
  target policy 字面量会 FAIL（本月实测踩过两次，其中一次是错误文案里的英文词 "re**adb**ack"
  被子串命中）。因此**通用分层模块不得含任何 Android 命令字面量**，探针命令必须由
  target owner 提供。
- **`host_resource_discipline` 精确 spawn 计数棘轮**：`android.lua` 现为 3 处
  `pcall(vim.system`。preflight 新增 spawn 必须显式抬计数并写明理由，不能绕过。
- **既有 `:UEDAPDiag`** 是事后取证、需要活会话；它**不是** preflight，两者并存不合并。
- **现有 124 个 `dap` 用例全是纯函数或源码断言**，这是可测性资产：新模块必须延续
  「纯判定函数 + 注入式命令执行」形态，才能 headless 测。

## Goals / Non-Goals

**Goals:**

- 让**外部契约失败**（目标 OS 策略、调试引擎）在 5 秒内自我指认，而不是数小时取证。
- 让层归属成为**结构**（类型 + 回归守护），而不是我记得写的习惯。
- 让层契约对三端 agent 第一手可见，且**只有一份正文**（避免第四份漂移副本）。
- 换设备不等于换一个月：能力靠探测。

**Non-Goals:**

- **不改已被证据背书的 attach 路线本身**（K30 serial-form、app-uid 运行形态、K3 信号处置、
  K37 slide 承重性）。本 change 只改**发现与验证**。
- 不追求 preflight「覆盖所有可能失败」。它只回答**已知的 19 条外部契约坑**所属的那几个能力问题。
- 不做自动修复。preflight 只判定 + 给出确切命令，**不代替用户改设备状态**（改设备是副作用，
  属 K46「安装/替换/启动必须分离」同一哲学）。
- 不合并 `:UEDAPDiag`。事后取证与前置门禁是两个用途。

## Decisions

### D1：层枚举放在 target-generic 模块，层**探针**放在 target owner

`lua/ue/dap/failure.lua` 只含层枚举、四元组构造、格式化——**零 target 字面量**，
因此不触 `ue_platform_boundary`。每层的实际探针由 target owner（`dap/android.lua`、
`dap/ios.lua`）以描述符形式注册：`{ layer, id, command_argv, verdict_fn }`。

**备选**：把探针也写进通用模块，用 if target == "Android" 分支 → 直接违反
`target_literal_condition` 与 `ue-target-driver-boundary`，且会让 iOS 复用变成硬编码分支。已拒绝。

### D2：四元组是**构造期强制**，不是文档约定

`failure.new{layer=, owner=, evidence=, remedy=}` 对缺失 `layer` **报错**（Lua `error`），
使「发出无层失败」在开发期就崩，而不是在 review 时被漏过。层不可判定时必须显式传
`layer = failure.L.UNDETERMINED`——**沉默不是选项，未判定是一个显式值**。

**备选**：只做 lint / 源码断言。已拒绝：源码断言只能覆盖已知发出点，新增发出点会静默逃逸。
不过**两者都做**——构造期强制 + `dap_failure_layer_spec` 源码断言扫描
`notify_error|P.error` 调用点，双保险。

### D3：探针是**纯判定函数 + 注入式执行器**

每个探针拆成两半：`build_argv(ctx) -> argv`（纯函数，可测）与
`decide(rc, stdout, stderr) -> verdict`（纯函数，可测）。执行器由调用方注入
（生产用 `vim.system`，测试用 recorded fixture 表）。这样 **L2 的每条设备语义都能
headless 测**，不需要手机。

这也解决了 §结论一的第二个结构性原因：K56/K58 那类语义会有 fixture 化的回归用例。

### D4：preflight 逐层短路，且**只在 L2 红灯时硬阻断 attach**

L0/L1 红灯本来就会在既有路径上失败得很明确（找不到 adapter、adb 不可达），
硬阻断收益低。**L2 是唯一「红灯却表现为 L3 症状」的层**，所以门禁只在这里强制。
L3/L4 不阻断——它们的失败已经自带协议级或符号级事实。

逃生开关 `UE_DAP_SKIP_PREFLIGHT=1`，与既有 `UE_DAP_NO_SLIDE` / `UE_DAP_NO_FATAL_BP` 同风格；
使用后**在失败反馈中留痕**（否则下次取证会被误导）。

### D5：规则可见性用「一份正文 + 三处指针」

正文（层定义 + owner + 判定手段）**唯一权威在 spec**
（`openspec/specs/dap-failure-layering/spec.md`）。
- 根 `AGENTS.md` SESSION START：**一行指针**（不复制正文）→ 满足「三端第一手可见」。
- `docs/CONSTRAINTS.md` §三：新增 **C10**，给层表摘要 + 指针。
- `lua/ue/dap/AGENTS.md`：层表 + 每层 owner 模块（就地可发现）。

`structure_spec` 断言这三处存在。**备选**：把正文复制到根 `AGENTS.md` → 制造第四份可漂移
副本，违反 `spec-authority-loop`「根文件只给指针」。已拒绝。

### D6：smoke 证据格式沿用 iOS 已有脱敏契约

`tools/evidence/android-dap/` 复用 `tools/evidence/ios-dap/` 的脱敏形态（K55：
只记摘要/digest，无真实 serial / bundle id / pid / 个人路径）。不新造格式。

### D7：拆分 `android.lua` 放在**最后**且沿 L1/L2/L3 缝

先落 failure + preflight + capability（新文件，不动老文件结构），**再**拆分。
理由：拆分是纯结构变更，混在行为变更里会让 review 与回归定位都变难。
拆分目标：`android/_transport.lua`（L1）、`android/_policy.lua`（L2 探针）、
`android/_engine.lua`（L3 命令序列），主文件保留编排。**新文件受 800 行上限**
（`stability_spec`），这正好是拆分粒度的天然约束。

## Risks / Trade-offs

- **preflight 增加 attach 前延迟** → 探针全部异步 + 并行同层，且只在 L2 强制；
  实测目标 < 1s。若超时，按 P6 宁可放行并标注「未判定」也不阻塞主循环。
- **探针本身可能是新的失败源**（探针错 → 误阻断能跑的 attach）→ 逃生开关 +
  探针失败默认「未判定」而非「红灯」，只有**明确拒绝证据**（如 rc=126 + 拒绝文本）才判红。
  宁可漏拦，不可误拦。
- **新增 spawn 撞 `host_resource_discipline` 精确计数** → 已知，显式抬计数并写理由
  （本月已踩过一次，见 K60 记录）。
- **层归属可能被误判并写进 evidence** → 四元组要求 evidence 是**命令 + 输出**，
  不是结论文本；误判时证据本身可推翻结论。
- **`commands_spec` 命令冻结清单 82 → 84** → 记得同步，否则 `commands` filter 立刻 FAIL。
- **五层可能不够/过多** → 分层来自 34 条真实坑的归类（A 9 / B 10 / C 6 / D 8），
  L0–L4 覆盖 A+B+部分 C；D（我们自己的 bug）不设层，因为它们本来就在本仓可修。
  若出现无法归类的坑，spec 已留 `UNDETERMINED`。

## Migration Plan

1. **规则先落地**（纯文档 + spec + `structure` 回归）——使后续实现有可引用的权威。
2. `failure.lua` + 回归：老发出点**逐步**迁移，`dap_failure_layer_spec` 先只断言新入口，
   避免一次性改 71 处调用点。
3. `capability.lua` + `preflight.lua` + `:UEDAPPreflight`（不接入 attach，先可独立运行）。
4. attach 接入 L2 门禁 + 逃生开关。
5. `:UEDAPSmoke` + 脱敏证据。
6. 拆分 `android.lua`。

**回滚**：每步独立可回滚。步 4 是唯一改变既有 attach 行为的步骤，逃生开关
`UE_DAP_SKIP_PREFLIGHT=1` 即为运行期回滚。

## Open Questions

- iOS 侧探针集合尚未枚举（L2 对 Apple 是「设备信任 / 开发者模式 / 签名」而非 uid/SELinux）。
  可后补：spec 的层定义是 target-agnostic 的，iOS 探针注册不改 spec、不改任务拆分。
- `:UEDAPSmoke` 是否纳入 `Tasks` 任务注册表（长跑可取消）待定；不影响本 change 的契约。
