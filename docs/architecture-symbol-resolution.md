# Symbol Resolution Architecture — C++ 语义权威与非 C++ 兼容链

> 最后更新：2026-08-05
> 权威代码：`lua/utils/lsp_fallback.lua`、`lua/utils/ue_goto/semantic_*.lua`、
> `scripts/ue_clang_semanticd.lua`

## 1. Authority invariant

C/C++ `gd` 只接受当前 active build 中由 Clang 证明的实体身份。唯一合法主键是
canonical USR（或等价的 compiler-owned identity）；函数名、receiver 文本、arity、
渲染后的 signature、候选顺序、文件距离和最近访问记录都不是身份。

因此 C++ `gd` 不读取或写入 definition-location cache，不调用 workspace symbol、
csearch 或 GTAGS 自动猜目标，也不让 Tree-sitter 决定或否决语义结果。显式搜索、
references 和非 C++ 文件仍可使用 csearch / GTAGS；这是另一条能力边界。

## 2. 两条 C++ 路径

### 2.1 Active CDB 覆盖的 source TU

`.c/.cc/.cpp/.cxx/.m/.mm` 先由 sidecar 的 `prove` 操作确认文件同时存在于当前
active shard 与 clangd 消费的 merged `compile_commands.json`。active shard 只证明
当前构建成员身份；merged CDB 必须不早于 active shard / selection manifest，并以其
post-processed file/directory/argv 作为 clangd 与 sidecar 的真实命令，再在精确光标
位置向已附着 clangd 请求：

1. `textDocument/symbolInfo`，要求唯一且非空的 USR；
2. 一次 `textDocument/definition`，只做位置正规化和去重；
3. 只有一个 location 时跳转，零个或多个都诚实失败。

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

## 3. Semantic sidecar

主 Neovim 只负责异步进程 I/O、请求快照、context 选择和跳转副作用。独立 headless
Neovim 通过 LuaJIT FFI 加载与 clangd 同目录的 `libclang.dll`，通过 versioned NDJSON
协议处理 `handshake/catalog/prove/query/stats/evict/shutdown`。

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

`clang_getCursorDefinition` 的可见域是当前 origin TU 的 AST。若头文件 declaration
对应的 out-of-line body 位于另一 source TU，sidecar 仍返回该 declaration 的 canonical
USR，但 `definition` 合法为空。此时跨 TU 补全只允许走 clangd project index：先在头文件
精确光标请求 `textDocument/symbolInfo`，要求 USR 与 sidecar 完全相等，再请求一次
`textDocument/definition`；definition 只发给实际返回该 USR 的 clangd client，过滤原
declaration 与当前位置后只剩唯一 location 才跳转。
USR 不一致、零个或多个 location 都不按名称或响应顺序猜选。若当前光标不在 declaration
本身，仍可安全退到 sidecar 已证明为同一 USR 的 declaration；已经位于该 declaration 时
则保持当前位置并报告跨 TU definition 不可用。

## 4. Terminal states 与 UI 副作用

每个 C++ 请求只能结束为：

| 状态 | 含义 | 是否跳转 |
|---|---|---|
| `resolved` | 唯一 canonical identity 与合法 declaration/definition | 是 |
| `ambiguous-context` | 多个 proven context 产生不同真实结果 | 否；先选 context |
| `invalid-semantic-context` | TU 可建，但当前位置是 invalid/recovery/dependent 结果 | 否 |
| `unavailable` | 工具、CDB、proven context 或协议不可用 | 否 |

每次 `gd` 带 monotonic action token、window/buffer/cursor/changedtick 和 document
version 快照。响应到达时任一项变化即 stale；stale 响应不得改窗口、jumplist 或光标。
`:UEDefCancel` 只取消 UI side effect，不强杀仍可能留下 warm TU 的冷解析。

## 5. Reuse 与失效边界

允许复用的是 live `CXTranslationUnit`，不是 definition location。TU key 至少绑定：

```text
origin_tu + active_build_key + exact compile fingerprint + toolchain identity
```

unsaved overlay 按 `path + contents` 判断是否需要 reparse；document version 只参与
stale 门禁，内容相同不会浪费一次 reparse。project/platform/configuration/target、CDB
或 toolchain fingerprint 变化会清理窗口 context 并 evict sidecar TU。

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

- `nvim --headless -l tests/run.lua cpp_semantic_context`
- `nvim --headless -l tests/run.lua cpp_semantic_client`
- `nvim --headless -l tests/run.lua cpp_semantic_sidecar`
- `nvim --headless -l tests/run.lua ue_goto_behavior`
- `nvim --headless -u NONE -l scripts/ue_cpp_semantic_smoke.lua`（输入只走环境变量，
  输出为脱敏 label / USR hash / basename+line / timing / RSS）

fixture 覆盖无参、同 arity 不同类型、默认参数、cv/ref、模板、ADL、继承、宏上下文、
multi-context、invalid context 和 unsaved overlay。实机 smoke 只读消费 active UE build
artifacts，不修改引擎或项目文件。
