## Context

见 `proposal.md`。当前 `lua/ue/dap/ios.lua` 已有完整 legacy MobileDevice pipeline：从持久化
runtime 冻结 USB device/bundle，解析 installed app 与 DeviceSupport，启动 `ios-deploy --nolldb`
bridge，再由 Apple `lldb-dap` 走 `remote-ios`。它在 `resolve_runtime()` 中明确拒绝
`coredevice`，因此 iOS 17+ 设备虽可用于 install/ordinary launch，却不能进入 DAP。

现有 `tools/ios_dap_protocol_probe.py` 已把 CoreDevice raw-DAP 正确顺序固定为
`target create` → `device select` → `device process attach -p`，并已有
`tools/nvim_ios_dap_smoketest.lua` 驱动 production handler。当前真机只读证据确认 selected Xcode
提供 `devicectl`、`lldb-dap` 与 LLDB CoreDevice commands，设备处于 paired、Developer Mode enabled、
tunnel connected 状态；独立会话还证明 start-stopped launch 与 CLI attach 可执行。严格 source
breakpoint/dSYM/cleanup gate 仍须由本 change 在 production handler 上完成。

## Goals / Non-Goals

**Goals:**

- 在不改变 legacy backend 的前提下，为 `coredevice` 增加生产级 attach 与 debug-launch。
- 让交互命令与 headless smoke 共用同一 production pipeline 和不可变 session snapshot。
- 在首次 continue 前完成结构化 process identity 与 UUID gate；成功后沿用现有 breakpoint/frame proof。
- 所有外部进程保持 async，所有失败与 cleanup 都只操作冻结 device/PID。

**Non-Goals:**

- 不改变普通 `:UELaunch`、install、signing 或 package 语义。
- 不给 pre-iOS17 legacy backend 改协议，不在两个 backend 之间 fallback。
- 不实现 Windows/SSH remote Mac、Simulator、custom DAP bridge 或自动选择“第一台”设备。
- 不扫描或修改 active project、显式设备与本仓之外的其他用户工作区；尤其不访问 `<OTHER_USER_HOME>`。
- 不以 symbol-name breakpoint、adapter initialized 或 UI 状态替代 source breakpoint 真机验收。

## Decisions

### 1. 在 iOS DAP owner 内按冻结 backend 分成两条 pipeline

共享入口只负责解析 active context、冻结 project tuple/device/bundle/debug artifact、选择 selected Xcode
adapter 与安装 listeners；随后按 `runtime.backend` 精确调用 `legacy-mobiledevice` 或 `coredevice`
strategy。每条 strategy 自己声明所需工具、bootstrap 与 cleanup；session metadata 同时记录
`owner=ios`、operation、backend、device 与 PID。

这样保留现有 lifecycle dispatch 的单一 owner，同时避免在 legacy 代码中散布 CoreDevice 条件分支。
Rejected：把 CoreDevice 伪装成 legacy bridge，会错误要求 `ios-deploy`/DeviceSupport 并破坏 backend
failure 的可诊断性。Rejected：新建第二个 DAP platform owner，会让同一 IOS target 的 command/matrix
与 lifecycle 状态分裂。

### 2. CoreDevice 所有 identity 都来自显式 context 与结构化 JSON

debug-launch 使用 selected Xcode 的 `devicectl device process launch --device <id>
--terminate-existing --start-stopped --json-output <temp> <bundle>`。ordinary attach 使用
`devicectl device info processes --device <id> --json-output <temp>`，只接受唯一匹配 bundle 的正
PID。installed app、launch、process 与 terminate 结果都通过纯 parser 返回结构化值；runtime 仅负责
`vim.system` async 执行、临时文件生命周期与 callback 编排。

JSON 文件使用每次调用独立的临时路径，callback 读取后无条件删除；任何 schema 缺失或 mismatch 都
fail closed。Rejected：解析 `devicectl` table/stdout，官方帮助已明确只有 `--json-output` 是脚本接口。
Rejected：按 executable name 或最近 PID 查询，会把进程重用与同名 app 当成正确 identity。

### 3. CoreDevice lldb-dap 配置复用 raw-DAP 已证实顺序

CoreDevice config 继续使用独立 adapter id 与 `request="attach"`，但不包含 `platform select remote-ios`、
loopback port 或 `SetPlatformFileSpec`。`attachCommands` 固定为：

1. `target create <local Mach-O>`；
2. `device select <captured device>`；
3. `device process attach -p <captured PID>`；
4. `target symbols add <matching dSYM>`。

CoreDevice attach 本身异步完成，因此 loaded-image gate 放在 `postRunCommands`：先用 `process status`
确认 stopped process，再输出唯一的 UUID OK/MISMATCH marker。production listener 与 raw probe 都必须消费
该 marker，未得到 OK 时不得进入首次 continue。

`stopOnEntry=true` 保持 attach 完成后的初始 stop；nvim-dap 在 `initialized` 后发送当前 source
breakpoints，再发送 `configurationDone`，因此 debug-launch 的 suspended process 不会在断点下发前运行。
Rejected：启动交互式 `xcrun lldb` 并桥接终端，它绕过 nvim-dap request/lifecycle，无法承载 F9、
stack/evaluate 与 owner cleanup。Rejected：新写 DAP byte-stream bridge，现有 Apple `lldb-dap` 已证明可用。

### 4. UUID gate 分为 host preflight 与 attach-time loaded-image assertion

adapter 启动前异步执行 selected Xcode 的 `dwarfdump --uuid`，要求 local Mach-O 与 `.dSYM` UUID
集合非空且完全一致。device attach 后在 post-run LLDB command 中读取主 executable module UUID，并与
冻结集合比较；listener 消费 OK/MISMATCH marker，缺失或不匹配即 non-terminating disconnect，早于首次
continue。source roots 与 checkout 也写入 snapshot，后续 breakpoint listener 只有在 verified breakpoint
对应 source 的真实 stop frame 中才报告 ready。

Rejected：仅比较文件名/路径，设备安装路径每次变化且无法证明构建 identity。Rejected：允许没有
dSYM 的 symbol-only session，违反 canonical spec 的 source-frame gate。

### 5. headless smoke 只参数化 production handler，不复制协议

扩展 `tools/nvim_ios_dap_smoketest.lua` 读取显式 mode、project/device/backend/bundle/binary/dSYM/source/
line 与可选 expression，构造 handler opts 后调用 `require("ue.dap.ios")[mode]`。smoke 继续监听真实
nvim-dap events，只有 verified breakpoint、breakpoint stop、精确 source path/line、evaluate 与 cleanup
全部成功才写 passed。

结果 JSON 只保留 basename、行号、boolean、错误 code 与敏感值 digest；真实 device、bundle、PID 和个人
绝对路径不落盘。unit test 只验证 parser、argv、redaction 与 lifecycle；真机结果单独标记 passed 或
blocked/not-run。Rejected：直接调用 `tools/ios_dap_protocol_probe.py` 代替 Nvim smoke；raw probe 是协议
诊断，不证明 production handler、registry、listeners 与 cleanup 已接通。

### 6. cleanup 先 detach，再按冻结 PID 终止和复验

用户 stop、bootstrap failure、adapter exit 与 Vim 退出统一进入 iOS owner 的幂等 cleanup。若有 DAP
session，先发送 `disconnect{terminateDebuggee=false}`。debug-launch 拥有由本次命令创建的 frozen PID，
因此再用 `devicectl device process terminate` 并复验 absence；ordinary attach 不拥有既有应用进程，
只按冻结 device/app/PID 复验 detach 后仍存活，绝不发送 terminate。无法证明 PID 归属时不猜测、不终止。

## Risks / Trade-offs

- [Risk] `devicectl` JSON schema 随 Xcode 版本变化。→ parser 接纳少量已观察字段别名，但 device/bundle/PID
  三项缺一即失败；fixtures 锁住 Xcode 当前形状，真实失败保留脱敏诊断。
- [Risk] start-stopped process 在 adapter/bootstrap 失败时长期冻结。→ PID 一产生就写入 runtime snapshot，
  每条失败边都进入幂等 terminate + absence probe。
- [Risk] DAP disconnect 或 CoreDevice terminate 超时。→ 复用 adapter disconnect timeout，外部命令各自有界；
  超时报告 cleanup_error，不把未验证清理写成成功。
- [Risk] 大型 UE dSYM/模块加载增加首次 attach 延迟。→ host UUID preflight 异步执行，LLDB 只校验主 module，
  不下载全部 remote images；进度 UI 分阶段显示。
- [Risk] 当前已安装 app 可附加但本地 dSYM 不属于同一构建。→ UUID gate 会明确阻塞，要求运行
  `:UEIOSSymbols`/重装匹配 artifact，而不是降级。

## Migration Plan

1. 先增加纯 config/parser 与 headless regression，锁住 legacy config 不变及 CoreDevice 命令/identity/cleanup。
2. 接入 CoreDevice async bootstrap 与 owner lifecycle；保留 legacy strategy 作为行为基线。
3. 在显式真机参数下先跑 CLI/raw-DAP gate，再跑 `nvim --headless` production smoke；失败时只保留
   blocked/failed 脱敏证据。
4. 真机 source breakpoint、frame、expression、cleanup 全部通过后更新 canonical docs/changelog，并跑范围
   回归与全量回归。
5. 回滚时删除 CoreDevice strategy/registration 分支即可；legacy handler、普通 launch 与持久状态 schema
   不需要迁移。
