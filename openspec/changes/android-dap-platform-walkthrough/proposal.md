## Why

本次会话围绕 UE Android DAP（`<space>da` 连不上 + F9 断不上）做了大量真机 + LLVM
22.1.6 源码诊断，确认了**正确路线是 lldb-server platform 模式 / 结构化连接键**，并把
所有失败路径证伪。但 attach 尚未在真机端到端跑通——还卡在一个已精确定位、但未最终
打通的连接组合上。本 change 把会话剩余的所有未决问题收拢成一份可执行清单，作为继续
攻坚的起点，避免下次重新发现已知结论。

完整证据链已固化在归档的四个 change（`docs/plans/` + 各 spec delta）：
- `archive/2026-06-03-android-dap-attach-bp-diagnosis`
- `archive/2026-06-03-android-dap-attach-bp-fix`
- `archive/2026-06-03-android-dap-attach-handshake-rootcause`
- `archive/2026-06-03-android-dap-platform-mode`

## 已确证结论（不要重新发现）

- **E1** `lldb-server gdbserver --attach <pid>` 在 a3ad86f3 从不绑定监听端口（ptrace
  附上但永不 listen/serve），host gdb 握手零响应。LLDB9/18/19/21 全复现。→ 此形态作废。
- **E2** 纯 `lldb-server gdbserver 127.0.0.1:<port>`（无 --attach）正常 listen，裸协议
  `QStartNoAckMode→OK`、`qSupported→PacketSize=20000;...`、`vAttach;<pidhex>→+`。
- **E2b** `lldb-server platform --server --listen` 正常 listen + `qLaunchGDBServer` 握手通。
- **E3** host `C:/tools/lldb-22/install/bin/lldb-dap.exe` 是 nopython 构建（`script` 无效）。
- **E4** `platform connect connect://...` 作为命令字符串经 lldb-dap 执行，被
  `getopt_long_only`（`OptionParser.cpp:46` + `optind=0` permute）吞掉 URL → `Invalid URL`。
- **E5** lldb-dap attach 有结构化键 `gdb-remote-port`/`gdb-remote-hostname`/`platformName`
  （`AttachRequestHandler.cpp` + `ProtocolRequests.cpp`），走 SBAPI `ConnectRemote`，
  **绕开 E4 的 getopt**。实测 `platformName=remote-android`+`gdb-remote-port` 能到
  `initialized`（之前命令字符串连这都到不了）。
- **E6** 但 `platformName` 源码确认**只 `CreateTarget(platform_name)`、不 connect platform**；
  `gdb-remote-port` 直连一个 listening gdb stub，**连不了 platform server**（platform 要
  qLaunchGDBServer 拉子进程）。且 `pid` 与 `gdb-remote-port` **互斥**（ProtocolRequests.cpp）。

## 收窄到的最可能正解（待真机确认）

**纯 listen gdbserver + 结构化 gdb-remote-port + process attach pid**（同时绕开 E1 和 E4）：
```
device: lldb-server gdbserver 127.0.0.1:<port>        # 纯 listen，无 --attach（绕 E1）
host:   attach 配置 gdb-remote-port=<port>            # 结构化键 SBAPI 连接（绕 E4）
        attachCommands=["process attach --pid <pid>"] # 无 URL，不中 E4；connect 后 vAttach
```
注意 `gdb-remote-port` 与 `pid` 互斥，所以 pid attach 须经 attachCommands 的
`process attach --pid`（命令无 URL，安全）。这是本 change 第一步要验证的精确组合。

## What Changes

- **新增 capability `android-dap-platform-walkthrough`**：把剩余未决问题（连接组合验证、
  断点机制、入口噪音、文档化）拆成可验证项，并定义"端到端跑通"的成功判据。
- 真机验证收窄的连接组合（纯 listen + gdb-remote-port + process attach），定出最终方案。
- 方案定型后再改 `lua/ue/dap/*.lua` / `lua/utils/platform/windows.lua` 接通 attach + 断点。
- 固化 `docs/plans/2026-06-03-android-dap-platform-mode.md`（E1–E6 + 最终方案）与
  `docs/TOOLING.md` / `docs/CONSTRAINTS.md` 更新。

## Capabilities

### New Capabilities
- `android-dap-platform-walkthrough`: 把 platform/结构化连接路线从"已定位"推进到"真机
  端到端跑通"的契约——连接组合验证、断点接通、入口噪音消除、环境与文档。

### Modified Capabilities
- `android-dap-attach`: 现有主 spec 以 platform-mode delta 为准但未真机验证；本 change
  跑通后将以真机结论 MODIFY 该 capability 的连接方式（纯 listen vs platform server）。

## Impact

- **待改 nvim 配置（方案定型后）**：`lua/ue/dap/android.lua`、`lua/ue/dap.lua`、
  `lua/utils/platform/windows.lua`。
- **诊断脚本（已在仓）**：`tools/dap_probe_android.py`、`tools/dap_platform_probe.py`、
  `tools/dap_platform_structured.py`。
- **文档**：`docs/plans/`、`docs/TOOLING.md`、`docs/CONSTRAINTS.md`。
- **设备**：仅 a3ad86f3；host adapter 维持 LLDB 22.1.6+；每轮 probe 前 `am force-stop`
  + 重启 app 取新 pid，probe 用随机 host 端口且必清理，收尾清 device lldb-server + forward。

## 剩余未决问题清单（本 change 要解决）

1. **连接组合**：纯 listen gdbserver + `gdb-remote-port` 结构化键 + `process attach --pid`
   能否端到端到 `threads`？（最可能正解，待真机）
2. **platform server vs 纯 gdbserver**：若用户坚持 platform server（为 file transfer 等
   IDE 能力），需确认 lldb-dap 22.1.6 是否有连 platform server 的结构化途径，或需 nvim-dap
   层绕 E4。当前结构化键只支持纯 gdb stub。
3. **device server 版本**：与 host 22 兼容的最低 LLDB 版本（LLDB21 r29 已暂存验证中）。
4. **断点机制**：连接通后 source-file `breakpoint set` 是否仍崩 `3221226505`；崩则用
   address 断点（`image lookup --line`→`breakpoint set --address`）；判据见
   `android-dap-handshake-diagnostics`（正解 vs workaround）。
5. **入口噪音**：消除 `Source missing, cannot jump to ...`（入口 PC-only 合成帧不 jump）。
6. **设备 serial 漂移**：测试机重连后 serial 变（a3ad86f3 ↔ 其它），代码/probe 不应写死。
