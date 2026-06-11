# lua/ue/dap/ — DAP 调试（codelldb + Android platform 模式）

> 继承 `../CLAUDE.md`（ue 中枢）→ `../../CLAUDE.md`（lua 总规则）。只写增量。
> ⚠️ 本目录踩坑密度最高，改动前**务必**读 `../../../docs/CONSTRAINTS.md §二 DAP` 全段。

## 用途

UE 专用 DAP：`_common`（adapter 接线 + env 清洗）、`_persist_bp`（断点持久化）、`_progress`、
`platforms`（dispatch 注册表）、`android/win64/mac/linux/ios`（各平台 attach/launch）。

## 专属约定 / 宪法级坑（权威见 CONSTRAINTS §二、§一）

- **codelldb 不用 `request="custom"`** → 用 `launch` + `targetCreateCommands` + `processCreateCommands`。→ P8/K1
- **Android attach 唯一正解**：platform 模式 + `connect://[<serial>]:<port>` serial URL；
  **不用** `gdbserver --attach`（从不 listen）；**不用** localhost URL（被 getopt 吞空）。→ P16/P17/K30–K32
- **ASLR `--slide` 必须在 `processCreateCommands` 内、先于 setBreakpoints**（基于事件太晚）。→ K11
- **不对 64 位 slide 用 `string.format("%x")`**（LuaJIT 截 32 位，用字符串拼接）。→ P7/K4
- **Android 不直接 `dap.terminate`**（会 SIGKILL 游戏）→ detach。→ K5
- **F-key 四模式绑定**（dap-repl 是 prompt buffer）。→ K6
- `platforms` 注册表是唯一 dispatch seam；新平台在此注册，不散落分支。

## 改动 → 必跑回归

改 `dap/**` → `dap` `platform`；改 `_common` 等被多平台共用面 → 提交前全量。
注意 `platforms._reset_for_test` 与 `ue.setup()` 幂等的交互（见 `tests/cases/dap_spec.lua`）。

## 先读

`../../../docs/CONSTRAINTS.md §二`、`../../../docs/TOOLING.md`、
归档 change `openspec/changes/archive/2026-06-03-android-dap-*`。
