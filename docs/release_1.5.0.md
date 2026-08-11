# hana-alice/nvim 1.5.0 — Minor Release

> Version: 1.5.0
> Repo:    https://github.com/hana-alice/nvim-dot-files
> Platform: macOS validated; portable headless schema for Windows/Linux
> Date:    2026-08-11
> Type:    Minor release (non-mutating core functionality health audit)

---

## One-line summary

Neovim now has one isolated, machine-readable health audit for real config startup, editing, mandatory Tree-sitter ASTs, rg/csearch, clangd/CDB, UE target plans and explicitly supplied live evidence.

## Release gate

- Full regression: `nvim --headless -l tests/run.lua` → **803/803 passed**.
- `core_health`: **28/28 passed**, including real `-u init.lua` startup, two consecutive audits, CLI parsing,
  caller-owned directory preservation, invalid/missing parser behavior and read-only live provenance/freshness fixtures.
- Real deterministic audit: startup/editor/C/C++/HLSL AST/rg/CDB/five target plans/cleanup all `PASS`.
- Current external gates are explicit: csearch/cindex are absent and Apple clangd 17.0.0 does not satisfy 22.1.x,
  so the machine report is `DEGRADED`, not a false all-green result.
- Scoped `stylua --check`, `git diff --check`, commands/cheatsheet/smoke/structure/task-registry and code-search
  regressions pass.
- Git tag `v1.5.0` is intentionally pending explicit user confirmation.

---

## Working log (sliced from docs/changelog.md Unreleased)

### 2026-08-11 — 为 Neovim 基本能力建立隔离、只读、可判定的健康审计

**Task**

检查 Neovim 的真实启动、基本编辑、csearch/rg、Tree-sitter 语法树、clangd/CDB 与 UE 集成是否正常；
对外部工具缺失给出准确 gate，不安装、不更新、不触发 UE build/device/DAP。

**Implemented**

- `lua/utils/core_health.lua` 定义稳定 report schema、状态聚合、filter、脱敏、deadline/异常隔离、退出码、
  文本/JSON 输出及异步 `:NvimCoreHealth[!] [filter]`；交互入口只启动登记到 task registry 的 headless 子进程。
- `lua/utils/core_health_checks.lua` 在唯一临时目录执行真实 `init.lua` 启动、create/edit/write/reopen、
  从 Tree-sitter plugin spec 派生的 C/C++/HLSL AST、公共 search dispatcher、实际 clangd 版本、fixture CDB
  和 Android/IOS/Linux/Mac/Win64 独立 target build plan；不存在的 caller-owned 目录才允许创建和清理。
- `lua/utils/core_health_live.lua` 只在显式 `--live` context 下读取既有 tuple/CDB/index/provenance，检查
  tuple identity 与 index freshness；可选查询既有 csearch index、复用既有 C++ semantic smoke，但不修复工件。
- `scripts/nvim_core_health.lua` 提供稳定 headless CLI：人类输出、`--json`、`--filter`、`--live` 和明确退出码。
- `NVIM_CORE_HEALTH_NO_MUTATE=1` 关闭 startup probe 的 ShaDa 清理、Lazy missing install、update checker 和
  change detection；cache/state 另行定向到 runner 临时目录，startup 仍加载真实 init、critical commands、
  VeryLazy keymap，并验证重复 health setup 幂等。
- `utils.code_search.build_index` 返回向后兼容的 stop function，使临时 cindex probe 超时后可终止；现有调用方可继续忽略返回值。
- 新增 28 条 `core_health` 回归和 C/C++/HLSL/search fixtures；命令冻结清单加入 `:NvimCoreHealth`，同步
  README、中英文说明、cheatsheet、testing map、architecture、memory 与 OpenSpec change。

**Pitfalls / Gotchas**

- `nvim -l` 不加载用户 init，因此 startup evidence 必须显式子进程 `--headless -i NONE -u <config>/init.lua`。
- health startup 若允许 Lazy missing-install/checker/change detection，审计本身会改变配置现场；只禁止写还不够，
  还要在启动前确认 lazy.nvim 已存在，缺失时报告 `BLOCKED` 而不是 bootstrap clone。
- Tree-sitter parse 与 clangd compiler semantics 是两个独立 capability；本机真实 AST 全部通过时，旧 clangd
  只阻塞 compiler check，不能篡改 syntax 结论。
- 既有 csearch index 的 public dispatcher 带 staged recovery 行为；live query 只在主 index 已经可用时执行，
  避免审计触发恢复写入。临时 deterministic index 则完全位于 runner-owned 目录。

**Validation**

- `nvim --headless -l tests/run.lua core_health` → **28/28 passed**。
- `utils` 44/44、`ue_goto_behavior` 4/4、`ue_paths` 9/9、`commands` 94/94、`cheatsheet` 129/129、
  `smoke` 18/18、`structure` 39/39、`task_registry` 15/15 passed。
- `nvim --headless -l tests/run.lua` → **803/803 passed**。
- `nvim --headless -i NONE -l scripts/nvim_core_health.lua --json` → deterministic `DEGRADED`；所有 required
  deterministic checks `PASS`，仅 csearch/cindex 与 clangd 22.1.x 为 `BLOCKED`，live checks 为 `SKIP`。
- `:NvimCoreHealth` 的真实异步 callback smoke 返回 `PASS`（syntax filter，3 parser checks + cleanup）。

**Follow-ups**

- 安装 csearch + cindex-uefilter 后重跑真实临时 index round trip；当前仅 rg fallback 有本机执行证据。
- 安装或选择 clangd 22.1.x，并在显式提供脱敏 live spec 时复验真实 UE CDB/index/semantic context。
- OpenSpec CLI 当前不可用；change 文件与任务状态已更新，但 archive/strict validation 留待工具可用时执行。

---

## Compatibility and limits

- `DEGRADED` exits zero because deterministic editor capabilities passed and only external prerequisites are blocked;
  any deterministic `FAIL` exits non-zero.
- Live checks require explicit artifact identities. They never discover, build, install, update, package, deploy, launch,
  attach to a device, or rewrite a workspace.
- The report redacts home/config/temp roots and sensitive identity fields; evidence records basenames, versions, counts and booleans.

## Files and ownership

- Report/orchestration: `lua/utils/core_health.lua`.
- Deterministic probes: `lua/utils/core_health_checks.lua`.
- Explicit live probes: `lua/utils/core_health_live.lua`.
- CLI: `scripts/nvim_core_health.lua`.
- Regression: `tests/cases/core_health_spec.lua`, `tests/fixtures/core_health/`.
- Usage and contracts: `docs/core-health.md`, README/cheatsheet/testing docs, architecture/memory and
  `openspec/changes/add-nvim-core-functionality-audit/`.
