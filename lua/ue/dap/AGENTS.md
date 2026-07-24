# lua/ue/dap/ — DAP 调试（codelldb + Android platform 模式）

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。
> ⚠️ 本目录踩坑密度最高，改动前**务必**读 `../../../docs/CONSTRAINTS.md §二 DAP` 全段。

## 用途

UE 专用 DAP：`_common`（adapter 接线 + env 清洗）、`_persist_bp`（断点持久化）、`_progress`、
`platforms`（dispatch 注册表）、`android/win64/mac/linux/ios`（各平台 attach/launch）。

## 专属约定 / 宪法级坑（权威见 CONSTRAINTS §二、§一）

- **codelldb 不用 `request="custom"`** → 用 `launch` + `targetCreateCommands` + `processCreateCommands`。→ P8/K1
- **Android attach 唯一正解**：platform 模式 + `connect://[<serial>]:<port>` serial URL；
  **不用** `gdbserver --attach`（从不 listen）；**不用** localhost URL（被 getopt 吞空）。→ P16/P17/K30–K32
- **ASLR `--slide` 必须在 `processCreateCommands` 内、先于 setBreakpoints**（基于事件太晚）。→ K11
- **ASLR `--slide` 是 load-bearing，别删**：真机 `UE_DAP_NO_SLIDE=1` 复验显示去掉它 attach 直接
  超时 / adapter `3221226505`。删除前必须在目标设备复验「无 slide 仍 resolved+命中」。→ K37
- **不对 64 位 slide 用 `string.format("%x")`**（LuaJIT 截 32 位，用字符串拼接）。→ P7/K4
- **Android 不直接 `dap.terminate`**（会 SIGKILL 游戏）→ detach。→ K5
- **F-key 四模式绑定**（dap-repl 是 prompt buffer）。→ K6
- **会话中 F9 即时下断点 = 正解，经 lldb-dap evaluate backtick `breakpoint set -f/-l` 通道**
  （`ue_android_live_plant_via_evaluate` in `../dap.lua`），不再 `:UEDAPReattach`、不 detach+reattach、
  不假 `verified`（回读 `breakpoint list resolved=N`，0/失败则诚实 warn）。preseed 降级为初始快照。→ K36
- **launch = wait-for-debugger（AS debug 按钮语义）**：`am set-debug-app -w` 冻住 JDWP 闸门 →
  K30 attach（此时 libUE4.so 未加载，attach-time slide 拿不到属**预期**）→ 首次 continue 时
  jdb 释放闸门 + late-rebase poller 经 evaluate 通道补发显式 slide（K37 语义「晚到」而非「缺席」）。
  任何退出路径必须 `am clear-debug-app`（粘性标志会冻住后续手动启动）。失败经 `wait_notice`
  每会话去重记录（notify + ue-dap-bp-diag.log）。
- **nvim-dap 没有 before-request hook**：`listeners.before.setBreakpoints` 在响应管线触发
  （签名 `session, err, response, request, seq`），**不能**改 outgoing `args.source`；恢复请求行须读
  `request` payload。别再起 `*_source_rewrite` 这种暗示 wire-mutation 的命名。
- **合成帧绕路收敛到单一 chokepoint**（`before.stackTrace` 把合成帧置 `line=-1`）；`_frame_set` patch
  与 bp-response remap 是薄 defence-in-depth。改前看 `dap.lua` 的 `ANCHOR(ue-synthetic-frame-guard)`。
- `platforms` 注册表是唯一 dispatch seam；新平台在此注册，不散落分支。

## 改动 → 必跑回归

改 `dap/**` → `dap` `platform`；改 `_common` 等被多平台共用面 → 提交前全量。
注意 `platforms._reset_for_test` 与 `ue.setup()` 幂等的交互（见 `tests/cases/dap_spec.lua`）。

## 先读

`../../../docs/CONSTRAINTS.md §二`、`../../../docs/TOOLING.md`、
ADR `../../../docs/plans/2026-06-15-android-dap-live-breakpoints.md`（live 断点决策 + 不变量）、
归档 change `openspec/changes/archive/2026-06-03-android-dap-*` / `2026-06-15-android-dap-live-breakpoints`、
真机证据 `../../../tools/evidence/android-f9/`。
