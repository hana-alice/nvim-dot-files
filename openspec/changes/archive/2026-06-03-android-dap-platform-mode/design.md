## Context

用户要求把 **lldb-server platform 模式**作为 UE Android DAP 的正式 attach 路径
（对标 IDE：file transfer、qLaunchGDBServer 自动拉子 gdbserver、多进程、launch 等
gdbserver 模式没有的能力）。除 "host adapter 必须 LLDB 22.1.6+" 外，其余项目原则本任务
内可放宽，目标是真正跑通。

本设计基于一连串真机（授权测试设备 / Android 16 / arm64 / `<android-package>`）+
LLVM 22.1.6 源码（官方 tag `llvmorg-22.1.6`）
的实证。证据脚本在 `tools/dap_probe_android.py`、`tools/dap_platform_probe.py`。

### 已确证的事实

**E1 — gdbserver `--attach` 形态不可用（旧路死因）**
`lldb-server gdbserver --attach <pid> *:<port>`：ptrace 附上（`TracerPid` 非 0）但
**端口从不进入 LISTEN**（设备 `/proc/net/tcp` 0 条，轮询 40s 不绑定），host gdb 握手
零响应 / `Connection shut down ... initial handshake`。LLDB9 / LLDB18 / LLDB19 / LLDB21
server 全复现。→ 这是之前所有 "连不上" 的真因。

**E2 — 纯 listen / platform server 完全正常**
- `lldb-server gdbserver 127.0.0.1:<port>`（无 --attach）：立即 LISTEN，裸协议
  `QStartNoAckMode`→OK、`qSupported`→`PacketSize=20000;...`、`vAttach;<pidhex>`→`+`。
- `lldb-server platform --server --listen 127.0.0.1:<pport>`：LISTEN 正常，
  `qLaunchGDBServer:` 触发 `TCPSocket::Listen`，握手全通。
→ **device 端 platform 模式可行，没有任何缺陷。**

**E3 — host lldb-dap 是 nopython 构建**
`<lldb-install>/lib/site-packages/lldb` 不存在，`script ...` 命令静默无效。
任何依赖 host python 的方案排除。

**E4 — `platform connect <url>` 命令字符串在 22.1.6 被 getopt permute 吃掉 URL（host 卡点）**
经 lldb-dap `initCommands` 执行 `platform connect connect://localhost:<port>` 稳定报
`error: Invalid URL:`（URL 为空）。源码逐层定位：
- `CommandObjectPlatformConnect` 是 `CommandObjectParsed`，Execute 前先
  `ParseOptions` → `Options::Parse` → `OptionParser::Parse` →
  `getopt_long_only`（`lldb/source/Host/common/OptionParser.cpp:46`）。
- `OptionParser::Prepare` 把 `optind=0`（glibc 下触发 getopt 重新初始化 + GNU
  argument permutation）。platform 选项表有 `-p/-v/-b/-S`，short-options 以 `:` 开头但
  **无 `+` 前缀禁止 permute**。
- `Options::Parse` 末尾 `argv.erase(begin, begin+GetOptionIndex())` 用 permute 后的
  `optind` 切参数，把裸 URL `connect://...` 一并切掉 → `ReconstituteArgsAfterParsing`
  重建出空 → `ConnectRemote` 的 `GetArgumentAtIndex(0)` 为空 → `URI::Parse("")` 失败。
→ **这是 host 命令层 bug，与 device 无关。绕开它的办法是不走命令行字符串解析。**

**E5 — lldb-dap attach 有不经过 getopt 的结构化连接路径**
`lldb/tools/lldb-dap/Handler/AttachRequestHandler.cpp`：当 attach 配置含
`gdbRemotePort`（JSON key `gdb-remote-port`）时，lldb-dap 直接走 C++ SBAPI
`dap.target.ConnectRemote(listener, "connect://<host>:<port>", "gdb-remote", error)`，
**完全不经过命令解释器 / getopt**。这条路对 URL 不做 getopt permute。

### 推论

- platform 模式的全部缺陷只在 host 命令字符串 `platform connect` 这一处（E4）。
- 要走通 platform，需让 `platform connect` 经 **不走 getopt 的途径**执行：候选是
  (a) 让 lldb-dap 在 attach 时用 SBAPI 建立 platform 连接（类似 E5 的结构化路径），
  (b) `platform select remote-android` 无 URL 参数（不触发 getopt 取参问题），platform
  连接交给结构化键 / SBPlatformConnectOptions，
  (c) 若 host 22.1.6 确无结构化 platform 键，则需在 nvim 侧用 nvim-dap 的连接而非
  attachCommands 字符串来驱动 platform connect。

## Goals / Non-Goals

**Goals**
- attach 经 platform 模式到 `initialized` + `threads`，无 `Invalid URL`、无握手超时、
  无 `3221226505`。
- F9 file:line 断点真实 resolved（platform 模式 + ASLR rebase 后）。
- 连上无 `Source missing` 噪音。
- 仅在授权测试设备验证；host adapter 维持 22.1.6+。

**Non-Goals**
- 不回退到 gdbserver `--attach`（已证伪）。
- 不依赖 host python（nopython 构建）。
- 不改 device 系统 / UE 工程。

## Decisions

**D1 — device server 用 platform 模式启动**
`files/<server> platform --server --listen 127.0.0.1:<pport>` + `adb forward`。server
二进制选与 host 协议兼容的版本（候选 LLDB21 r29 / 实测中确定），写进
`default_lldb_server_paths()` 与 `docs/TOOLING.md`。

**D2 — platform connect 不走 getopt 命令字符串（核心）**
避免把 `platform connect connect://...` 作为命令字符串经 lldb-dap 命令解释器执行（E4）。
采用不触发 getopt permute 的途径，按 apply 阶段真机验证在以下方案中择优：
- 方案 A：lldb-dap attach 配置结构化键（若 22.1.6 暴露 platform 连接键）。
- 方案 B：`platform select remote-android`（无 URL，安全）+ 用 SBAPI / 结构化路径完成连接。
- 方案 C：在 nvim-dap 侧用 DAP `attach` 请求体直接驱动（非 attachCommands 字符串）。
每方案以 fresh protocol log 判定，确认 URL 不再被吞。

**D3 — attach + ASLR + 断点**
platform 连接建立后 `process attach --pid <pid>`（无 URL，不受 E4 影响）→
`target modules load --file libUE4.so --slide 0x<base>`（base 运行时从
`/proc/<pid>/maps` 读，hex 拼接禁 `string.format("%x")`）→ file:line 断点。断点是否仍需
address 形态由 platform 路径下的真机验证决定。

**D4 — clean env 协议**
每轮 probe 前：`am force-stop` + 重启 app 取新 pid；probe 用随机 host 端口给
lldb-dap、结束必 kill；动态取当前 device serial；收尾清 device lldb-server + forward。
（`tools/dap_platform_probe.py` 已实现随机端口 + 必清理。）

## Risks / Trade-offs

- [22.1.6 host 可能没有结构化 platform 连接键] → 退到 D2 方案 C（nvim-dap 驱动）或
  向上游确认；最坏情况记录为 "platform 模式需 host 端补丁"，但 device 已证可行。
- [platform 路径下 source-file 断点可能仍崩 3221226505] → 复用 address 断点结论
  （image lookup --line → breakpoint set --address）。
- [server 版本与 host 22 的 platform 协议不完全兼容] → 真机逐版本验证握手层。
- [仅单机] → 明确 a3ad86f3。

## Migration Plan

1. apply 阶段先用 `tools/dap_platform_probe.py` 在 a3ad86f3 验证 D2 三方案，定连接途径。
2. 改 `lua/ue/dap/android.lua`：server 启动改 platform；attach 改不走 getopt 的连接途径
   + `process attach` + ASLR。
3. 改 `lua/ue/dap.lua`：会话识别 / 入口不 jump / 断点响应按 platform 路径。
4. 改 `lua/utils/platform/windows.lua`：server 版本/优先级。
5. 文档：`docs/TOOLING.md`、`docs/CONSTRAINTS.md`、`docs/plans/`。
6. 真机 `<space>da` 端到端：initialized/threads/断点 resolved/命中正确行/无 Source missing。
7. 回滚：`git checkout` 相关 lua + docs。

## Open Questions

- 22.1.6 host lldb-dap 是否暴露结构化 platform 连接键（D2-A）？需读 attach JSON schema
  解析层（`lldb/tools/lldb-dap` 的 args 解析）确认。
- 兼容 host 22 platform 协议的 device server 最低 LLDB 版本？真机逐版本定。
- platform 路径下断点：source-file vs address，由真机定。
