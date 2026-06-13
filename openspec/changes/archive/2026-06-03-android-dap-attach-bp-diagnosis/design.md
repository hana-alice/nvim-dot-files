## Context

`<space>da` 在连真机后两层叠加失败，需要在改任何 attach 协议之前先定位。当前事实（只读分析得出）：

- **attach 路径**：`lua/ue/dap/android.lua` 用预先 spawn 的 `lldb-server gdbserver --attach <pid> *:<port>` + lldb-dap `gdb-remote 127.0.0.1:<port>`（不是 platform 模式）。host adapter 固定 LLVM 22.1.6 (`C:/tools/lldb-22/install/bin/lldb-dap.exe`)。
- **已知证据**（`docs/changelog.md` 2026-06-02 多条）：`platform connect` 成功；`process attach --pid` 在设备端报 `Cannot get process architecture`（当前设备 server）或 `lost connection`（NDK r27 server 回归探针）；bare `lldb-server gdbserver --attach` 在设置 `TracerPid` 前就返回/崩溃。说明失败在**设备端 server / ptrace 边界**，不是 dapui。
- **F9 断点链路**：`lua/ue/dap.lua` ~1958 把 Android 会话的 `setBreakpoints` 请求整体拦截，返回 `ue_android_synthetic_breakpoint_response`（`verified=false`，带 "cannot safely plant post-attach source breakpoints" 消息）；`android.lua` ~1225 的 `preseed_breakpoints_into_attach_commands(cfg)` 被**注释掉**。也就是说当前 F9 在 Android 上**根本没有真正下发到 lldb**——这是设计上的"先保 attach 稳定"取舍，不是新 bug。
- **ASLR**：当前 `android.lua` **没有** `target modules load --slide` rebase，而 MEMORY/历史教训（`docs/CONSTRAINTS.md` K2/K11）指出 gdb-remote attach 后必须显式 rebase 模块基址，否则断点解析到错地址。
- **设备**：当前连接 `a3ad86f3`。

约束（`docs/CONSTRAINTS.md`）：不改 host adapter 版本策略（22.1.6+ forward-only）、不动 `stopOnEntry=true`、不在 attachCommands/postRunCommands 加 `process continue`、不动 SIGSEGV/SIGBUS `--pass true --stop false`、改协议前必须有 fresh protocol proof。

## Goals / Non-Goals

**Goals:**
- 把"attach 连不上"与"F9 断不上"两个问题拆成**分层假设**，每层给可执行验证命令 + 判定标准。
- 明确指出代码现状中导致 F9 必然失败的两处（合成 setBreakpoints + 注释掉的 preseed），避免误判为环境问题。
- 给出排查顺序：先确认 attach 能稳定到 `initialized`+`threads`，再谈断点接通。
- 产出 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 作为后续修复的依据。

**Non-Goals:**
- 本阶段不改运行时 `.lua`（不动 attach 协议、断点拦截、信号处置、stopOnEntry）。
- 不重新设计 DAP 栈，不切回 codelldb / platform 模式。
- 不在没有 fresh protocol log 的情况下下结论性"修复"。

## Decisions

**D1 — 诊断先行，代码零改动。** 当前问题分布在设备/ptrace 边界（不可纯靠读码确定）+ 编辑器侧已知短路（可靠读码确定）。先把两类分开记录，避免在错误层面瞎改。备选（直接改 attach 协议）被否，因违反 `CONSTRAINTS` "改协议前需 protocol proof"。

**D2 — 分六层定位潜在问题。** 层次：
1. **host adapter**：lldb-dap.exe 是否 22.1.6、是否成功 spawn（排除 P7/版本回退）。
2. **adb / forward**：`adb forward tcp:<port>` 是否建立、设备是否唯一就绪。
3. **设备端 lldb-server**：版本与可执行性（沙箱 `files/lldb-server version`）、是否被 `run-as` 正确启动、`gdbserver --attach` 是否在设 `TracerPid` 前退出。
4. **ptrace / 进程架构**：`Cannot get process architecture` 指向 server 读取目标 arch 失败——核对目标进程是 64 位（arm64）、server 是 arm64、`/proc/<pid>` 可读、目标非 state T。
5. **模块与 ASLR**：attach 成功后 `image list libUE4.so` 的 base 是否等于 `/proc/<pid>/maps` 首映射；当前缺 `--slide` rebase。
6. **断点注入路径**：确认 `setBreakpoints` 被合成短路、preseed 被注释——这是 F9 不上的**编辑器侧直接原因**。

**D3 — 把"已知必然失败点"显式写进 spec 的可验证 Scenario。** 让后续实现者一眼看到：F9 在 Android 当前是被设计性短路的，不能用"环境问题"解释；接通断点需要在 attach 稳定后选择 preseed（attachCommands 内 `?breakpoint set -f file -l N`）或安全的 post-attach 路径，且很可能需要先补 ASLR rebase。

**D4 — 设备验证限定单一 serial。** 与历史一致（`a3ad86f3`），避免多设备误选（changelog 已有 `<space>ul` 多设备回归）。

## Risks / Trade-offs

- [诊断不动代码，用户问题当下仍未修] → 明确这是 propose 阶段；apply 阶段按结论最小改动，且每步要 protocol proof。
- [设备端根因需 live 复现，读码无法 100% 确定] → 第 3/4 层给出在设备上直接跑的命令（`run-as ... files/lldb-server version`、`cat /proc/<pid>/maps` via platform shell、检查 `TracerPid`），用真实输出判定。
- [误把合成断点响应当成"已接通"] → spec 显式要求验证 `verified` 字段与 lldb 端 `breakpoint list resolved` 数，二者都要为真才算接通。
- [补 ASLR rebase 可能与 lldb-dap 22 的 setBreakpoints 崩溃叠加] → 记为开放项，修复时先 attachCommands 预置、bare lldb 验证 resolved，再回 DAP 路径。

## Migration Plan

1. 写 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md`（六层假设 + 验证命令 + 现状事实）。
2. 不改任何 `.lua`；`git status` 应仅显示 `docs/plans/` 与 `openspec/`。
3. 后续修复另循 propose→apply，按本诊断的层级结论推进，每步附 fresh protocol log。
4. 回滚：`git rm docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md`，零运行时影响。

## Open Questions

- 设备端 `Cannot get process architecture` 的根因：是 `lldb-server` 版本/arch 不匹配，还是 `run-as` 上下文下 `/proc/<pid>` 读取受限？需 live 命令确认。
- 接通断点的最终机制：attachCommands preseed vs post-attach DAP（后者历史上会触发 lldb-dap 22 崩溃）——待 attach 稳定后再决策。
- 是否需要先补 `target modules load --slide` 才能让 file:line 断点 resolved——待第 5 层验证。
