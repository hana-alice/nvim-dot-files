## Why

用户明确要求：**走通 lldb-server platform 模式**作为 UE Android DAP 的正式 attach 路径，
因为需求复杂、对标 IDE，未来还会扩展（platform 模式天然支持 file transfer、多进程、
launch、qLaunchGDBServer 等 gdbserver 模式没有的能力）。

诊断（`docs/plans/2026-06-03-...`，真机 ANDROID-SERIAL-A）已证明当前 `lldb-server gdbserver
--attach` 路径的硬缺陷：**`--attach` 形态从不绑定监听端口**（ptrace 附上但永不进入
listen+serve），host 握手零响应 → attach 永远超时。而 `lldb-server platform --server
--listen` 与纯 `gdbserver`（无 --attach）实测**正常绑定 + gdb 握手全通**。

用户授权：除"host adapter 必须 LLDB 22.1.6+"这一条外，其余原则（workaround 隔离、
最小改动、不碰 nvim 外等）本任务内可放宽，目标是**把 platform 模式真正跑通**。

## What Changes

- **device server 改用 platform 模式**：`lua/ue/dap/android.lua` 用
  `files/lldb-server platform --server --listen 127.0.0.1:<pport>` 启动 platform
  server（替代 `gdbserver --attach`），并 `adb forward` platform 端口。
- **lldb-dap attach 改 platform 流程**：attachCommands 改为
  `platform select remote-android` → `platform connect connect://127.0.0.1:<pport>`
  → `target create <symbol so>` → `process attach --pid <pid>` →（信号处置）→
  `target modules load --slide 0x<base>`。platform 模式下 lldb 自己 spawn 子 gdbserver
  并完成 qLaunchGDBServer 握手。
- **device server 版本对齐**：platform 的 qLaunchGDBServer 握手对 LLDB 版本敏感
  （历史 changelog 记录过 version-mismatch deadlock）。按真机 probe 结论选定可用的
  device LLDB（NDK21 LLDB9 / r29 LLDB21 / 其它），并据此调整
  `default_lldb_server_paths()` 优先级与 `docs/TOOLING.md`。
- **断点机制**：platform attach 稳定后，按真机验证决定 source-file `breakpoint set`
  是否仍崩；若崩则用 address 断点（`image lookup --line` → `breakpoint set --address`）。
  本 change 以 attach 跑通为主，断点接通作为后续验证项。
- **文档**：`docs/TOOLING.md` + `docs/CONSTRAINTS.md` 更新为 platform 模式正式路径，
  并记录 gdbserver `--attach` 不可用的结论；`docs/plans/` 增补 platform 模式设计与证据。

## Capabilities

### New Capabilities
<!-- 无新 capability。 -->

### Modified Capabilities
<!-- 无 spec 级既有 capability（DAP 行为未 spec 化）。本 change 为实现层重构 + 文档。 -->

## Impact

- **修改的 nvim 配置文件**：
  - `lua/ue/dap/android.lua`：server 启动改 platform 模式；attach 配置改 platform 流程。
  - `lua/ue/dap.lua`：会话识别 / 入口停顿 / 断点响应按 platform 路径调整（含消除
    `Source missing`）。
  - `lua/utils/platform/windows.lua`：device server 候选与优先级按 platform 模式可用版本调整。
- **文档**：`docs/TOOLING.md`、`docs/CONSTRAINTS.md`、`docs/plans/2026-06-03-...`。
- **保留不变**：host adapter LLDB **22.1.6+ forward-only**（用户唯一硬约束）。
- **可放宽（用户授权）**：其余项目原则（workaround 隔离、最小改动、不碰 nvim 外、
  `stopOnEntry`/信号处置等既有边界）在本任务内可按"跑通 platform"需要调整，但每处改动
  需有真机 protocol log 支撑、不是盲改。
- **设备验证范围**：仅 `ANDROID-SERIAL-A`（arm64-v8a / Android 16 / SELinux Enforcing），
  目标 `<android-package>`。
- **成功判定**：`<space>da` platform attach 到 `initialized` + `threads`、无 attach
  超时/`3221226505`；F9 断点 `verified=true` 且 lldb `breakpoint list` resolved>0、
  命中停在正确源码行；连上无 `Source missing`。
