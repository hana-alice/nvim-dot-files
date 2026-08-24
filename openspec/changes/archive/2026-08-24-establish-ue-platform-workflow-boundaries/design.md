## Context

当前实现已经具备 `utils.platform` host driver、`ue.targets` target driver、`host_operations` matrix、`ue.target_tasks` runner 与 `ue.dap.platforms` registry，但缺少 target-specific side-effect workflow 的正式层级。纯 target driver 不应持有 Neovim UI/job lifecycle，通用 `ue.lua` 又不应拥有 IOS/Android 策略，结果是签名、设备发现、安装、启动、Apple semantic 与错误解释持续回流核心。

`lua/ue.lua` 还受 LuaJIT 单 chunk local 上限影响，大量能力被挂到 `CORE_RT` 以绕过 local slot 压力；公共 `ue.*` API、81 个用户命令、持久状态键、project bucket/cache layout 和异步行为均已有回归或现场依赖。迁移必须先锁行为、保持 façade 和数据兼容，再改变代码归属。

现有测试同时存在两类问题：一类 contract 测试正确验证 matrix/plan；另一类直接切取 `ue.lua` 函数体，反向要求 iOS/Android workflow 留在核心。边界回归草案从未实施，而且只覆盖直接 OS probe/import，不能发现 target lifecycle policy 回流。

## Goals / Non-Goals

**Goals:**

- 建立 host capability、target policy、target workflow、generic runner、public façade 五层依赖方向。
- 让平台专属异步状态机拥有明确模块归属，同时保留 target driver 的纯 plan/parser 特性。
- 在不改变用户行为和持久数据的前提下迁出 `ue.lua` 的 iOS/Android/Apple workflow 与散落的 host tool policy。
- 用行为测试和 AST/结构化边界回归同时证明“功能仍工作”和“平台逻辑没有继续回流”。
- 将平台 invariant 从 Apple 功能规格提升为全平台 canonical capabilities，并让 feature spec 只引用、不复制这些 invariant。

**Non-Goals:**

- 不重命名或删除命令、keymap、公共 `ue.*` API、状态键、cache path 或日志入口。
- 不改变 Android/iOS 的构建、部署、安装、启动、DAP 路线与已验证工具链。
- 不在本 change 全面重写搜索、CDB、DAP 或拆完 `ue.lua` 的所有非平台职责。
- 不在本 change 合并全部历史 Android DAP main specs；它们的语义去重另立后续 change，本 change 只建立 dispatch 边界并避免新增重复 invariant。
- 不引入新依赖；源码边界扫描复用现有 Tree-sitter Lua parser。

## Decisions

### D1 — 增加 target workflow controller，而不是放宽 core 或污染 target driver

采用以下依赖方向：

```text
utils/platform/<host>       ue/targets/<target>
       host capability        pure policy / plan / parser
                 \            /
                  \          /
             ue/workflows/<target>/<operation>
             async state machine / UI / progress / cleanup
                          |
                 ue.target_tasks + shared runtime
                          |
                    ue.lua public façade
```

`lua/ue/workflows/init.lua` 提供 operation dispatch/registry；target ID 可以作为注册表数据出现，但不能成为通用执行分支。`lua/ue/workflows/_runtime.lua` 只提供 policy-free 的 context snapshot、task execution、progress completion、project-change guard 与 runtime persistence seam。target-specific controller 按 operation 拆分，例如 IOS semantic/signing/device/install/launch 与 Android install/SO，单文件继续受 800 行门禁。

workflow controller 可以使用 Neovim UI、异步 task 与 target-specific parser，但不得直接探测 host OS、不得调用另一个 target workflow、不得自行绕过 `host_operations`。执行前必须先由 target resolver 验证 host-target-operation 组合，再消费 target driver 的 plan/descriptor。

`ue.lua` 保留 context、命令注册、公共 API façade 和 generic dispatch；现有 `M.*` test seam 若仍有外部价值则薄转发到新 owner，不复制实现。

**Rejected:** 把 UI/job lifecycle 全塞进 `ue/targets/ios.lua` 或 `android.lua`。这会破坏纯 planner、扩大 driver 到新的巨模块，并降低 headless contract 可测性。

**Rejected:** 继续让 `ue.lua` 作为“有意 monolith”拥有 workflow。该方案正是当前回流根因，也已经触发 local slot workaround、重复分支和测试错向。

### D2 — Workflow 以不可变 operation snapshot 启动

generic dispatch 在开始时冻结 canonical project、target、configuration、host id、device/signing/runtime identity 与 operation owner。callback、poller、cleanup、stop/status 均消费该 snapshot，不重读后来变化的 current platform/device 选择。

snapshot 不创建新的磁盘 schema；它从现有 project state/runtime 字段构造进程内值。现有 `target_runtime.IOS`、Android serial、signing identity、Apple semantic marker 等持久键保持原样，由新 owner 通过注入的 state seam 读写。

这同时解决 DAP stop 当前按 `M.current_platform()` 猜 owner 的风险：DAP attach/launch 注册 session owner，stop/status/reattach 优先按活跃 session metadata 分派；没有活跃 session 时才按命令自身支持面返回结构化 unavailable，不能猜另一个 target。

### D3 — Host tool/path policy 由 capability 返回，不由调用方解释 host

host driver 分为所有 host 同形的基础能力和拥有者专属的 optional capability。工具解析统一采用：

```text
显式 env override → ue.config extra candidates → host driver defaults
```

driver 返回候选、executable/argv plan、path identity 或 separator/suffix 信息；`index`、`code_search`、`clipboard`、semantic sidecar 等调用方只消费结果。optional capability 缺失返回结构化 unavailable，不添加“存在但永远失败”的假方法，也不回退到别的 host。

`shell.lua` 继续只接受显式 shell kind 与 executable 并负责 quote/argv。PowerShell/sh/cmd 的选择、安装入口和 PATH 形状属于 host driver/tool-resolution owner。

**Rejected:** 仅允许调用方读取 `platform.is_windows` 后继续分支。兼容 boolean 可以保留给公共 API，但不能再作为新 tool/path policy 的扩展 seam。

### D4 — 先把源码位置测试改为行为契约，再移动实现

迁移前为每个待移动 workflow 锁定：输入 snapshot、driver plan、task argv/cwd、progress terminal state、错误结果、project/device 变化、temp cleanup、runtime persistence 和公共 façade。现有按 `source:find()` 切 `ue.lua` 函数体的测试改为调用注入 seam 或 registry handler；只有架构扫描测试读取源码结构。

边界回归复用 Tree-sitter Lua AST，并以规则表表达：

- 直接 OS probe 只能出现在 host platform owner；
- 通用层的条件表达式不得把 target/platform 变量与 `Android`、`IOS`、`Mac`、`Win64`、`Linux` literal 比较；注册表、命令声明和展示数据允许；
- target-specific script/path/backend/error token 的 string literal 只能出现在对应 target driver/workflow、脚本或测试 fixture；
- 通用层不得 require concrete host/target workflow，不得跨 target import；
- shell executable 与 host tool candidate 不得在调用方重新构造。

扫描必须按 AST 节点和语义上下文判定，不用裸 regex/grep；白名单必须绑定规则编号、精确文件与理由，不能按整个 `ue.lua` 放行。

### D5 — `ue.lua` 使用单调下降 ratchet，不设永久豁免

现有“grandfathered file 不限增长”改为版本化最大行数。change 开始时记录 12,002 基线；每批迁移后下调到实际行数，最终值必须小于起始基线，后续改动不得提高。行数只作为回流报警，不替代 D4 的语义边界测试。

新 workflow 文件不得加入 >800 行白名单；接近上限时按 operation/state owner 拆分，而不是创建一个新的 `ios.lua` 巨模块。

### D6 — 分阶段迁移且每阶段保持 façade 可回退

迁移顺序按依赖从外向内：

1. 改写测试锚点并建立暂以现状为基线的 boundary report；
2. 收口 host tool/path resolution，消除通用模块的直接 host policy；
3. 迁移 Android install/SO/Gradle cleanup workflow；
4. 迁移 IOS semantic、signing、device、install、launch workflow；
5. 将 DAP stop/status/reattach 改为 session-owner dispatch；
6. 删除 core 中已无调用的 compatibility implementation，下调 ratchet，并把 boundary report 收紧为零违规。

每阶段由 `ue.lua` façade 委托新 owner，公共调用方不感知模块路径变化。阶段失败时可把 façade 临时指回上一 owner；由于没有持久 schema 迁移，不需要数据回滚或双写。

### D7 — Canonical invariant 与 feature behavior 分开

六个新 capability 是平台边界唯一规范来源。Apple semantic、iOS lifecycle、Android SO 与 multi-instance specs 只描述自身行为及消费的 invariant，不再复制 host/target/DAP 通用 SHALL。已经与当前实现冲突的 Android F9 reattach、sandbox gdbserver 与固定 serial 诊断要求在本 change 内同步改正，避免新边界建立后 main specs 仍给出相反指令；其余 Android DAP 语义合并仍留给后续独立 change。

旧 ADR/iteration log 保留历史证据，但顶部必须标明 snapshot/superseded 并指向当前 architecture/spec。`docs/CONSTRAINTS.md` 继续作为索引，不复制完整规范正文。`lua/ue/AGENTS.md` 改为 façade/orchestration 规则，删除“故意 monolithic”的许可。

## Risks / Trade-offs

- **[异步迁移漏掉 completion/cleanup 分支]** → 迁移前用注入 seam 锁定成功、失败、取消、project change、device change 和 task-start failure；按 workflow 单独搬迁并逐批回归。
- **[模块拆分引入循环 require]** → workflow/runtime 通过显式 dependency table 注入 context/state/task/progress，target driver 与底层模块禁止 load-time `require("ue")`。
- **[AST 门禁误报展示字符串或命令注册]** → 按 AST parent/context 区分注册表数据、UI 文本与 executable branch；白名单精确到规则和文件，不使用目录级放行。
- **[只移动代码但制造多个新巨模块]** → 保留 800 行上限，按 operation/state owner 拆分，并用 dependency/ownership contract 审核公共 helper。
- **[公共 API 或持久状态兼容回归]** → `ue.lua` 保留薄 façade，API/commands 冻结清单不变；持久键和 cache paths 不迁移，旧/新 owner 不双写新格式。
- **[一次 change 影响面较大]** → 严格执行 D6 顺序；依赖阶段串行、独立测试可并行，任何阶段未绿不得开始下游迁移。

## Migration Plan

1. 记录现有行为 fixture、公共 API/commands、状态键与 `ue.lua` 12,002 行基线。
2. 将源码位置型测试改为 contract/behavior 测试，先证明测试迁移不改变运行时。
3. 增加 workflow/runtime registry 与 host capability，不接管用户入口时先完成独立测试。
4. 按 Android → IOS semantic/readiness → IOS lifecycle → DAP owner 的顺序切换 façade，每次只切一个 operation。
5. 删除对应 core implementation、收紧 AST 规则与行数 ratchet，确认不存在双 owner。
6. 跑受影响 filters、structure/OpenSpec strict validation、静态分析和全量回归；同步 changelog、architecture、CONSTRAINTS、AGENTS 与测试映射。

回退以 operation façade 为边界：在某批验收失败时恢复该 operation 的旧委托并保留已通过的底层 capability，不改变磁盘数据。最终归档前不得保留旧/新实现双路可选开关，避免长期双真相。
