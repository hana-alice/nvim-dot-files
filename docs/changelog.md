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

### 2026-08-31 — Sync and archive all active OpenSpec changes

**Task**

将四个活动 OpenSpec change 的 delta 同步到主规格并归档，同时在公开分支提交前检查商业敏感词。

**Implemented**

- 将后台索引 CPU 准入、磁盘工件自证 readiness、跨 checkout 候选标记、header TU 自动收敛四组契约
  同步到 `cpp-semantic-index-coverage`、`ue-code-search` 与
  `cpp-contextual-definition-navigation` 主规格；同时消除旧的“多个 TU 即提示选择”条款冲突。
- 将四个 change 移入 `openspec/changes/archive/2026-08-31-*`，保留原始 task 勾选状态，不把未完成项
  改写为已完成。
- 收窄 iOS DAP smoke 脱敏回归中的短 PID 断言：直接检查结构化 `pid` 字段与错误消息，避免随机路径
  摘要恰好含同一四位数字时误报；设备、bundle 与本地路径的完整序列化结果检查保持不变。

**Pitfalls / Gotchas**

- 四个归档 change 分别仍有 1、4、12、4 个未勾选任务；归档是用户明确要求的管理动作，不构成这些
  实现/验收项已完成的证据，尤其 foreign checkout picker change 仍为 0/12。
- 12 位十六进制摘要可能偶然包含任意四位数字；独立 SHA-256 实验在第 5019 个输入复现了 `4242`
  出现在已脱敏摘要中的情况，因此不能把整段 JSON 的短数字子串搜索当作泄漏证明。

**Validation**

- `openspec validate --all`（归档后）：39/39；`nvim --headless -l tests/run.lua structure`：71/71；
  `nvim --headless -l tests/run.lua ios_dap_probe`：6/6；全量回归：1325/1325。
- 暂存新增内容通过本地 pre-commit 隐私门；完整暂存树按私有 denylist 扫描为 0 命中。
- spec 一致性：四份 delta 已同步到上述三份主规格并完成归档；未勾选的实现/验收义务原样保留为风险。

**Follow-ups**

- 若继续实现归档中的剩余义务，应从对应 archive 恢复或新建后继 change，不能把本次归档视为验收通过。

### 2026-08-31 — Surface csearch queries in grep history

**Task**

修复 `<leader>/` 的 csearch 查询已由 Snacks 持久化、但 `<leader>sH` 历史面板完全看不到的问题。

**Implemented**

- `lua/plugins/snacks.lua` 统一读取 csearch、常规 grep 与旧 rg picker 的 history source，按查询文本去重；
  picker history 清理动作同步清空这些 grep source，不再留下隐形 csearch 记录。
- `tests/cases/grep_cache_spec.lua` 用隔离的 Snacks history 替身锁住 csearch/rg 合并展示与清理行为；
  用例在修复前分别以“只显示 1/2 条”和“未清理 csearch store”稳定失败。
- `tests/cases/ios_dap_coredevice_spec.lua` 处置全量回归暴露的既有 Windows 红灯：只有真实 `xcrun`
  可用时验证成功冻结路径，否则断言 CoreDevice resolver fail closed；不再用其他 executable 冒充 `xcrun`。
- `openspec/specs/ue-code-search/spec.md` 同步 csearch 查询进入统一 grep history、去重与共同清理的可观察契约。

**Pitfalls / Gotchas**

- Snacks 按 picker `source` 分文件保存 history；csearch 使用 `ue_grep_csearch`，原历史面板却只读取 `grep`，
  所以磁盘记录一直存在，缺失发生在读取路由而非写入。
- 宿主相关回归不能靠注入无关 executable 让断言通过；Windows 没有真实 `xcrun` 时应验证 fail-closed。

**Validation**

- 修复前：`grep_cache` 基线 29/29；新增回归后 29/31（2 个预期失败）。修复后：`grep_cache` 31/31、
  `smoke` 19/19、`keymaps` 58/58、`structure` 71/71、`ios_dap_coredevice` 10/10、`dap` 94/94。
- 全量首次运行 1324/1325，唯一失败为 Windows 缺少 `xcrun` 时旧用例注入 `true` 失败；按宿主能力守卫
  修正后全量 `nvim --headless -l tests/run.lua`：1325/1325。
- `stylua --check` 未运行：本机未安装 `stylua`；相关 Lua 文件均已被上述 headless 用例实际加载。
- spec 一致性：已同步 `ue-code-search` 主规格，无独立 delta change。

**Follow-ups**

- 无。

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
