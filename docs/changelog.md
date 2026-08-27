# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)

## Unreleased

### 2026-08-27 — Keep clangd discovery retries callable after history reconciliation

**Task**

消除合入重写后的 origin 时由全量回归暴露的 `vim.defer_fn` 异步回调错误。

**Implemented**

- `clangd_resource_controller.discover_with_retry` 按 Neovim API 的 `(fn, timeout)` 顺序安排有界重试。
- 回归注入使用同一真实签名，避免测试 mock 反向固化实现错误。
- 既有 host-resource-discipline 可观察契约不变；这是实现对现有 spec 的一致性修复，无 delta spec。

**Pitfalls / Gotchas**

- 原全量统计仍显示全绿，但 `vim.wait` 期间的 scheduled callback 已打印 `fn: expected callable, got number`；
  只看最终 pass 计数会漏掉异步错误。

**Validation**

- 定向 `nvim --headless -l tests/run.lua clangd_resource`：10/10；全量回归：1324/1324，且不再出现
  scheduled callback 异常。
- 现有 host resource OpenSpec 契约未变化；本次只修正实现与测试替身的 Neovim API 调用顺序。

**Follow-ups**

- 无。

### 2026-08-26 — Add the iOS CoreDevice production DAP route

**Task**

让 macOS 上的 Neovim headless/production iOS DAP 支持已选 `coredevice` 真机，同时保留 pre-iOS17
`legacy-mobiledevice` 行为，并用真机 source breakpoint/cleanup gate 决定是否可报告成功。

**Implemented**

- iOS DAP 在 session 开始时冻结 backend、selected Xcode adapter、project/source roots、device、bundle、
  local Mach-O/dSYM 与 PID；CoreDevice 和 legacy 走独立 strategy，失败不互相 fallback，也不借用 Mac handler。
- iOS DAP 的产物布局与 backend 工具集合由 `ue.targets.ios` owner 规划，runtime 只冻结解析结果，保持
  host/target 架构边界与 capability matrix 一致。
- CoreDevice 只消费 `devicectl --json-output`：精确解析 installed app/canonical device、start-stopped launch、
  running process 与 PID reuse；Apple LLDB config 固定为 `target create` → `device select` →
  `device process attach -p` → `target symbols add`，再通过 `postRunCommands` 输出唯一 loaded-image UUID marker；
  Neovim listener 只有收到成功 marker 才允许 source breakpoint proof 继续，并以有界 grace 兼容 marker/
  `initialized` 事件顺序差异；adapter 不回 disconnect 事件时也有 owner cleanup timeout fallback。
- adapter 前置门禁异步比较 Mach-O/dSYM UUID，并要求 dSYM 通过 `dwarfdump --verify --quiet`；owner cleanup
  先 non-terminating disconnect：普通 attach 复验冻结 app/PID 仍存在，只有 debug-launch owner 才终止该 PID 并
  复验 absence；重复触发复用同一 cleanup 结果。
- headless smoke 改为显式 project/device/backend/bundle/binary/dSYM/source/line 输入，要求 verified breakpoint、
  breakpoint stop、精确 source:line、expression 与 cleanup 全部成立才写 `passed`；raw/production evidence
  只持久化 basename/digest/boolean，不落真实 device、bundle、PID 或个人路径。
- 将 DAP event proof 从已超过仓库行数门禁的 iOS transport 文件拆到单一 session listener owner；没有改变
  CoreDevice/legacy transport 行为，也没有引入依赖。
- 将 CoreDevice route、debug-launch identity、UUID/source gate 与 production headless contract 同步到 canonical
  OpenSpec、architecture、tooling、constraints（K55）与 lessons。

**Pitfalls / Gotchas**

- 原 monolithic dSYM 虽与 Mach-O UUID 相等，但 DWARF verification 报 invalid abbreviation offset；UUID 相等
  不能代替内容校验。最终使用与设备安装的 branch_3.6 Development executable 精确匹配、且 verification
  通过的窄 dSYM 完成 source breakpoint 证明；该 dSYM 只覆盖本次所需编译单元，不冒充项目完整符号包。
- attach command 中的同步 LLDB `assert` 会早于异步 CoreDevice process load 执行，而且 lldb-dap 会继续初始化；
  因此真实 fail gate 必须是 `process status` 后的 marker，并由 DAP listener 在首次 continue 前消费。
- QA 包体属于 branch_3.6；把 branch_3.7 本地 executable 与它的 cooked shader 混用会连续触发 missing global
  shader。安装必须使用包体 `prepared-signing/current.json` 指向的匹配 App，或使用同一 branch_3.6 checkout
  编译的本地 executable；不得复用已被其他构建覆盖的通用 `signed-app` 路径。
- Personal Team profile 不提供 V8 所需的 Apple 私有内存 entitlement，原 QA executable 会因 pointer-compression
  cage 预留失败退出。匹配 branch_3.6 的本地 Development executable 必须以
  `-disablev8pointercompression` 构建；本次真机日志确认 `V8 PointerCompressionIsEnabled: 0`。

**Validation**

- 定向：`dap` 94/94、`platform` 39/39、`ue_platform_boundary` 9/9、`ios_dap_probe` 6/6、
  `ue_target_drivers` 47/47、`ue_target_tasks` 9/9、`ue_workflows` 26/26；5 个 iOS production Lua、
  新增 CoreDevice spec 与 production smoke 的 `stylua --check` 通过，production Lua bare-global AST lint 通过。
- `python3 tools/ios_dap_protocol_probe.py self-test`：passed；production headless attach/launch 与 strict raw-DAP
  均生成脱敏 `status=passed` evidence，并同时证明 loaded-image UUID、verified breakpoint、breakpoint stop、
  精确 source frame、expression 与 disconnect acknowledgement。
- 真机 cleanup：production attach 在 detach 后复验原 app/PID 仍存在；production launch 只终止本次 owner PID
  并复验 absence；最终设备无残留测试进程。
- 匹配 branch_3.6 的 Personal Team App 完成 container-preserving 安装，既有外置资源未重传；普通启动进入
  `FEngineLoop::Init`、LaunchScene 并持续运行。raw DAP 以及 production nvim attach/launch 均使用同一
  local Mach-O/dSYM/source identity，未混用 branch_3.7 artifact。
- 全量 `nvim --headless -l tests/run.lua`：1324/1324；
  `openspec validate add-ios-coredevice-headless-dap --strict` 与 `git diff --check` 通过。
- `python3 tools/ios_dap_protocol_probe.py self-test`、`git diff --check`、通用 secrets 扫描，以及旧历史到脱敏
  snapshot 的删除内容回归扫描均通过；未重新引入被清理的 identity、设备标识或个人路径。

**Follow-ups**

- 当前窄 dSYM 已完成 Launch 编译单元的真机证明；调试其他编译单元前仍需为同一 executable 生成对应的
  verified dSYM。Personal Team profile 到期时只刷新签名缓存，不得改变 binary/dSYM UUID 配对。
