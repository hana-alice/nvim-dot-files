# 让 spec 真正生效，并收敛 spec ↔ 实现的既有漂移

## Why

本次审计发现两类真实问题，二者互为因果：

**① spec 与实现已经漂移，且没人拦得住。** 全量回归 `nvim --headless -l tests/run.lua`
当前 **8 条 FAIL（1074/1082）**，也就是说仓库处在「Definition of Done 第 1 条不满足」的
状态却仍在继续开发；`openspec validate --all` 却 37/37 全绿——说明**结构合法性校验永远
不会发现 spec 与实现的语义漂移**。同时至少 3 处 spec/规则文档指向已不存在的文件
（`docs/plans/2026-06-03-android-dap-handshake-rootcause.md`、
`openspec/changes/establish-ue-platform-workflow-boundaries/*`、
`scripts/test_cached_grep.lua`），5 处 spec 仍以 `CLAUDE.md` 为「本地规则内容源」描述
（实际内容源早已改为 `AGENTS.md`，`CLAUDE.md` 只是 `@AGENTS.md` stub）。

**② spec 对三个 agent 都不是「第一时间自动读到」的东西。** 根 `AGENTS.md` 的
SESSION START 只强制读 `docs/CONSTRAINTS.md` / `memory/project_overview.md` / 目录本地规则，
**从未把 `openspec/specs/` 列为必读或必须遵循的权威**；22 份目录级 `AGENTS.md` 里只有 3 份
提到 openspec。结果是：spec 是「写完就躺在 `openspec/specs/` 里的文档」，agent 改代码时
既不会主动读它，也没有任何机制在它与实现分叉时报警。三个 agent 的加载路径已验证：

| agent | 自动读到的项目上下文 | 现状 |
|---|---|---|
| Claude Code | 根 + 目录 `CLAUDE.md`（`@AGENTS.md` 展开） | ✅ 读到 AGENTS.md，✗ 不读 spec |
| Codex | 根 + 目录 `AGENTS.md`（原生） | ✅ 读到 AGENTS.md，✗ 不读 spec |
| pi | `AGENTS.md`/`CLAUDE.md`，逐级向上拼接；`AGENTS.override.md` 优先 | ✅ 读到 AGENTS.md，✗ 不读 spec |

三者的公共交集恰好是 `AGENTS.md`（单一内容源已经建好），所以**「让 spec 生效」的正解不是
再加第四份文件，而是把 spec 提升为 SESSION START 的一等公民，并用回归把这条纪律钉死**。

Why now：漂移已经导致全量回归红着继续开发，这正是「政策存在但不生效」的典型故障模式；
不修就会继续累积不可归因的 FAIL。

## What Changes

- **把 `openspec/specs/` 写入 SESSION START 强制前置**：根 `AGENTS.md` 的 SESSION START
  增加一步「读改动范围对应的 spec」，并在 Definition of Done 增加一条硬条件「改动落地后
  spec 与实现一致（同步 spec 或立 change）」。三个 agent 因此同时生效，无需新增入口文件。
- **建立 spec 覆盖导航（capability → 代码/测试 owner）**：新增一张 capability ↔ 目录 ↔
  必跑 filter 的映射，使 agent 从「我要改 `lua/ue/dap/`」能一步找到 `dap-platform-dispatch`
  等对应 spec，而不是遍历 37 份 spec。
- **每个目录级 `AGENTS.md` 声明其治理 spec**：在各目录规则的「先读」段落中补上该子系统
  对应的 `openspec/specs/<capability>/spec.md` 指针。
- **新增 spec 引用完整性回归**：把「spec 与规则文档里的仓内路径引用必须存在」变成
  `structure` filter 下的可执行断言，杜绝再出现悬空的 `docs/plans/...`、已归档 change 路径。
- **修掉审计发现的既有漂移**：
  - 5 份 spec 里的「本地规则内容源 = `CLAUDE.md`」表述更正为 `AGENTS.md` 源 + `CLAUDE.md` stub
    （**这是 spec 修实现之外的反向修正：实现是对的，spec 落后了**）。
  - `local-subsystem-rules` / `structure-discoverability-regression` 的主要目录清单补齐
    实际存在且已被回归覆盖的 `lua/ue/index`、`lua/ue/targets`、`lua/ue/workflows`、
    `lua/trouble`、`lua/nio`。
  - `android-dap-handshake-diagnostics` 对已随历史脱敏删除的 `docs/plans/...` 的产出物要求，
    改为记录该产出物的现状（已随公开镜像脱敏移除）而不是继续要求一个不存在的文件。
  - `probe-feedback-loop` 补上实际已实现但 spec 未声明的 `:UEProbeCompact`。
- **收敛 8 条 FAIL**：区分「宿主相关（Windows 上跑 macOS-only 断言 / 命中本机真实
  `C:\WINDOWS\adb.EXE`）」与「真实实现漂移」两类，前者按 host 能力守卫用例（spec 已要求
  fail closed，而非要求测试假装宿主具备该工具），后者修实现或修 spec。

不改动：不引入新依赖、不新增第四份 agent 入口文件、不改 openspec CLI 与 schema。

## Capabilities

### New Capabilities

- `spec-authority-loop`: 定义 spec 在开发循环中的权威地位与生效机制——SESSION START 必读
  范围内 spec、Definition of Done 含 spec 一致性、capability→目录→filter 覆盖导航、
  三 agent（Claude/Codex/pi）通过唯一内容源 `AGENTS.md` 同时生效、以及 spec 引用完整性的
  可执行守护。

### Modified Capabilities

- `test-regression-policy`: Definition of Done 增加第 4 条硬条件「spec 与实现一致」，并要求
  Validation 字段同时记录 spec 一致性处置；SESSION START 协议块的必读序列增加 spec 一步。
- `structure-discoverability-regression`: 新增「spec 引用完整性回归」要求（spec 与关键规则
  文档中的仓内路径引用必须存在）；主要目录清单与实际回归覆盖对齐。
- `local-subsystem-rules`: 本地规则内容源更正为 `AGENTS.md`（`CLAUDE.md` 为 `@AGENTS.md`
  stub）；每份目录规则须声明其治理 spec 指针；目录清单补齐 index/targets/workflows/trouble/nio。
- `project-constraints-doc`: `docs/CONSTRAINTS.md` 导航中枢须同时指向 `openspec/specs/`
  与 capability 覆盖映射；本地规则表述更正为 `AGENTS.md` 源。
- `ai-knowledge-base`: `memory/project_overview.md` 的「先读顺序」纳入 spec 一步，并更正
  本地规则内容源表述。
- `probe-feedback-loop`: 补齐已实现的 `:UEProbeCompact` 手动精简命令要求。
- `android-dap-handshake-diagnostics`: 诊断产出物要求与公开镜像脱敏后的实际文件状态对齐。

## Impact

- 文档/规则：根 `AGENTS.md`（SESSION START + DoD）、`docs/CONSTRAINTS.md`、
  `memory/project_overview.md`、`docs/testing-regression.md`、`tests/AGENTS.md`、
  22 份目录级 `AGENTS.md`（补 spec 指针）。`CLAUDE.md` 全部保持 `@AGENTS.md` stub 不动。
- Spec：新增 `spec-authority-loop`；修改上列 7 个既有 capability 的 delta。
- 回归：`tests/cases/structure_spec.lua` 新增 spec 引用完整性与 capability 覆盖断言；
  `platform_spec.lua`、`ue_context_spec.lua`、`ue_api_spec.lua`、
  `ue_target_integration_spec.lua` 的 8 条 FAIL 收敛。
- 运行时：`lua/**` 仅在 8 条 FAIL 被判定为真实实现漂移时才改动；默认零运行时行为变化。
- Agent：Claude Code / Codex / pi 三端通过既有唯一内容源同时获得新纪律，无新增入口文件、
  无 per-agent 分叉维护。
