## 1. 规则先可见（三端第一手 · 纯文档 + spec）

- [x] 1.1 在 `docs/CONSTRAINTS.md` §三新增 **C10 — DAP 归属分层契约**：五层表（L0 宿主工具链 /
      L1 传输 / L2 目标 OS 策略 / L3 调试引擎 / L4 符号语义）+ 每层 owner + 判定手段指针 +
      「失败先报层再给处置」纪律 + 分层目的（34 条坑中多数是外部契约）
- [x] 1.2 在根 `AGENTS.md` 的 SESSION START 增加**一行指针**（不复制正文）：改动带归属分层
      契约的子系统前先读该契约，指向 `openspec/specs/dap-failure-layering/spec.md` 与 C10
- [x] 1.3 在 `lua/ue/dap/AGENTS.md` 增加层表 + 每层 owner 模块 + 失败先报层纪律，
      并在「先读」段落登记新 capability spec
- [x] 1.4 在 `docs/CONSTRAINTS.md` §六维护契约增加一条：新增 DAP 坑必须标注归属层
- [x] 1.5 在 `memory/project_overview.md` 子系统速查表的 DAP 行补 `dap-failure-layering`
      治理 spec；`lessons/README.md` DAP 领域补分层导航一句
- [x] 1.6 `tests/cases/structure_spec.lua` 新增断言：根 `AGENTS.md` 含分层指针、
      CONSTRAINTS 含 C10、`lua/ue/dap/AGENTS.md` 含层表（缺失即 FAIL）
- [x] 1.7 `tests/AGENTS.md` CHANGE-TO-FILTER MAP 与 `docs/testing-regression.md` 同步新增
      `dap_failure_layer` filter 行
- [x] 1.8 跑 `structure` 全绿

## 2. 失败四元组（layer / owner / evidence / remedy）

- [x] 2.1 新建 `lua/ue/dap/failure.lua`：层枚举 `L.HOST_TOOLCHAIN|TRANSPORT|TARGET_POLICY|
      DEBUG_ENGINE|SYMBOL|UNDETERMINED`、`new{}` 构造器（缺 `layer` 即 `error`）、
      `format()` 输出「层 + owner 在前，remedy 在后」。**零 target 字面量**（D1）
- [x] 2.2 `failure.lua` 提供 `evidence.command(argv, rc, out)` 构造器，强制 evidence 是
      命令 + 输出而非结论文本
- [x] 2.3 新建 `tests/cases/dap_failure_layer_spec.lua`：构造器缺层报错、UNDETERMINED 必须
      显式、format 顺序（层先于处置）、evidence 形状
- [ ] 2.4 源码断言用例：扫描 `lua/ue/dap/**` 的 `notify_error|P.error` 调用点，
      新增/迁移过的入口必须经 `failure.*`（允许显式白名单尚未迁移的旧点，白名单只能缩小）
- [ ] 2.5 把 attach 主路径的失败发出点迁到 `failure.*`（bootstrap / staging / server 启动 /
      connect / attach 五处），旧点白名单相应缩小
- [x] 2.6 跑 `dap` `dap_failure_layer` `ue_platform_boundary` 全绿

## 3. 能力探测（取代写死的设备结论）

- [x] 3.1 新建 `lua/ue/dap/capability.lua`：探针描述符注册表
      `{ layer, id, build_argv(ctx), decide(rc, out, err) }` + `run(descriptors, executor)`
      异步编排；执行器注入（生产 `vim.system`，测试 fixture 表）（D3）
- [x] 3.2 在 `lua/ue/dap/android.lua` 注册 L1 探针：adb 可达、serial 已捕获、forward 可建
- [x] 3.3 注册 L2 探针（**每条对应一个已知坑**）：`run-as` 可用性 · app uid 对 sandbox 副本
      `test -x`（K58）· app uid ptrace 可行性（K56）· `getenforce` 模式 · sandbox 路径可写 ·
      package debuggable（K47：不假设 `su`）
- [x] 3.4 L2 探针以**该身份**执行（app uid 用 `run-as`），并在 decide 中拒绝把 shell uid
      结果当依据；不确定时返回 `undetermined` 而非 `fail`（宁可漏拦不可误拦）
- [x] 3.5 fixture 化回归：用 recorded rc/输出复现 K56（ptrace 拒绝）与 K58（rc=126 +
      `can't execute: Permission denied`）两条语义，断言归入 L2 且 remedy 指向确切命令
- [x] 3.6 `host_resource_discipline_spec.lua` 显式抬 `android.lua` spawn anchor 计数并写明
      新增用途（能力探测），不绕过棘轮
- [x] 3.7 跑 `dap` `platform` `host_resource_discipline` `ue_platform_boundary` 全绿

## 4. `:UEDAPPreflight`（逐层判定 · 无需活会话）

- [x] 4.1 新建 `lua/ue/dap/preflight.lua`：L0→L4 顺序编排，同层并行，首个 fail 标为阻塞层，
      其后各层标 `undetermined`；全程异步（P6）
- [x] 4.2 L0 判定：`lldb-dap` 可解析 + 版本 ≥ 22.1.6（C1 forward-only）+ python 包存在性
      （K57：区分「liblldb 链了 python311.dll」与「`lldb` 包存在」）
- [ ] 4.3 L4 判定：符号包与设备 versionCode 一致性（本月未闭环的 follow-up）+ slide 可解析性
- [x] 4.4 在 `lua/ue.lua` 注册 `:UEDAPPreflight`（**仅注册，实现在 dap/**，保持 10562 行 ratchet）
- [x] 4.5 输出渲染：逐层 ✓/✗/? + evidence 命令 + 阻塞层的 remedy；可在无活会话时运行
- [x] 4.6 `commands_spec.lua` 冻结清单 82 → 83 并加注册断言
- [x] 4.7 跑 `dap` `commands` `stability` 全绿

## 5. attach 接入 L2 门禁

- [x] 5.1 `bootstrap_session` 在启动 device server 与 `platform connect` **之前**跑 L2 子集，
      红灯即以 `failure.new{layer=TARGET_POLICY}` 终止
- [x] 5.2 实现逃生开关 `UE_DAP_SKIP_PREFLIGHT=1`，跳过即在后续失败反馈中留痕（D4）
- [x] 5.3 探针超时按 P6 放行并标 `undetermined`，MUST NOT 阻塞主循环
- [ ] 5.4 回归：L2 红灯时断言「未发起 connect」；逃生开关时断言留痕文本存在
- [x] 5.5 跑 `dap` `platform` `ue_platform_boundary` 全绿

## 6. `:UEDAPSmoke`（真机端到端 + 脱敏证据）

- [x] 6.1 新建 smoke 入口（实现在 `lua/ue/dap/`）：跑 preflight → attach → threads →
      bp resolved 判据 → detach，逐层记录判定
- [x] 6.2 证据落 `tools/evidence/android-dap/`，沿用 `ios-dap` 脱敏形态（K55：无真实
      serial / package / pid / 个人路径，只留摘要与 digest）
- [x] 6.3 无设备时报「不适用」而非通过；禁止注入假可执行文件/假宿主（宿主能力守卫）
- [x] 6.4 在 `lua/ue.lua` 注册 `:UEDAPSmoke`；`commands_spec` 冻结清单 83 → 84
- [x] 6.5 回归：脱敏断言（证据中不得出现真实标识形状）+ 不适用路径断言
- [x] 6.6 跑 `dap` `commands` `structure` 全绿

## 7. 沿 L1/L2/L3 缝拆分 `android.lua`（纯结构，最后做）

- [x] 7.1 抽 `lua/ue/dap/android/_transport.lua`（L1：adb / forward / staging 传输跳）
- [x] 7.2 抽 `lua/ue/dap/android/_policy.lua`（L2：能力探针 + 沙箱 staging 判定）
- [x] 7.3 抽 `lua/ue/dap/android/_engine.lua`（L3：initCommands/attachCommands 序列构造）
- [x] 7.4 主 `android.lua` 只保留编排与 session 状态；新文件均 ≤ 800 行（`stability` 上限）
- [x] 7.5 跑全量回归，确认拆分零行为变更（用例数不减、无新 FAIL）

## 8. 收尾（Definition of Done）

- [x] 8.1 `docs/changelog.md` Unreleased 追加条目，Validation 写明所跑范围与结果 +
      spec 一致性处置（本 change 承载 spec 变更）
- [x] 8.2 `docs/TOOLING.md` 更新 Android DAP 状态段：加入 preflight 与分层排查入口
- [x] 8.3 `openspec validate --strict` + 全量 `nvim --headless -l tests/run.lua` 全绿
- [x] 8.4 归档本 change（`openspec archive`），确认 delta 已并入主 spec
