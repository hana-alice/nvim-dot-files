## Context

诊断报告 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 已在真机 `a3ad86f3` 定位三个根因并验证了关键修复假设。本 design 说明如何在 **nvim 配置内**最小改动落地，且把环境要求落到 `docs/TOOLING.md`。

现状代码事实：
- `lua/ue/dap/android.lua:609` spawn：`cd files && ./lldb-server gdbserver --attach <pid> *:<port>`（run-as）。
- `lua/ue/dap/android.lua:1225` `preseed_breakpoints_into_attach_commands(cfg)` 被注释。
- `lua/ue/dap.lua:1954-1967` 把 Android `setBreakpoints` 拦截为 `verified=false` 合成响应。
- `lua/ue/dap/android.lua` 无 `target modules load --slide`。
- `lua/utils/platform/windows.lua:100-105` 临时把 Android Studio LLDB19 server 置顶（probe override）。

真机已验证：
- run-as `cd` 不生效（cwd=`/`），`files/lldb-server version` 可执行（LLDB19）。
- NDK21 LLDB 9.0.9 server `gdbserver --attach 22232` tracer 稳定存活、未崩；LLDB18/19 会 Segfault。
- device `libUE4.so` base = `0x6c9fe21000`；host 符号 so 在 `Client_Symbols_v170300916/Client-arm64/libUE4.so`。

约束（`docs/CONSTRAINTS.md`）：host adapter 22.1.6+ forward-only、`stopOnEntry` 不动、无 `process continue`、SIGSEGV/SIGBUS 不动、hex 用拼接禁 `string.format("%x")`、改协议需 protocol proof。

## Goals / Non-Goals

**Goals:**
- attach 能稳定到 `initialized` + `threads`（修 spawn 路径 + 钉死 NDK21 server）。
- F9 file:line 断点真正 resolved（preseed + ASLR rebase + 放开合成短路）。
- 仅改 nvim 配置文件 + 文档；环境要求写入 `docs/TOOLING.md`。
- 全程仅在 `a3ad86f3` 验证。

**Non-Goals:**
- 不改设备系统、UE 工程、host adapter 版本。
- 不切回 codelldb / platform 模式。
- 不引入新依赖；复用现有 push/run-as 暂存逻辑。

## Decisions

**D1 — spawn 用 `files/lldb-server` 相对路径，不用 `cd && ./`。**
run-as cwd 已是 `/data/user/0/<pkg>`，`files/lldb-server` 直接可执行；`cd` 在 `runas_app` 域下静默失效。改 `lua/ue/dap/android.lua` `start_lldb_server_gdbserver` 的命令串即可。备选（绝对路径 `/data/user/0/<pkg>/files/lldb-server`）也可，但相对形式更短且不依赖拼 pkg 路径。

**D2 — device server 钉死 NDK21 LLDB 9.0.9。**
恢复 `default_lldb_server_paths()` 的 NDK21 首选顺序，移除 probe override。理由：与 libUE4.so 构建 NDK 匹配，真机验证 attach 不崩；LLDB18/19 Segfault。这是把临时实验回退到 commit 144c28d 的契约。

**D3 — ASLR rebase 在 attach 成功后注入。**
读 `/proc/<pid>/maps` 首个 libUE4.so 映射 base（优先 LLDB `platform shell` 或 run-as `cat`，已验证 run-as cat 可读），拼 hex（`"0x" .. string.gsub(...)` 或逐位拼接，**禁 `string.format("%x")`**），下发 `target modules load --file libUE4.so --slide 0x<base>`。位置：attach 完成后、断点 resolve 前——与诊断 K11 一致。

**D4 — 接通断点：preseed + 放开合成短路。**
- 解除 `_finalize_session` 中 `preseed_breakpoints_into_attach_commands(cfg)` 注释，让断点作为 attachCommands 内 `?breakpoint set -f <file> -l <N>` 下发（在信号处置之后、诊断验证的安全顺序）。
- `lua/ue/dap.lua` 放开对 Android `setBreakpoints` 的合成拦截：保留路径名 basename 重写（避免 R/rejected），但让响应反映 lldb 真实 `verified`，不再硬编码 false。
- 判定接通：DAP `verified=true` 且 lldb `breakpoint list` resolved>0。
- 风险对冲：若放开合成短路重现 lldb-dap 22 的 `STATUS_STACK_BUFFER_OVERRUN`，回退为"仅 preseed + 合成 verified=true（基于 preseed 已成功）"，二选一由真机 protocol log 决定。

**D5 — 环境要求写 `docs/TOOLING.md`。**
新增/更新 Android device server 段：必须 NDK 21.4.7075529 LLDB 9.0.9，给 host glob 路径与"为何不能用 NDK27/AS bundled"的真机证据。不改 nvim 之外任何东西。

## Risks / Trade-offs

- [放开合成短路触发 lldb-dap 22 崩溃] → D4 回退方案（preseed-only + 合成 verified=true）；先 bare lldb 验 resolved 再走 DAP。
- [ASLR base 读取失败/格式错] → 用 run-as `cat /proc/<pid>/maps`（已验证可读）+ 拼接 hex；失败时 toast 并跳过 rebase，不阻断 attach。
- [NDK21 未安装的机器] → `default_lldb_server_paths()` 仍有 fallback；`docs/TOOLING.md` 记录硬性要求，缺失时报清晰错误。
- [仅单机验证] → 明确范围 `a3ad86f3`；其它设备需各自 protocol proof。

## Migration Plan

1. 改 `lua/ue/dap/android.lua`（spawn 路径 + ASLR rebase + 启用 preseed）。
2. 改 `lua/utils/platform/windows.lua`（NDK21 首选）。
3. 改 `lua/ue/dap.lua`（放开 Android setBreakpoints 合成短路）。
4. 更新 `docs/TOOLING.md` 环境要求。
5. headless 加载 smoke：`nvim --headless -u NONE -c "luafile lua/ue/dap/android.lua" -c qa` 等。
6. 真机 `a3ad86f3` 跑 `<space>da`，取 fresh protocol log，验 `initialized`/`threads`/断点 resolved。
7. 回滚：`git checkout` 这 3 个 lua + `docs/TOOLING.md`；零设备侧残留（push/run-as 暂存自带清理）。

## Open Questions

- D4 最终形态（放开短路 vs preseed-only）取决于真机是否重现 lldb-dap 22 崩溃——apply 时按 log 决定。
- ASLR base 读取走 run-as `cat` 还是 LLDB `platform shell`：两者都验证可行，preseed 阶段在 nvim 侧 run-as 读更简单。
