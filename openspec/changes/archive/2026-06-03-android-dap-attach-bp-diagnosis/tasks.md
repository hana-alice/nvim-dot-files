## 1. 固化现状事实（只读分析）

- [x] 1.1 记录 attach 路径事实：`android.lua` `attach_commands`/`_finalize_session` 用 `gdb-remote 127.0.0.1:<port>`（gdbserver 模式），host adapter = LLVM 22.1.6 `C:/tools/lldb-22/install/bin/lldb-dap.exe`。
- [x] 1.2 记录 F9 短路事实：`lua/ue/dap.lua` ~1958 `session_mod.request` 拦截 `setBreakpoints` → `ue_android_synthetic_breakpoint_response`（`verified=false`）。
- [x] 1.3 记录 preseed 被注释事实：`android.lua` ~1225 `preseed_breakpoints_into_attach_commands(cfg)` 已注释。
- [x] 1.4 记录 ASLR 缺失事实：`android.lua` 无 `target modules load --slide`，对照 `docs/CONSTRAINTS.md` K2/K11。
- [x] 1.5 汇总已知证据：从 `docs/changelog.md`（2026-06-02 多条）摘录 `Cannot get process architecture` / `lost connection` / `TracerPid` 未设 等设备端边界证据。

## 2. 撰写诊断文档

- [x] 2.1 创建 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 头部（背景、设备 serial、约束引用 `docs/CONSTRAINTS.md`）。
- [x] 2.2 写"现状事实"小节（任务组 1 的 5 条）。
- [x] 2.3 写"attach 失败分层假设"：host adapter / adb·forward / 设备端 lldb-server / ptrace·进程架构，每层给验证命令 + 判定标准（已用 `a3ad86f3` 真机验证）。
- [x] 2.4 写"F9 断不上"小节：合成 setBreakpoints + 注释 preseed 两处直接原因 + 接通断点的判定标准（DAP `verified=true` 且 lldb `breakpoint list` resolved>0）。
- [x] 2.5 写"ASLR slide 缺失"小节：`image list libUE4.so` base vs `/proc/<pid>/maps` 首映射的比对法（device base 实测 `0x6c9fe21000`）。
- [x] 2.6 写"排查顺序与修复路线建议"：先 attach 稳定到 `initialized`+`threads`，再接通断点（preseed vs 安全 post-attach），必要时先补 `--slide`；每步需 fresh protocol log。
- [x] 2.7 写"不改运行时边界"声明：22.1.6+ forward-only、`stopOnEntry`、无 `process continue`、SIGSEGV/SIGBUS 策略不变。

## 3. 核验

- [x] 3.1 运行 `git status`，确认仅 `docs/plans/`、`openspec/` 改动，无 `lua/ue/dap/*.lua` 改动。
- [x] 3.2 核对文档每条假设都有可执行验证命令与期望输出；设备验证均限定单一 serial（`a3ad86f3`）。
- [x] 3.3 `openspec validate android-dap-attach-bp-diagnosis` 通过。
