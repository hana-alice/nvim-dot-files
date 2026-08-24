# Android DAP attach 失败 + F9 断点失效 · 诊断报告

> **状态：Historical / superseded evidence。** 本文冻结 2026-06-02 的失败现场，
> 其中 sandbox `gdbserver --attach`、F9 short-circuit 与固定设备 serial 不是现行实现要求。
> 当前路线以 [`android-dap-attach`](../../openspec/specs/android-dap-attach/spec.md)、
> [`android-dap-live-breakpoints`](../../openspec/specs/android-dap-live-breakpoints/spec.md)
> 和 `docs/CONSTRAINTS.md` K30/K36/K37 为准：设备端使用 `lldb-server platform`，
> session 捕获显式 serial，active-session F9 走 live 通道且不要求 reattach。

> 日期: 2026-06-02
> 历史取证设备: **仅在 `a3ad86f3` 上验证**（证据范围，不是脚本默认值；abi `arm64-v8a`, sdk 36 / Android 16, SELinux Enforcing）
> 目标进程: `<android-package>`（DEBUGGABLE，run-as 可用，idle 时 `State=S` `TracerPid=0`，Threads=17）
> 约束: 遵守 `docs/CONSTRAINTS.md` —— host adapter 22.1.6+ forward-only、`stopOnEntry=true` 不动、
>   attachCommands/postRunCommands 不加 `process continue`、SIGSEGV/SIGBUS `--pass true --stop false` 不动、
>   改协议前需 fresh protocol proof。
> 关联代码: `lua/ue/dap/android.lua`、`lua/ue/dap.lua`、`lua/ue/dap/_common.lua`、`lua/ue/dap/_persist_bp.lua`

---

## 0. 一句话结论

attach 连不上有**两个独立的设备端根因**叠加，F9 断不上是**编辑器侧的设计性短路**（与设备无关）。
其中第一个 attach 根因是**确定性 bug**，可直接修；第二个是 lldb-server 在该目标上 `gdbserver --attach`
崩溃，需要换 server / 换路径验证。

---

## 1. 现状事实（只读代码分析）

| # | 事实 | 位置 |
|---|------|------|
| F1 | attach 走预 spawn `lldb-server gdbserver --attach <pid> *:<port>` + lldb-dap `gdb-remote 127.0.0.1:<port>`（非 platform 模式）。 | `android.lua` `start_lldb_server_gdbserver` / `attach_commands` / `_finalize_session` |
| F2 | 设备端 spawn 命令为 **`cd files && ./lldb-server gdbserver --attach %d \*:%d`**，用 `run-as <pkg> sh -c`。 | `android.lua:609-610` |
| F3 | host adapter 固定 LLVM 22.1.6（`C:/tools/lldb-22/install/bin/lldb-dap.exe`），forward-only。 | `lua/utils/platform/windows.lua` / `docs/changelog.md` |
| F4 | **F9 被合成短路**：Android 会话的 `setBreakpoints` 被 `session_mod.request` 包装拦截，直接返回 `verified=false` 的合成响应。 | `lua/ue/dap.lua:1954-1967` `ue_android_synthetic_breakpoint_response` |
| F5 | **preseed 被注释**：`preseed_breakpoints_into_attach_commands(cfg)` 在 `_finalize_session` 中被注释掉，断点未作为 attachCommands 下发。 | `android.lua:1225` |
| F6 | **无 ASLR rebase**：`android.lua` 全文无 `target modules load --slide`，与 `docs/CONSTRAINTS.md` K2/K11 冲突。 | `android.lua`（grep 计数 0） |

---

## 2. attach 失败 —— 分层定位（真机已验证）

### 层 1: host adapter ✅ 正常
- 设备唯一就绪（`adb -s a3ad86f3 get-state` = device）。
- host adapter 版本策略不在本次失败链路上（失败发生在设备端，见层 3/4）。

### 层 2: adb / forward ✅ 正常
- `adb -s a3ad86f3 forward tcp:<port> tcp:<port>` 建立成功（rc=0）。
- run-as 可用，uid = `u0_a429`，SELinux context = `runas_app`。

### 层 3: 设备端 lldb-server 可执行性 ⛔ **确定性 bug #1**

**症状（真机复现）**：
```
$ adb -s a3ad86f3 shell run-as <pkg> sh -c 'cd files && ./lldb-server version'
/system/bin/sh: ./lldb-server: inaccessible or not found
```
但绝对/相对前缀路径可执行：
```
$ adb -s a3ad86f3 shell run-as <pkg> sh -c 'files/lldb-server version'
lldb version 19.0.1   ← OK
```

**根因**：在 `runas_app` SELinux 域下，`sh -c 'cd files && ...'` 里的 **`cd` 不生效，cwd 仍是 `/`**
（已验证：`cd /data/user/0/<pkg>/files && pwd` 打印 `/`）。于是 `./lldb-server` 在 `/` 下找不到。
这正是 `android.lua:609` 用的形式（F2）。`docs/changelog.md` 早有同类记录："run-as ... `PWD=/`，`mkdir files` 在只读 `/` 上失败"——同一个 cwd 陷阱，这次出现在**启动 server** 这一步。

**判定**：这是 attach 第一道门，命令字符串本身在该设备上就跑不起来。

**修复方向（apply 时最小改动）**：把 spawn 命令从 `cd files && ./lldb-server ...` 改成
`files/lldb-server gdbserver ...`（相对包数据根的路径，run-as cwd 已是 `/data/user/0/<pkg>`），
或用绝对路径 `/data/user/0/<pkg>/files/lldb-server`。**不改 attach 协议本身**。

### 层 4: ptrace / gdbserver attach 稳定性 ⛔ **根因 #2（间歇/崩溃）**

即使绕过层 3 用可执行路径，`gdbserver --attach` 在该目标上**不稳定**：

**症状（真机复现）**：
```
$ run-as <pkg> sh -c 'files/lldb-server gdbserver --attach 22232 *:<port>'
PLEASE submit a bug report to https://github.com/android-ndk/ndk/issues ...
Stack dump:
0. Program arguments: ./lldb-server gdbserver --attach 22232 *:15040
Segmentation fault          ← exit 139
```
- LLDB 19（沙箱 server）与 LLDB 18（NDK r27 server）**都出现过 attach 崩溃**。
- 崩溃后会残留 `lldb-server` 进程并把目标 `TracerPid` 置为非 0（如 23570），需 `killall lldb-server` 清理，
  否则目标被 stale tracer 占住。已验证清理后 `TracerPid` 回 0、`State=S`。
- 轮询观察：attach 启动后目标短暂 `TracerPid=<server>` 且 `State=S`，但 server 进程随后崩溃 /
  超时无 `Listening` 输出 → host 侧 `gdb-remote` 拿不到稳定连接 → lldb-dap `process attach` 报
  `Cannot get process architecture` / `lost connection`（与 `docs/changelog.md` 2026-06-02 记录一致）。

**判定**：层 4 是真正的 attach 拦路虎，且属设备/server 二进制层面，**不能纯靠改 nvim 代码解决**。

**待验证项（apply 阶段在 `a3ad86f3` 上做）**：
- 换 server 二进制：NDK 21 LLDB（历史 changelog 称其在 platform 模式有过成功）、Android Studio bundled、termux server 逐一试 `gdbserver --attach`，记录哪种不崩。
- 换 attach 方式：`gdbserver --attach <pid>` vs 先 `platform` 再 attach（注意 changelog 记录 platform 模式在本机 `process attach` 也 `lost connection`，故两条路都需 fresh log）。
- 缩小目标：对同 uid 的小进程（如 `:pushservice` pid）attach，区分"是 UE 大进程特性"还是"server 普遍崩"。本次对 pushservice 也未拿到干净 `Listening`（超时），倾向 server 二进制问题而非目标体积。

### 层 5: 模块基址 / ASLR（attach 成功后才生效，预置风险）
- 设备 `libUE4.so` 首映射 base（来自 `run-as <pkg> cat /proc/22232/maps`）= **`0x6c9fe21000`**。
- host 符号 so 存在：`E:/sample/zeqiang_sample_3.4/Source/Client/Binaries/Android/Client_Symbols_v170300916/Client-arm64/libUE4.so`（3192229608 B）。
- 当前代码无 `--slide`（F6）。一旦 attach 通了，file:line 断点很可能仍解析到错地址。
- **验证法**：attach 成功后 `image list libUE4.so` 的 base 应等于 `0x6c9fe21000`；不等就需补
  `target modules load --file libUE4.so --slide 0x6c9fe21000`（hex 用拼接，禁 `string.format("%x")`，见 K4/P7）。

---

## 3. F9 断不上 —— 编辑器侧设计性短路（与设备无关）

两处**代码当前就决定了 F9 不会真正生效**，不要当环境问题排查：

1. **合成 setBreakpoints**（F4）：`lua/ue/dap.lua` 把 Android 会话的 `setBreakpoints`
   整体拦截，返回 `verified=false` + 消息 "UE Android lldb-dap 22.1.6 cannot safely plant
   post-attach source breakpoints"。即断点请求**根本没到 lldb**。
2. **preseed 注释**（F5）：唯一能下发断点的 attachCommands preseed 路径被注释掉。

这是"先保 attach 稳定"的刻意取舍（注释里写明 lldb-dap 22 在 attach 后发 `breakpoint set` /
post-attach `setBreakpoints` 会 `STATUS_STACK_BUFFER_OVERRUN` 崩）。

**接通断点的判定标准**（缺一不可）：
- DAP 侧：`setBreakpoints` 响应 `verified=true`（不是合成的 false）。
- lldb 侧：`breakpoint list` 中 `resolved > 0`。
- 仅 UI 出现断点标记 **不算**接通。

**接通顺序建议**：先把层 3/4 的 attach 做稳 → 再选断点机制（attachCommands 内
`?breakpoint set -f <file> -l <N>` preseed，bare lldb 先验 resolved）→ 很可能需先补层 5 的 `--slide`。

---

## 4. 排查 / 修复顺序（每步需 fresh protocol log）

1. **修层 3（确定性）**：spawn 命令去掉 `cd files && ./`，改 `files/lldb-server` 或绝对路径。
2. **攻层 4（设备 server）**：在 `a3ad86f3` 上逐个 server 二进制试 `gdbserver --attach`，
   选不崩的；记录 `TracerPid` 变化与 `Listening` 输出；崩溃后必 `killall lldb-server` 清理。
3. **attach 通到 `initialized` + `threads`** 后，再验层 5 ASLR base。
4. **接通断点**：preseed（attachCommands）→ bare lldb 验 `resolved` → 回 DAP 路径，
   同时评估解除 F4 合成短路是否会重现 lldb-dap 22 崩溃。
5. 全程 SELinux Enforcing、`stopOnEntry`、信号处置策略**不变**。

---

## 5. 不改运行时边界（本诊断阶段）

本报告为纯文档；未修改任何 `lua/ue/dap/*.lua`。后续修复另行最小改动，且：
- host adapter 维持 22.1.6+ forward-only；
- 不动 `stopOnEntry=true`；
- attachCommands/postRunCommands 不加 `process continue`；
- 不动 SIGSEGV/SIGBUS `--notify false --pass true --stop false`；
- 所有设备验证仅在 `a3ad86f3` 上进行。

---

## 6. 真机证据附录（a3ad86f3, 2026-06-02）

```
abi=arm64-v8a sdk=36 selinux=Enforcing
target pid 22232  State=S  TracerPid=0(idle)  Threads=17  VmRSS=213048kB  DEBUGGABLE=yes
run-as uid=u0_a429  context=u:r:runas_app  cwd(run-as)=/data/user/0/<android-package>

# 层3 bug:
run-as <pkg> sh -c 'cd files && ./lldb-server version'      -> ./lldb-server: inaccessible or not found
run-as <pkg> sh -c 'cd /data/.../files && pwd'              -> /            (cd 未生效)
run-as <pkg> sh -c 'files/lldb-server version'              -> lldb version 19.0.1   (OK)

# 层4 crash:
run-as <pkg> sh -c 'files/lldb-server gdbserver --attach 22232 *:N'   -> Segmentation fault (exit 139)
  （LLDB19 与 NDK27 LLDB18 均复现；崩溃残留 lldb-server，需 killall 清理，否则 TracerPid 卡非0）

# 层5 ASLR:
run-as <pkg> cat /proc/22232/maps | first libUE4.so r--p  -> base 0x6c9fe21000
host symbol so: .../Client_Symbols_v170300916/Client-arm64/libUE4.so (3192229608 B)
```
