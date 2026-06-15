## Context

当前 Android DAP 代码已经切回 K30 路线：device 端启动 `lldb-server platform --server
--listen`，host 端用 `platform connect connect://[<serial>]:<port>` 后 `process attach
--pid`。这解决的是 attach 传输路线，不等于解决 F9 断点命中。

F9 仍断不住需要重新分层看：

```text
编辑器断点状态
    │
    ▼
attachCommands / DAP setBreakpoints 是否真的发到 LLDB
    │
    ▼
LLDB breakpoint list 是否 resolved>0
    │
    ▼
运行时 PC 是否走到该 address 且触发 stopped event
    │
    ▼
nvim 是否跳到正确本地源码行
```

任一层断开，UI 显示 `verified=true` 都是误导。现有代码中还存在历史取舍：Android
`setBreakpoints` 曾因 lldb-dap 22 崩溃风险被合成短路；preseed 断点只对 attach 前已存在的
断点有效；attach 后新增/删除 F9 没有等价的安全命令路径。之前的修复没有把这些路径逐层闭环。

### 当前代码行为快照

apply 前必须以这些代码事实为起点，不能只按旧文档或记忆实现：

- F9 用户入口是 `lua/config/keymaps.lua` → `:UEDAPToggleBreakpoint` →
  `lua/ue/dap.lua` `D.dap_toggle_breakpoint()` → `lua/ue/dap/_persist_bp.lua`
  `toggle()` → `dap.toggle_breakpoint()`，持久化由 `_persist_bp` 负责。
- 持久化恢复路径 `_persist_bp.restore_for_buf()` 在会话存在时会调用
  `dap.session():set_breakpoints(...)`，因此 attach 后恢复/新增断点会触发 DAP
  `setBreakpoints` 流。
- `lua/ue/dap.lua` 目前有一套 `ue_android_preseed_breakpoints()`，通过
  `dap.listeners.on_session["ue_android_preseed_breakpoints"]` 修改 `session.config.attachCommands`。
- `lua/ue/dap/android.lua` 也有一套 `preseed_breakpoints_into_attach_commands(cfg)`，在
  `_finalize_session()` 调用 `C.run()` 之前修改同一个 attach config。
- 两套 preseed 的插入点不同：`dap.lua` 只找 `process handle SIGPIPE` 后插入；
  `android.lua` 会继续扫描 `target modules load`，确保断点在 ASLR rebase 后插入。
  这意味着当前设计有重复职责，且一条路径可能把断点放到不理想的位置。
- `lua/ue/dap.lua` 里存在 `ue_android_synthetic_breakpoint_response()`，当前搜索只看到定义，
  没有看到调用点；它可能是死代码，也可能是旧设计残留，apply 前必须确认并清理。
- `after.setBreakpoints["ue_android_bp_local_response"]` 当前会无条件调度 detach + reattach，
  把“会话中 F9”转化为“重新 attach 后 preseed”。这不是理想的即时断点模型，最多是受限环境下的
  显式策略，不能伪装成真正动态下发。

## Goals / Non-Goals

**Goals:**

- apply 前建立完整 F9 设计图：用户入口、持久化、断点收集、attach config 构建、
  DAP `setBreakpoints`、LLDB 命令、stop event、source navigation 都要有代码依据。
- 给 F9 定义端到端成功标准：DAP `verified=true`、LLDB `breakpoint list resolved>0`、
  真机触发 `stopped(reason=breakpoint)`、源码行正确。
- 保留当前 K30 serial-form platform attach 路线，不回到已证伪的 `gdbserver --attach`。
- 明确 attach 前断点与 attach 后断点的不同处理策略，避免只修一种时机。
- 用真机 fresh protocol log / LLDB console log 证明每一层，不再凭 UI 标记判断。
- 在 lldb-dap 22.1.6 可能崩溃的路径上采用“先 probe、再放开”的策略。
- 消除重复职责和 workaround-shaped 代码：断点植入只有一个 owner，反馈只反映真实状态。

**Non-Goals:**

- 不引入新依赖，不更换 DAP 客户端框架。
- 不修改 UE 工程、设备系统或目标包。
- 不把 `verified=true` 作为无条件 UI 安慰值。
- 不把 platform attach 重新改成 `gdb-remote-port` / `gdbserver --attach`。

## Decisions

**D1 — 先做断点证据链，不先改 UI**

修复顺序必须先证明 LLDB 层已经有 resolved breakpoint，再让 DAP/UI 报成功。具体证据：

- attach 前记录 nvim 断点表，包含本地绝对路径、basename、line、是否来自持久化恢复。
- attachCommands 或后续命令日志中必须出现对应 `breakpoint set` / address breakpoint 命令。
- attach 完成、`configurationDone` 前后都采集 `breakpoint list`。
- 真机触发后必须看到 `stopped` event，且 top frame / selected frame 可映射到本地源码。

替代方案：直接把合成响应固定为 `verified=true`。拒绝原因：这正是当前容易误判的来源，不能证明断点命中。

**D1b — 代码事实优先于方案假设**

任何实现想法必须先回答三个问题：

1. 当前代码哪条路径会执行它？
2. 当前代码实际会产生什么 DAP / LLDB 行为？
3. 这个行为如何用日志或测试证明？

如果无法回答，不能实现；如果答案暴露设计更差，先更新 design/tasks，再改代码。apply 阶段不得把
“先绕过去看看”当成方案，除非该路径被明确标记为诊断 probe 且不会进入运行时主路。

**D1c — 单一 owner：断点植入归 `ue.dap.android`**

Android attach config 的断点植入应只有一个 owner：`lua/ue/dap/android.lua`。理由：

- attachCommands 的正确插入位置依赖 Android attach 顺序、signal disposition、ASLR rebase；
  这些上下文都在 android 模块里。
- `lua/ue/dap.lua` 是 host-side DAP glue，适合做 source path rewrite、event 监听、UI 状态与
  session 行为协调，不应重复修改 Android attachCommands。
- 当前双 preseed 结构可能重复植入同一断点，且 `dap.lua` 路径可能插在 ASLR rebase 前。

因此 apply 时要删除或停用 `dap.lua` 的 Android preseed listener，把断点收集/命令生成/插入顺序
集中到 `android.lua`，并用 test hook 验证生成的 attachCommands。

**D2 — attach 前断点走 preseed，attach 后断点走受控 command path**

attach 前已有断点必须在 attach 阶段植入，避免 lldb-dap 22 的 post-attach source breakpoint
崩溃路径。插入顺序应是：

```text
target create <symbol-rich libUE4.so>
platform select remote-android
platform connect connect://[serial]:port
process attach --pid <pid>
process handle SIG*
target modules load --file libUE4.so --slide 0x<base>   (若启用)
breakpoint set ...
breakpoint list
```

attach 后新增/删除 F9 不应继续假装已生效。先实现为安全、明确的行为：若不能即时安全下发，
提示需要 reattach；若 probe 证明 command path 稳定，再通过 LLDB 命令下发并重新采集
`breakpoint list`。

替代方案：恢复原生 DAP `setBreakpoints` 请求。拒绝原因：历史上该路径可能触发
`3221226505`，必须先用受控 probe 证明不崩。

**D2b — attach 后 F9 不用“静默自动 reattach”伪装即时断点**

当前 `after.setBreakpoints` 会调度 detach + reattach。这可以作为用户明确接受的“重新植入”
动作，但它不是即时断点下发。设计上应改成：

- 若会话中 F9 能通过受控 LLDB command path 安全下发，就即时下发并用 `breakpoint list` 验证。
- 若不能安全下发，就明确提示“该断点将在 reattach 后生效 / 执行 :UEDAPReattach”，不要静默断开用户会话。
- 不允许在未 resolved 时返回或展示成功语义。

**D3 — source-file 断点优先，address 断点作为语义等价正解**

优先使用 source-file `breakpoint set -f <file> -l <line>`，因为它最接近用户 F9 语义。
如果 source-file 路径在 lldb-dap 22.1.6 下仍崩或 pending，则使用：

```text
image lookup --file <file> --line <line>
breakpoint set --address <resolved-pc>
```

address 断点只有在满足以下条件时才可作为正解：对应同一源行、同一 module UUID/slide、同一
PC 范围，且 `breakpoint list` resolved>0，命中后 frame 能映射回原源码行。否则只能标记为
workaround，不作为完成。

**D4 — 路径匹配不能只靠 basename**

UE 大工程里 basename 可能重复。preseed 命令可以保留 basename 作为兼容路径，但验证必须记录
LLDB 解析出的 compile-unit 路径，并和本地 sourceMap / path resolver 对齐。若出现重复或
pending，应升级为更精确的路径策略或 address 断点，而不是继续只用 basename。

**D5 — 同步修正过时 attach spec**

现有 `android-dap-attach` spec 仍写着 MUST NOT 使用 `platform connect connect://...`
命令字符串，但 `docs/CONSTRAINTS.md` K30 与当前代码已经确认 serial-form
`connect://[serial]:port` 是工作路线。这个 change 应同步修正 spec，避免后续实现被旧契约拉回
错误方向。

**D6 — 删除死代码和历史注释债**

如果 `ue_android_synthetic_breakpoint_response()` 没有调用点，应删除；如果有隐藏调用点，应改为
真实状态响应。`android.lua` 中仍写着旧 gdb-remote 形态的注释必须同步修正。保留历史失败路径只应在
`docs/CONSTRAINTS.md` / change design 中作为证据，不应混在运行时主路注释里制造误导。

## Risks / Trade-offs

- [source-file breakpoint 仍触发 lldb-dap 崩溃] → 先用 probe 分离 `image lookup`、
  `breakpoint set -f/-l`、`breakpoint set --address`，只放开稳定路径。
- [basename 匹配到错误 translation unit] → 在日志中记录 resolved compile-unit 路径和 address；
  必要时改用 address breakpoint。
- [attach 后动态 F9 无法安全即时生效] → 明确提示需要 reattach，不再显示假成功。
- [address breakpoint 与源码行有多地址/内联函数差异] → `breakpoint list` 和 stop frame 必须记录
  所有 location；命中判据允许同一源码行的多个 resolved locations。
- [真机环境残留影响判断] → 每轮验证前清理 lldb-server、forward、TracerPid，重启目标取 fresh pid。

## Migration Plan

1. 增加/扩展只读 probe：输出 nvim 断点表、最终 attachCommands、LLDB `breakpoint list`、
   DAP `setBreakpoints` 响应、stop event、adapter exit code。
2. 画出并确认当前 F9 代码路径图：F9 keymap、`_persist_bp`、DAP listener、android config builder、
   attachCommands、`setBreakpoints`、source navigation。
3. 用 probe 复现当前 F9 断不住，定位断在哪一层：未发命令、pending、resolved 但不命中、
   命中但 UI 不跳转。
4. 先修设计债：移除重复 preseed owner、死代码、误导性注释和静默 auto-reattach 假即时语义。
5. 修 preseed 路径：确保 attach 前断点在 ASLR / target create 之后植入，并记录 resolved 结果。
6. 处理 attach 后 F9：先给出诚实提示或实现经 probe 证明稳定的 command path。
7. 若 source-file 断点不稳定，按 D3 切 address 断点并保留语义等价证据。
8. 更新 `android-dap-attach` spec、工具文档、changelog。
9. 验证：headless smoke + 真机 `<space>da` + F9 命中 + 无 `Source missing` + adapter 存活。

## Open Questions

- 当前用户场景里的 F9 是 attach 前已存在断点，还是 attach 后才新增？两者都要支持，但首个
  真机复现需要记录具体时机。
- source-file `breakpoint set` 在当前 K30 platform route 上是否仍会触发 `3221226505`？
- 如果同一 basename 多处存在，LLDB 当前会解析到哪一个 compile unit？
