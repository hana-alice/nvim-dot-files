# Symbol Resolution Architecture — C++ 语义权威与非 C++ 兼容链

> 最后更新：2026-09-09
> 权威代码：`lua/utils/lsp_fallback.lua`、`lua/utils/ue_goto/semantic_*.lua`、
> `lua/ue/index/`、`lua/ue/clangd_commands.lua`、`scripts/ue_clang_semanticd.lua`、
> `scripts/ue_clang_cursor_shim.c`

## 1. Authority invariant

C/C++ `gd` 只接受当前 active build 中由 Clang 证明的实体身份。唯一合法主键是
canonical USR（或等价的 compiler-owned identity）；函数名、receiver 文本、arity、
渲染后的 signature、候选顺序、文件距离和最近访问记录都不是身份。

因此 C++ `gd` 不读取或写入 definition-location cache，不调用 workspace symbol、
csearch 或 GTAGS 自动猜目标，也不让 Tree-sitter 决定或否决语义结果。显式搜索、
references 和非 C++ 文件仍可使用 csearch / GTAGS；这是另一条能力边界。

环境要求按 route 区分：source 需要 clangd 与当前 build/CDB；header 才额外要求匹配 libclang。
缺少 header 的 native tooling 不再提前阻断独立的 source clangd 路径。

## 2. 两条 C++ 路径

### 2.1 Active CDB 覆盖的 source TU

`.c/.cc/.cpp/.cxx/.m/.mm` 由 `ue.clangd_commands` 从当前 controlled active CDB 查询
post-processed exact command，并通过 clangd 官方 `compilationDatabaseChanges` transport 绑定到
打开的 source buffer。active CDB/selection manifest 证明当前构建成员身份；exact-command 查询失败时
保持 unavailable，不退回文本猜测。identity 阶段在不可变精确光标 snapshot 上执行：

clangd 启动资格来自同一组持久化证据，而不是进程内“执行过 prepare”标志。当前 tuple 的 build key、
selection/artifact、controlled/semantic CDB 与源 CDB 签名仍为 ready 时，Nvim 重启后直接复用；证据
missing/stale 或 tuple 变化时才 defer。同进程内也逐次验证，避免更新 CDB 后沿用旧的 positive cache。

1. 只向已接收 exact command 的 clangd client 请求 `textDocument/symbolInfo`，聚合响应中全部 canonical USR，不选数组首项；
2. definition 请求只允许同一 USR 的 client 参与；
3. 去除当前位置后必须只剩一个 destination，且与该 identity 的 definition evidence 相符；声明不可冒充 definition，否则返回结构化 role/empty/multiple reason；
4. 目标为 header 时，把 exact command 记录为该窗口后续 header-in-context 查询的 origin TU evidence。

若 clangd restart 后已先用 synthetic CDB 的邻近 TU 推断命令打开 source，首次 exact transport 会对
同一 client/command 只执行一次有序 `didClose → didChangeConfiguration → didOpen`，用当前 buffer 全文
重建 AST 后再回答 identity；symbolInfo 与 definition 共用 30 秒 provider hard ceiling，覆盖 UE 冷 preamble。

Apple UBT 会把部分扩展名仍为 `.cpp/.h` 的 mixed source 用 `-x objective-c++[-header]` 编译。exact-command
transport 同时消费这项 compiler language evidence：buffer 继续保持 `cpp` filetype 与 C++ Tree-sitter，另将
内置 `objcpp` syntax 作为 lexical overlay，使 `@autoreleasepool`、Objective-C message/interface 等构造可见。
普通 C/C++ argv 不启用 overlay；不能把 `objcpp` 整体映射到只继承 C grammar 的 `objc` Tree-sitter parser。

source 路径不再为每次 `gd` 让 sidecar 重读 200MB+ 全量 CDB 或重复创建 libclang TU；sidecar 保留给
必须在 proven origin TU 内求值的 header 路径。

这条路径不会读取旧 location cache，也不会在 clangd 失败后进入文本 fallback。
跳入头文件时直接携带这个已证明的 source compile context；不得通过
`catalog(source.cpp)` 间接猜回 origin TU。

active shard 选择优先服从仍匹配 platform/config/build class 的 `manifest.active`；
显式 target 存在时服从该 target。只有缺少这些明确选择时才在同 build class 中选择
候选，不能因为另一个 target 的单文件 hot shard mtime 更新就把它当成当前构建。

### 2.2 Header-in-context

普通头文件不能作为独立主文件代表真实 build。查询必须带一个 proven origin TU：

```text
ProvenContext = {
  project_root,
  active_build_key,
  origin_tu,
  compile = { file, directory, argv },
  compile_command_fingerprint,
  toolchain_identity,
  evidence,
}
```

context 只能来自两类可验证 provenance：

- 从 source TU 跳入头文件后，当前窗口继承该 source 的真实 origin context；
- 直接打开头文件时，从 active build 的 compiler-emitted `.cpp.json`，或
  `.d + .o.rsp + unity` 证据枚举真实 includer，并与 active CDB 交叉验证。

零个 proven context 返回 `unavailable`；一个直接使用；多个要求用户选择。
同 basename、同目录、最短路径或最近使用时间不得用于自动选择。

source 与 header 共用同一 identity/destination authority。声明处不是终点：只要当前 TU
没有 body，就继续用 canonical USR 查 module AST。对 virtual call，Clang 在精确表达式上
选中的 derived override USR 必须原样保留；若静态类型只证明 base method，则不能根据运行时
可能性猜派生实现。

## 3. Semantic sidecar

### 3.1 模块归属

| 模块 | 所有权与依赖边界 |
|---|---|
| `lsp_fallback.lua` / `provider.lua` | 稳定公共入口、命令和路由；provider 转发到具体能力 |
| `semantic_navigation.lua` | action coordinator：最终 freshness、jump、成功后的 lineage、进度与终态通知 |
| `semantic_report.lua` | 纯报告数据：Explain、通知文本、脱敏和 probe payload；不执行请求或修改编辑器 |
| `lsp_transport.lua` | 通用 LSP 请求、能力与超时；不发现 UE 构建，不调用 legacy search |
| `clangd_adapter.lua` | clangd exact-command transport、canonical USR 与 identity 限定的 destination 请求 |
| `compat_navigation.lua` | 非 C++ definition 的重试/fallback 与 references 兼容策略 |
| `semantic_environment.lua` | 只读环境快照与 transition 判定；不 evict、不清 lineage、不启动进程 |
| `semantic_client.lua` | composition root：分开的 transport/action state，环境变化处置与 dispose |
| `semantic_client_runtime.lua` / `semantic_session.lua` | 队列、进程、deadline 与实际 compiler handshake session；通过请求级 validity callback 判断排队请求是否过期 |
| `semantic_client_actions.lua` | 编辑器快照、overlay、取消与窗口 context；返回 origin evidence，由 coordinator 在 jump 成功后提交 |
| `semantic_sidecar.lua` | native composition root、协议路由与聚合 metrics |
| `semantic_sidecar_tu.lua` | TU store：CXIndex、TU 与 compilation database handles 的创建和释放 |
| `semantic_sidecar_catalog.lua` | compiler evidence catalog，经显式依赖访问工具链和 metrics |
| `semantic_sidecar_definition.lua` | definition resolver：自己的 LRU 与 controlled CDB cache，通过注入接口借用 TU |

sidecar 三个组件各自实例化；TU shutdown 不再顺手删除 definition cache。根对象统一 evict/shutdown 时
显式调用相关 owner。client transport 与 action 不共享可变 state，transport 不依赖 action installer
稍后补上的方法。source 与 header 保留各自的证明流程，只在 coordinator 汇合跳转副作用。
navigation install 返回独立实例；公开 lineage getter 返回副本，外部修改返回值不会越过提交入口改写内部状态。

### 3.2 Native 语义执行

主 Neovim 只负责异步进程 I/O、请求快照、context 选择和跳转副作用。独立 headless
Neovim 通过 LuaJIT FFI 加载与 clangd 同目录的 `libclang.dll`，通过 versioned NDJSON
协议处理 `handshake/catalog/prove/query/lookup-definition/stats/evict/shutdown`。

sidecar 使用 compiler-emitted argv 与 working directory 创建真实
`CXTranslationUnit`，并在同一 TU 中执行：

```text
file + line + column
  -> cursor
  -> referenced cursor
  -> canonical cursor / USR
  -> definition（存在时）或同一 USR 的 declaration
```

空 USR、null / invalid cursor、`OverloadedDeclRef`、recovery AST 或不同 context 的
不同 USR 都不能降级成“第一候选”。本地缺少匹配 semantic tooling 时返回
`unavailable`，不会写引擎或项目源码，也不会生成 forced-include 补丁。
error/fatal diagnostics 会阻止该 TU 提供语义答案；失败 TU 下次查询重新解析，允许补齐依赖后恢复。
多 context 查询和 module lookup 的部分解析/遍历失败不能构成唯一目标证明。
CDB 解码同时保留被拒绝的编译记录和完整性状态；catalog、prove、lookup 不能把成功解析的子集冒充完整输入。
compiler 返回的相对目标与依赖路径统一按该 TU 的编译目录解析。

`clang_getCursorDefinition` 的可见域是当前 origin TU 的 AST。若头文件 declaration
对应的 out-of-line body 位于另一 source TU，identity query 仍返回 canonical USR，但
`definition` 合法为空。`lookup-definition` 随后读取同 generation 的 current→hot→full
controlled CDB；每条记录只来自 active build 的 compiler-authored UBT unity membership，
无法构成真实 unity 时退回 exact per-file TU。phase artifact 携带 portable module/member metadata；
发布给 clangd 的 `compile_commands.json` 只保留标准字段，避免其 JSONCompilationDatabase parser
因内部 provenance key 拒绝整份受控索引。

LuaJIT FFI 不能可靠把 by-value `CXCursor` callback 传给 `clang_visitChildren`。因此 sidecar
按当前 toolchain identity + C 源码 hash 懒编译一个最小 C ABI shim；shim 不加载第二份
libclang、不重新 parse，只在已有 `CXTranslationUnit` 上遍历 declaration cursor，比较
exact canonical USR 并返回有 body 的位置。一个唯一位置才能 resolved；零个、多个、遍历
overflow 或 64-context cap 都结构化 fail closed。module context 暂不可用时才允许 secondary
clangd；其 `symbolInfo` USR 必须与 sidecar USR 完全相同。

## 4. Terminal states 与 UI 副作用

每个 C++ 请求只能结束为：

| 状态 | 含义 | 是否跳转 |
|---|---|---|
| `resolved` | 导航 coordinator 已完成合法目标跳转 | 已跳转 |
| `ambiguous-context` | 多个 proven context 产生不同真实结果 | 否；先选 context |
| `invalid-semantic-context` | TU 可建，但当前位置是 invalid/recovery/dependent 结果 | 否 |
| `unavailable` | 工具、CDB、proven context 或协议不可用 | 否 |

每次 `gd` 带 monotonic action token、window/buffer/cursor/changedtick 和 document
version 快照。响应到达时任一项变化即 stale；stale 响应不得改窗口、jumplist 或光标。
同一 action 冻结全部 unsaved overlays，并验证 active roots 内已加载 C++ buffer 的版本，
防止另一依赖 buffer 在等待期间编辑或编辑后保存造成旧语义结果被接受。目标协议列按编码转换为字节列。
`:UEDefCancel` 只取消 UI side effect，不强杀仍可能留下 warm TU 的冷解析。
尚未执行的旧 action 请求会从 client 队列移除并完成回调；sidecar 同时只接收一个执行中请求，
执行 deadline 从实际发送时计算，不扣除等待前序请求的时间。已有 native 请求仍受硬超时回收保护。
`UEDefExplain` 输出有界、脱敏的原始失败原因、诊断、上下文和阶段耗时。
LSP preparation 和真正发送前都检查同一 action 的有效性；已发送请求保留 request ID，取消/超时只取消
对应请求。action cleanup 支持多项注册与注销，进度清理和请求取消不会互相覆盖。
成功终态在 jump 前验证 identity、location、provider、destination role 与 metrics 来源，所有成功路径
均保留 USR；header 还携带实际 compiler session。没有测得的阶段耗时不伪造为测量值。

协议 evidence 与 action outcome 不同：`query/resolved` 表示 canonical USR 加 declaration/definition
证据；`lookup-definition/resolved` 必须是 canonical USR 加 definition。单独的 identity 响应不表示
编辑器已跳转。新 lineage 在 jump 成功后才提交；失败保留原 context。每个进度句柄拥有独立的
原生非聚焦 float、buffer 和 8 秒到期计时器，clear/finish 只清理这些资源，不扫描其他窗口。
终态继续使用 `vim.notify`。过期 action 不覆盖最新 Explain；resolver 不再重复显示终态或持有进度 UI。

## 5. Reuse 与失效边界

允许复用的是 live `CXTranslationUnit`，以及已经证明唯一的 canonical-USR destination。
TU key 至少绑定：

```text
origin_tu + active_build_key + exact compile fingerprint + toolchain identity
```

unsaved overlay 按 `path + contents` 判断是否需要 reparse；document version 只参与
stale 门禁，内容相同不会浪费一次 reparse。project/platform/configuration/target、CDB
或构建 fingerprint 变化会清理窗口 context 并 evict sidecar TU。工具链变化则重启进程，
不能仅清 TU 后继续使用已经加载的旧 libclang。`UEDefReload` 在清除模块缓存前先 dispose 旧 client，
取消旧 action、清理进度和 context 并停止旧 sidecar；旧实例的延迟启动回调受 lifecycle generation 守卫。

EnvironmentSnapshot 中 `compiler_files` 保存 clangd/libclang 的 realpath、size、mtime（秒和纳秒），
只用于宿主判断是否重新启动，不能冒充语义身份。CompilerSession 绑定进程代际、请求 descriptor 与
handshake 返回的实际工具路径、Clang version、toolchain identity；路径不匹配或启动期间文件签名变化
会拒绝 ready。普通响应附带处理它的 compiler session。文件签名不读取整个二进制内容，故无法检测
刻意保留同 size/mtime 的原地替换。
native compilation database 句柄也绑定数据库文件签名，并在全量 evict 时释放，覆盖协议允许的未嵌入
compile descriptor 路径。NDJSON 对完整帧和分块帧统一执行 1 MiB 限制；真实 stdin 分块读取并背压，
超限后丢弃到下一行边界再恢复。host 超大出站请求直接返回 `request-too-large`，不占满执行 deadline。

resolved destination cache 绑定 canonical USR、决定模块选择的 subject、所有候选 controlled CDB 的文件签名、
overlay 内容 hash 与 toolchain identity，所以同一实体从 call 跳到 declaration 后可直接复用。
`definition-not-found` 与 `multiple-definitions` 不缓存，避免一个 module 的负证据压住另一个
subject 的真实定义；裸 symbol、receiver、arity 与格式化 signature 永远不是 cache key。
destination cache 有独立 LRU，默认上限 128 项（`UE_SEMANTICD_MAX_LOOKUP_ENTRIES` 可配置），
命中更新顺序、无效签名条目清除；TU 数量上限不能替代该缓存上限。

sidecar 记录 cold parse、reparse、warm cursor query、TU 数量和进程 RSS。实机表明单个
UE Android TU 可达到数 GB working set，因此默认 LRU 容量为 1（可显式配置），并在 30 秒
无请求后 evict；不得为每次按键 spawn `clang-check/clang-query`，也不得在 UI
主循环 parse/reparse。

## 6. 非 C++ compatibility boundary

旧 `cache -> LSP -> csearch -> GTAGS` 链只保留给非 C++ 兼容路径；`.usf/.py/.Build.cs`
等无 clangd 文件仍可直接走 GTAGS。`gr` references 和显式 csearch / GTAGS 命令不受
C++ `gd` authority invariant 影响。

`jumper.lua` 仍统一执行跳转并维护 Vim 原生 jumplist 后置条件：一个 `<C-O>` 回源、
恰好一条源位置记录、无幽灵位置。

## 7. 验证入口

最终验收设置 `NVIM_TEST_REQUIRE_NATIVE=1`，缺失真实工具时不能以 SKIP 代替通过。
`cpp_semantic_pipeline` 补充 header 的完整真实链路与持久反馈验证。

反馈由 `semantic_report.OBSERVATIONS` 声明稳定修复 revision，在启动和记录路径开启有期限的观察。
同 revision 休眠后不自动续期；读取报告、处置失败与确认复发分开记录。成功/失败计数与固定耗时桶
支持观察质量变化，但不能把“已开启观察”表述为现场验证完成。持久化 owner 与生命周期 owner 分离，
详见 `probe-feedback-loop` spec。

- `nvim --headless -l tests/run.lua cpp_semantic_context`
- `nvim --headless -l tests/run.lua cpp_semantic_client`
- `nvim --headless -l tests/run.lua cpp_semantic_sidecar`
- `nvim --headless -l tests/run.lua ue_goto_behavior`
- `nvim --headless -l tests/run.lua index_generation`
- `nvim --headless -l tests/run.lua clangd_commands`
- `nvim --headless -l tests/run.lua cpp_semantic_index`
- `nvim --headless -l scripts/ue_cpp_semantic_sidecar_smoke.lua`（输入只走环境变量，
  输出为脱敏 label / USR hash / basename+line / timing / TU count / RSS）

fixture 覆盖无参、同 arity 不同类型、默认参数、cv/ref、模板/特化、ADL、继承、
derived/base virtual receiver、constructor/destructor、type/alias、field/variable、enum member、
namespace alias、macro、operator、multi-context、invalid context 和 unsaved overlay。实机 smoke
只读消费 active UE build artifacts，不修改引擎或项目文件。当前 Android Vulkan 4-wrapper
实测：三个不同 canonical USR 的首次 module lookup 各约 29–31 秒；相同 USR 从另一个调用点
或 declaration 再查为 0ms；`tu_count=1` 时 sidecar RSS 为 1797–1818 MiB。默认
`max_tus=1` 保持内存有界，不用并发 TU 换取冷路径速度。
