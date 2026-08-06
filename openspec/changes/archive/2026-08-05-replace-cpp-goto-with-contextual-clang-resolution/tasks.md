## 1. 先锁定语义行为与反例

- [x] 1.1 在 `ue_goto_behavior` 中加入按裸 symbol 复用 sibling overload 的失败回归，断言第二个调用点必须发起独立语义请求且不得跳到第一次缓存位置。
- [x] 1.2 新建最小 C++ fixture 与真实 `compile_commands.json`，覆盖无参 / 同 arity 不同类型 / 默认参数 / cv-ref / 模板 / ADL / inherited overload，并记录每个调用点的预期实体身份。
- [x] 1.3 在 fixture 中加入非自包含头文件与两个宏上下文不同的 source TU，锁定 origin context 继承、直接打开多 context 和无 proven context 三种行为。
- [x] 1.4 增加 unsaved overlay 与 stale response 回归，断言 changedtick / document version 变化后旧响应不能跳转或写 jumplist。
- [x] 1.5 新增只读 UE smoke 驱动，定位 `SubmitActiveCmdBuffer` 423 / 428、无参调用和指针调用，不写引擎或项目源码。

## 2. 建立 proven semantic context 模型

- [x] 2.1 新增纯 Lua `SemanticContext` / `ProvenContext` 数据模型与 fingerprint，覆盖 project、active build key、origin TU、compile argv + directory、toolchain identity 和 evidence source。
- [x] 2.2 实现 per-window origin TU 生命周期：从 source TU 跳入头文件时继承，jumplist / buffer 导航继续携带，主动切 context 或 build context 变化时失效。
- [x] 2.3 实现 compiler-emitted `.cpp.json` dependency parser，并以 fixture 断言只产出同时具备 include evidence 与 compile argv 的 context。
- [x] 2.4 实现 Clang `.d` dependency parser、rsp / unity membership 映射，并以 Android 形态 fixture 验证 continuation、escaped path 和多 donor 场景。
- [x] 2.5 汇总 active build context catalog；零候选返回 `unavailable`，单候选直接使用，多候选返回 `ambiguous-context`，不得加入 basename / 目录距离 / 最近使用 heuristic。
- [x] 2.6 为 context picker 与窗口级显式选择增加行为测试，保证选择只在 fingerprint 未变化时复用。

## 3. 实现异步 libclang semantic sidecar

- [x] 3.1 新增 headless Neovim sidecar 入口与最小 LuaJIT FFI 声明，只覆盖 libclang toolchain / CDB / TU / unsaved file / location / cursor / xref / USR / diagnostic API。
- [x] 3.2 复用现有 LLVM / clangd discovery 定位同工具链 `libclang.dll`，实现版本握手和结构化 `unavailable` 探测结果，禁止硬编码项目路径。
- [x] 3.3 实现 NDJSON 请求循环、严格 request / response schema、协议版本、stderr 日志隔离与无效输入恢复测试。
- [x] 3.4 从真实 compilation database 读取 origin TU 的 argv 与 working directory，生成稳定 compile-command fingerprint，拒绝缺失或无法证明的合成命令。
- [x] 3.5 实现 `CXTranslationUnit` cold parse、unsaved overlays reparse、TU epoch 与诊断采集，确保所有 parse/reparse 只发生在 sidecar 进程。
- [x] 3.6 实现 header file + line + column → cursor → referenced cursor → canonical USR → definition / declaration 的语义解析，并对 null、overloaded-decl、invalid / recovery 结果返回非 resolved 状态。
- [x] 3.7 实现小容量 TU LRU、空闲回收和 context 失效；只缓存活 TU，不持久化 definition location。
- [x] 3.8 输出 cold parse、reparse、warm query、TU 数量与进程内存指标到现有性能日志接口，并为指标格式增加回归。

## 4. 实现主 Neovim semantic client

- [x] 4.1 新增 sidecar process manager，使用异步 pipe 启动、增量解析 stdout、发送请求、捕获退出，并在崩溃后最多自动重启一次。
- [x] 4.2 实现 monotonic request token、buffer / cursor / changedtick 快照与 stale 门禁；取消 UI action 不强杀可留下 warm TU 的 cold parse。
- [x] 4.3 收集属于目标 TU 的 modified C++ buffers 作为 unsaved overlays，并保证响应中的 document version 与当前 snapshot 一致后才允许跳转。
- [x] 4.4 实现 `resolved`、`ambiguous-context`、`invalid-semantic-context`、`unavailable` 状态 UI；只有 `resolved` 可写 jumplist 和移动光标。
- [x] 4.5 实现延迟进度通知、用户取消和 sidecar diagnostics 摘要，保证 UI 主循环不等待同步 parse / process exit。

## 5. 接管 C++ gd 决策链

- [x] 5.1 将 active CDB 覆盖的 source TU `gd` 收敛为 clangd precise request；结果只正规化 / 去重，不读取 definition cache、不做 arity / ranking、不自动文本 fallback。
- [x] 5.2 将普通头文件 `gd` 路由到 proven origin context + semantic sidecar，禁止采信 standalone-header clangd 候选作为 build truth。
- [x] 5.3 按同一 USR 实现 definition 优先、declaration 兜底的落点策略；没有同一实体的 definition 时不得搜索同名 `.cpp` body。
- [x] 5.4 将 project / platform / configuration / target / CDB fingerprint 变化连接到 context catalog、origin context 与 sidecar TU 失效。
- [x] 5.5 扩展 definition trace，记录 request id、context id、provider、USR、terminal state、timing 和 stale 原因，不记录项目名、设备标识或其他敏感值。
- [x] 5.6 验证非 C++ 文件类型与显式 csearch / GTAGS 搜索入口保持原行为，C++ `gd` 失败时不会进入这些路径。

## 6. 删除错误与失效机制

- [x] 6.1 移除 C++ `gd` 对 `utils.ue_goto.cache` 的 get / put；若模块无其他合法调用方则删除模块及 `:UEDefCacheClear` / status 表面。
- [x] 6.2 删除不再有调用方的 `syntax_filter`、call / declarator arity overload filtering 与对应“arity 可完成重载决议”的错误注释和测试。
- [x] 6.3 删除 C++ 自动 csearch / GTAGS fallback、pair winner 和按候选首项自动跳转路径，同时保留显式文本导航 / 搜索命令。
- [x] 6.4 更新 `docs/architecture-symbol-resolution.md`，将 authority invariant、header context、terminal states、cache boundary 和禁止 workaround 写成单一权威架构说明。
- [x] 6.5 检查并更新 `docs/CONSTRAINTS.md` / lessons / decisions 中与旧 cache、syntax overload filtering 或 header standalone parse 冲突的陈述。

## 7. 验证、性能与交付

- [x] 7.1 跑 pure-Lua context / protocol / request-token 回归和 `ue_goto_behavior`、`utils` filter，修复全部失败。
- [x] 7.2 在兼容 LLVM 环境跑真实 libclang fixture，逐项验证 USR、declaration / definition、multi-context、invalid context 与 unsaved overlays；缺工具时必须显式报告 skip 原因。
- [x] 7.3 在已连接的目标 UE 工作区执行只读 smoke，证明 423 / 428 解析为 `TArrayView` 重载身份、无参 / 指针调用各自正确，并保存脱敏 trace 证据。
- [x] 7.4 采集 sidecar cold、warm、reparse、内存数据；证明 warm 查询复用同一 TU 且没有按键级 compiler process spawn，检查现有 performance / stall probes 无新增失败。
- [x] 7.5 跑当前保留的稳定 legacy 导航脚本（`test_jumper_headless.lua`）和全量 `nvim --headless -l tests/run.lua`，结果必须全绿。
- [x] 7.6 在 `docs/changelog.md` Unreleased 按模板记录行为变化、breaking fallback 边界与实际 Validation 命令 / 结果。
- [x] 7.7 复查变更只涉及 Neovim 配置、测试、文档和本地 semantic tooling，没有修改引擎 / 项目源码、没有新增依赖、没有遗留敏感路径或项目名。
- [x] 7.8 用 live Nvim 复现并修正 source proof 的 active shard 误选与 raw/merged argv 等值误判；以 active membership + merged freshness 回归和真实 `gd` 落点闭环。
