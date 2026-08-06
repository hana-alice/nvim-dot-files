## Context

见 `proposal.md` 的动机与 `specs/cpp-contextual-definition-navigation/spec.md` 的行为合同。

现行链路在 C++ `textDocument/definition` 前读取按 `receiver::symbol` / 裸 `symbol` 持久化的 location，并只以“目标附近仍出现同名文本”判断有效。现场 trace 已证明：一次无参 `SubmitActiveCmdBuffer` 解析把头文件第 421 行写入裸键，随后第 423 行的另一重载调用在未请求 clangd 的情况下命中该键。

移除缓存只能消除直接错跳，不能解决非自包含头文件的语义上下文。现场 `textDocument/ast` 把第 423 行表示为 `UnresolvedMemberExpr`、`RecoveryExpr contains-errors` 与未决 `CallExpr`；`clangd --check` 将头文件当作 `-x c++-header` 主文件并在真实 include 前置上下文缺失时报告 21 个错误。相反，使用真实 donor source TU 的 Clang AST 对同一位置求值，两条独立 TU 均把第 423、428 行绑定到第 419 行的 `TArrayView` 重载。

约束：不得修改引擎或项目源码；不得引入新的第三方包；必须异步；现有 LLVM 安装同时提供 clangd 与 `libclang.dll`；现有 compile database、平台配置和 build dependency artifacts 可以只读复用。

## Goals / Non-Goals

**Goals:**

- 让 C++ `gd` 的目标完全由真实 TU 中的 Clang 语义身份决定。
- 为头文件维护显式、可追溯的 origin TU context，不把 standalone header parse 当作 build truth。
- 删除会跨调用点、重载或配置泄漏的 application-level location cache。
- 在不阻塞 UI 的前提下复用 warm TU，并对冷解析、失效和取消提供确定状态。
- 让所有失败都“诚实失败”：无 context、invalid AST、dependent 或多 context 分歧均不自动猜测。

**Non-Goals:**

- 不重写 C++ overload resolution，也不从 Tree-sitter 推导参数类型或转换排名。
- 不修补 UE 头文件的自包含性，不生成 per-file forced include 源码补丁。
- 不把 csearch / GTAGS 从显式搜索、references fallback 或非 C++ 文件路径中删除；本 change 只将它们移出 C++ `gd` 自动决策链。
- 不保证跨 TU 都存在函数体定义；当前 context 中只有 declaration 时，正确落点是同一 USR 的 declaration。
- 不构建或维护自定义 clangd fork；若标准 libclang sidecar 无法满足后续实测性能，另立 change 评估 clangd extension，而不是在本 change 中暗加 heuristic。

## Decisions

### 1. 将 C++ 路径分成 source-TU 与 header-in-context 两类

`.cpp` / 真实 CDB TU 继续以其已附着 clangd 的 `textDocument/definition` 为首选语义 provider；sidecar 必须先证明该 source 是明确选中的 active shard 成员、也存在于 clangd merged CDB，且 merged CDB 不早于 active shard / selection manifest。raw shard command 只提供构建成员 provenance；实际查询使用 clangd 消费的 post-processed merged command。返回值只按 LSP 位置正规化和同请求去重，不经 symbol cache、arity filter 或文本 ranking。空、多义或失败保持为语义状态，不触发自动文本 fallback。

普通头文件不直接采信“把头文件作为主文件”的 clangd 请求。它必须携带一个 `SemanticContext`：

```text
SemanticContext = {
  project_root,
  active_build_key,
  origin_tu,
  compile_command_fingerprint,
  source_of_evidence,
}
```

原因：头文件的宏、include 顺序、条件编译和名称查找属于包含它的 TU，而不是头文件路径本身。

替代方案“所有文件都走 standalone clangd”已被现场 recovery AST 证伪；“为出错头文件补一个 include”不能覆盖任意宏状态和多 TU 差异，属于 workaround，拒绝。

### 2. origin context 只来自可验证 provenance

context 来源按以下规则建立，但不按优先级猜目标：

1. 从 source TU 跳进头文件时，直接把已经过 active-shard membership 与 merged-CDB freshness 证明的 post-processed source compile context 记录为该窗口导航链的 origin；不得用 `catalog(source.cpp)` 反推。
2. 直接打开头文件时，从 active build 的 compiler-emitted dependency evidence 中枚举真实 includer；Windows 可消费 `.cpp.json`，Android / Clang build 可消费 `.d` / rsp 与 unity membership。
3. 候选只有同时存在 include evidence 和可还原的真实 compile argv 时才是 proven context。
4. 一个 proven context 可直接使用；多个则展示 context picker；零个则 `unavailable`。

同 basename、同目录、最近访问、最短 include path 均不构成 provenance，禁止使用。

### 3. 使用独立 headless Neovim + LuaJIT FFI 承载 libclang sidecar

新增本地 `ue-clang-semanticd` sidecar，由 headless Neovim 进程运行并通过 LuaJIT FFI 加载与 clangd 同工具链的 `libclang.dll`。主 Neovim 通过 NDJSON / JSON-RPC 风格的 stdin/stdout 协议通信，解析工作永远不进入 UI 主循环。

选择该形态的原因：

- Neovim 与 LLVM 已是现有运行前提，不新增 Python package、Node package 或网络服务。
- libclang 提供 compilation database、translation unit、unsaved files、source location → cursor、referenced cursor、definition 和 USR 的稳定 C API。
- sidecar 可长期持有 TU，避免每次 `gd` 启动约 9–10 秒的 cold CLI 解析。
- 进程崩溃与内存可由主进程隔离、重启和观测。

替代方案：

- 每次 spawn `clang-query` / `clang-check`：独立实验可证明语义，但 cold latency 不可接受，拒绝。
- 主 Neovim 直接 FFI：会让 parse/reparse 阻塞 UI，拒绝。
- Python `clang.cindex`：需要额外 package；纯 `ctypes` 也引入另一个 runtime surface，当前无收益，拒绝。
- 自定义 clangd extension：可复用 ParsedAST，长期性能潜力最好，但需要维护非上游二进制和协议；本 change 暂不选择。

### 4. sidecar 查询以真实 TU 和 unsaved overlay 求值

主进程发送：request id、context、header URI、精确 UTF-8 byte position、document version，以及所有属于该 TU 且当前已修改的 open-buffer contents。sidecar 使用真实 compile argv 构建 / reparse `CXTranslationUnit`，再执行：

```text
header file + line + column
  → CXSourceLocation
  → most-specific CXCursor
  → clang_getCursorReferenced
  → canonical cursor / USR
  → definition（若当前 TU 可证明）或 declaration
```

响应只允许：

```text
resolved { usr, declaration, definition?, context_id, document_version }
ambiguous-context { context → semantic target[] }
invalid-semantic-context { diagnostics, context_id }
unavailable { reason, probes }
```

空 USR、overloaded-decl cursor、recovery / invalid cursor 或错误前置上下文不得降格成首候选。

### 5. 删除 persistent definition-location cache，只缓存活 TU

`utils.ue_goto.cache` 不再参与 C++ `gd`。不尝试通过扩展 key 加入 arity、receiver 或格式化 signature 来挽救它，因为 C++ 实体意义还受模板实例化、隐式转换、宏、using、ADL、继承、cv/ref 和编译配置影响。

sidecar 的 LRU 缓存对象是 `CXTranslationUnit`，key 为：

```text
origin_tu + active_build_key + compile_command_fingerprint + clang_toolchain_identity
```

单次 query result 只在相同 context id、URI、position、document version 与 live TU epoch 内可短暂复用，不落盘。CDB / platform / config / project 变化销毁对应 context；unsaved contents 变化触发 reparse 并增加 epoch。

### 6. 请求 token 负责取消 UI side effect，不强杀有价值的冷解析

每次 `gd` 分配单调 request token。光标移动、buffer 切换、再次 `gd` 或 changedtick 变化使旧 token stale；旧响应不得跳转或写 jumplist。若 sidecar 正在做首次 cold parse，可让解析完成并留下 warm TU，但取消当前 UI action。sidecar 退出、协议错误或超时都归入 `unavailable`，可重启一次，但不触发文本跳转。

### 7. declaration / definition 落点服从同一语义身份

先确定 referenced entity 的 USR，再决定落点：当前 context 能证明 definition 时优先 definition；否则使用该 USR 的 declaration。不得为了追求 `.cpp` body 把同名 workspace symbol 当成 definition。

此决策把“选择哪个重载”和“落 declaration 还是 definition”分离：前者必须语义唯一，后者只能在同一实体身份内变化。

### 8. 回归采用小型真实 CDB fixture 加 UE 只读 smoke

测试分三层：

1. 纯 Lua：context provenance、fingerprint、request token、状态机和协议解析。
2. 本地集成 fixture：最小 C++ 工程 + `compile_commands.json`，覆盖同 arity 不同类型、模板、ADL、默认参数、cv/ref、宏 context、多 TU 分歧和 unsaved overlays；用真实 libclang 断言 USR / location。
3. UE 只读 smoke：`SubmitActiveCmdBuffer` 423 / 428 → `TArrayView` 重载身份，无参调用 → 无参重载，且 trace 中不存在裸 symbol cache hit。

集成测试缺少兼容 libclang 时可明确 skip 并报告原因，但提交前的目标环境实机验证必须执行，不得用 mock 结果代替语义证明。

## Risks / Trade-offs

- [Risk] 每个 UE TU 的 preamble / AST 内存很大，sidecar 与 clangd 会重复占用内存 → [Mitigation] 小容量 LRU、空闲回收、按窗口 origin context 预热，并把内存 / parse timing 写入现有性能日志。
- [Risk] libclang C API 暴露的信息比 Clang C++ AST 少 → [Mitigation] 只依赖稳定的 location、cursor、referenced、definition、USR 和 diagnostics；若任一信息缺失则诚实失败，不解析 AST dump 文本。
- [Risk] Android `.d`、Win64 `.cpp.json` 与 unity rsp 的 dependency 形态不同 → [Mitigation] 各 parser 只接受 compiler-emitted evidence，并通过统一 `ProvenContext` 数据结构汇合；不以文件名 heuristic 补洞。
- [Risk] compile argv 含相对路径或需特定 working directory → [Mitigation] context 同时保存 CDB directory，sidecar 串行切换到该 directory 后解析，并用 fingerprint 覆盖 argv + directory。
- [Risk] 直接打开多上下文头文件会多一次选择 → [Mitigation] 选择绑定当前窗口导航链；只有用户切 context 或 active build 改变才再次询问。
- [Risk] cold parse 实测约 9–10 秒 → [Mitigation] 异步进程、可取消 UI、origin TU 预热、warm TU 复用；禁止按键级 CLI spawn。

## Migration Plan

1. 先为当前错误缓存链和 `SubmitActiveCmdBuffer` 建立失败回归，锁定“错误跳到 sibling overload”的现状。
2. 引入 C++ semantic result 状态机和 request-token 门禁，但暂不切换默认 `gd`。
3. 实现 proven context catalog、sidecar 协议与 libclang fixture；完成 source / header 两条语义集成测试。
4. 将 C++ `gd` 切到 precise source-TU / contextual header 路径，同时停止 C++ cache put/get 和自动文本 fallback。
5. 删除不再有调用方的 arity overload filter、pair winner 逻辑及错误文档陈述；保留显式搜索入口。
6. 跑目标回归、legacy scripts、全量 headless suite 和 UE 只读 smoke，记录 cold / warm / memory 数据。
7. 若出现严重回归，回滚整个 change 恢复旧链；不得只恢复 symbol cache 或 arity guess 作为临时补丁。
