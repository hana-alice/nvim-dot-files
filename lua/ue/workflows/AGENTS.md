# lua/ue/workflows/ — target workflow owners and runtime seams

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。

## 用途

把 target workflow owner、immutable snapshot 和 policy-free runtime 放在单独目录，
作为 `ue.lua` façade 与 `ue.targets` planner 之间的运行时边界。

## 专属约定

- **registry 只按 `(target, operation)` 精确匹配**：不得跨 target fallback，不得把 host/target 兼容性写成硬编码分支。
- **兼容性先走 `ue.targets.resolve`**：workflow dispatch 只能复用 target driver 的 `host_operations` matrix，不能自行猜测可执行组合。
- **snapshot 必须 immutable**：workflow 开始后冻结 canonical project / target / configuration / host / identity / owner；异步回调、poller、cleanup、persistence 只吃 snapshot。
- **runtime 必须 policy-free**：这里只做 task 执行、project-change guard、cancel/cleanup、state seam；不得写 target 名、设备 backend 选择或 signing/install/launch 策略。
- **无 load-time `require("ue")`**：本目录模块不得在加载期依赖 `lua/ue.lua` 主 façade。

## 改动 → 必跑回归

- 改 `workflows/**` → `ue_workflows` `ue_target_tasks` `structure`
- 如 dispatch/compatibility 与 target driver 契约交界被改动，再补 `ue_target_drivers`

## 先读

`../../../openspec/specs/ue-target-workflow-boundary/spec.md`（治理本目录的 capability）、
`../../../openspec/specs/ue-target-driver-boundary/spec.md`、
`../../../openspec/changes/archive/2026-08-24-establish-ue-platform-workflow-boundaries/design.md`
