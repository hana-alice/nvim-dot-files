# Symbol Resolution Architecture — 旁路语法/索引栈全景

> 仓库: hana-alice/nvim-dot-files
> 适用版本: main @ 636ac8b 之后
> 最后更新: 2026-05-09
> 关联代码: `lua/utils/lsp_fallback.lua` / `lua/utils/ue_goto/` / `tools/`
> 关联 commit: `055f1c9` (chain 折叠) / `252e9e0` (cursor 漂修复) / `636ac8b` (TS dead-zone bail)

---

## 0. 一句话概括

按 `gd` 后能在 100ms 内出结果, 靠的不是单个工具, 而是**5 个职责互补的解析层**
按"省调用 → 命中精度 → 兜底覆盖"的优先级串成一条 fallback 链, 加一层 cache 把
70%+ 的请求拦在最便宜的位置. 每一层只做它最擅长的事, 永远不试图替代别人.

---

## 1. 全栈架构图

```
                         ┌────────────────────────────┐
                         │   你按 gd / 搜索 / 跳转    │
                         └─────────────┬──────────────┘
                                       │
                  ┌────────────────────▼────────────────────┐
                  │         lua/utils/lsp_fallback          │
                  │     router: "哪个工具回答这问题?"      │
                  └─┬────────────┬──────────────┬───────────┘
                    │            │              │
       ┌────────────▼──┐   ┌─────▼──────┐   ┌──▼─────────────┐
       │  treesitter   │   │   cache    │   │    jumper      │
       │   (语法分流)  │   │  (热路径)  │   │ (落点+反漂守护)│
       └────────────┬──┘   └─────┬──────┘   └────────────────┘
                    │ MISS       │ MISS
                    ▼            ▼
            ┌─────────────────────────────────────┐
            │   Layer 1: clangd (LSP)             │  权威, 慢, 偶尔 stale
            │   ── precise: 200-500ms              │
            │   ── timeout: 30s                    │
            └─────────────────┬───────────────────┘
                              │ MISS / 不可用 (.usf .py .Build.cs)
                              ▼
            ┌─────────────────────────────────────┐
            │   Layer 2: csearch                  │  trigram 倒排, 毫秒级
            │   (Google codesearch)               │  正则文本, 需 cindex 维护
            └─────────────────┬───────────────────┘
                              │ MISS / 噪音多
                              ▼
            ┌─────────────────────────────────────┐
            │   Layer 3: GNU global (gtags)       │  ctags-based, 扫定义点
            │   (gtags + global)                  │  非 cpp 文件主力
            └─────────────────────────────────────┘

  并行: clangd-indexer (background, 离线)
        → 写 .idx → 给 clangd LSP 读 (workspace symbols / call hierarchy)
```

---

## 2. 各层职责详解

### 2.1 clangd (LSP) — 唯一懂 C++ 语义的家伙

**它做什么**

吃 `compile_commands.json` (CDB) 的每条编译命令, 自己跑一遍 preamble:

- 跑 preprocessor (展开所有 macro)
- 解析所有 `#include` (sometimes 几百个 .h)
- 模板实例化
- name lookup (ADL / using / hidden friend)

建立**完整的 C++ 语义模型**.

**它能回答的问题** (其他人答不了)

- `Foo::Bar()` 在子类 / 重载 / 模板特化里的精确定义点
- ADL / using-declaration 引入的符号
- macro 展开后真实展开成什么 (`DECLARE_GLOBAL_SHADER` 展开成几十行那种)
- "这个 `T::value`, T 是什么实际类型, value 又是哪个"
- semantic highlighting / diagnostics / rename / call hierarchy / type hierarchy

**代价**

| 项目 | 数字 |
|---|---|
| 首次 attach (UE cpp, cold) | 几秒到几十秒 (preamble) |
| `textDocument/definition` (cold) | 200-500ms |
| `textDocument/definition` (warm) | 50-150ms |
| 30s 硬 timeout | 我们的 ceiling, clangd 自己可能更长 |
| 无 CDB 条目 | 完全瞎 (.usf shader / .Build.cs / 生成代码 / 孤立 .h) |

**stale 风险**: preamble 是按文件 hash 缓存的. 改了上游 .h 没触发重 parse → 给错答案.

**关联 skill**:
- `clangd-pch-precompile` (umbrella)
- `clangd-restart-after-index-rebuild`
- `clangd-fatal-cascade-diag-triage`
- `ue-cdb-pch-fi-postinject`
- `clangd-stale-uht-generated-h`

### 2.2 clangd-indexer — clangd 的"离线大脑"

**它做什么**

单独的 binary (`clangd-indexer.exe`), 不是 LSP, 是个**批处理工具**.
吃 CDB, 跑过所有 TU, 把"每个符号定义在哪、引用在哪"写成 `.idx` 文件.

**为什么需要它**

clangd LSP 启动时需要 workspace 视图的查询 (ws/symbol, call hierarchy,
跨文件 references), 如果 LSP 每次现 parse 整个仓库会爆炸. indexer 离线
搞定这层, LSP 只读 `.idx`.

**关键产出 (UE 仓 benchmark, 2026-05)**

| 指标 | baseline | 我们的 pipeline |
|---|---|---|
| cpp 文件数 | 14334 | (合并成) 13 super-TU |
| 索引耗时 | ~165 min | **50 s** (~200x) |
| `.idx` 大小 | — | 244 MB |
| pipeline | naive 一对一 TU | inject .h + super-unity + slim PCH |

**它的限制**

- 对模板 / dependent name 跟 LSP 一样无能 (都是 clang frontend, 同一套)
- 不会自动增量, 改了文件要重跑 (super-unity pipeline 解决了这个)
- 跟 LSP **不共享内存**, 只通过 `.idx` 文件协议
- 22.1 trunk 限制: `--filter` 子集机制有些 corner case

**关联 skill / sessions**:
- `clangd-indexer-ue-defs-injection`
- `super-unity-cdb-pipeline`
- `ue-fork-force-unity-cdb-via-cli` (本地 skill — 描述 UE fork 强制 unity 编译生成 CDB 的命令行流程)
- `ue-cdb-response-file-expansion`
- `clangd-h-cdb-entry-inject`
- sessions: `ue-clangd-indexing.md`

### 2.3 tree-sitter — 零成本的语法分流器

**它做什么**

纯**语法** (syntax) 解析, 不做 name lookup, 不做 semantic analysis,
**不看 #include**. 每个文件在 buffer 里实时增量 parse, parse 一次后
cache 在 buffer 上, 任何位置查询节点 < 5ms.

**它能回答的问题**

- "光标这个 token 是什么?" → identifier / comment / string / preproc_arg
- "光标在的祖先链是什么?" → `field_expression` < `template_method` < `function_definition`
- "这是 `obj.method()` 的 `obj` 还是 `method`?" (用 named field 取 `argument` vs `field`)
- "光标在的标识符是不是某个 class/struct/function 的**定义 site 名字**?"
- "这是不是 template parameter `T` 的传入?" (看祖先 template_declaration 的参数列表)

**它**不能**做的事**

- "这个 `Foo` 是哪个 namespace 的" (不解析 #include 就无法知道)
- "Bar() 重载了几个, 这次匹配哪个" (没有 type info)
- "这个 macro 展开成什么" (它不展开 macro, 只解析为 `preproc_call` 节点)

**在我们这套里 tree-sitter 担四个角色** (全是"LSP 一定答不了的"语法判定 +
receiver 提取):

| 检测器 | 文件 | 作用 |
|---|---|---|
| `is_at_definition_at_cursor` | symbol.lua | 光标已在定义 → toast no-op, 不发 LSP |
| `is_dependent_at_cursor` | symbol.lua | 模板 dependent name → LSP 也没答案, 解释原因 |
| `is_in_unresolvable_context_at_cursor` | symbol.lua | 注释/字符串/字面量 → 立即 bail (~22.6% 命中率) |
| `current_receiver` | symbol.lua | 给 cache key 提供"接收者"消歧 (FAndroid::CreateProc vs FWindows::CreateProc) |

**关键设计**: TS 永远在 LSP 之前, 做"可以省掉 LSP 请求"的判定;
**永远不试图替代 LSP 给精确定义** (那是死路, 见 racing-goto-definition 系列 skill).

**关联 skill**:
- `treesitter-pre-lsp-early-bail` (.archive/2026-04-29)
- `clangd-at-definition-bail`
- `racing-goto-definition` (反例)

### 2.4 csearch (Google codesearch) — 暴力但极快的文本搜索

**它做什么**

纯文本/正则的 grep, 但比 ripgrep 快 10-100x. 靠**trigram 倒排索引**:

- 把仓库里所有文件预处理成"哪三字节序列出现在哪些文件"的反查表
- 搜 `FRasterizer` 时, 先查 `FRa` `Ras` `ast` ... 哪些文件**全部包含**
- 再只在那些文件里跑正则

UE 仓 200GB, csearch 索引 ~3GB, 搜任何字符串 < 200ms.

**它能回答的问题**

- "这个字符串在仓里哪些位置出现" (包括注释、字符串、未编译的 .usf shader、Build.cs、Python、生成代码)
- 任何**正则** (grep -E)
- 跨语言 / 跨编译边界 (LSP 看不见的 .usf .py 也能搜)

**它不能**做的事

- 区分定义 vs 引用 (都是文本 match)
- 处理重载 / namespace
- 知道你搜的 `Foo` 是哪个 `Foo`

**在 lsp_fallback 里的角色**

LSP MISS (.usf 没 LSP / .h 不在 CDB / 跨翻译单元找不到) 时上场.
把 sym 当字面量搜, 过滤"看起来像定义"的行 (开头是
`class|struct|void|FORCEINLINE|template`...).

**dirty workspace 限制**

csearch 索引是离线 build 的, 你刚改的代码不在索引里.
解决: skill `csearch-rg-on-dirty-hybrid` (csearch 拿基线 + ripgrep 补 dirty 文件).

**关联 skill**:
- `csearch-snacks-live-finder-integration`
- `csearch-rg-on-dirty-hybrid`
- `codesearch-cindex-incremental-merge-traps`
- `incremental-multi-index-fs-watcher`
- `rg-windows-ntfs-large-cpp-workspace`
- `zoekt-on-windows-dead-end` (反例: 别考虑迁移)

### 2.5 GNU global (gtags) — 古典 ctags 的现代继承者

**它做什么**

跑一遍 `gtags` (底层调 universal-ctags), 扫描所有源文件, 找**定义点**
(class/struct/function/typedef declaration sites), 写成 `GTAGS / GRTAGS / GPATH`
三个 sqlite-like 文件. 然后 `global -d Foo` 毫秒级返回所有 `Foo` 的定义位置.

**它跟 csearch 区别**

| 维度 | csearch | gtags |
|---|---|---|
| 索引内容 | 任何字符串的位置 | 仅定义 (declaration sites) |
| 区分 def vs ref | 不区分 | 区分 |
| 区分原理 | — | 正则规则 (ctags langmap) |
| 噪声 | 高 (全文 match) | 低 (只返回像定义的行) |
| 增量 build | 慢 | 快 |

**为什么仍然有用**

- **非 cpp 文件** (`.usf` shader / `.Build.cs` / `.py`) clangd 完全不管, 但 gtags 用 ctags langmap 能扫
- 比 csearch 信号噪声比高
- 增量 build 比 clangd-indexer 快得多

**在 lsp_fallback 里的角色**

`non-clangd ext` 分支: `.usf / .py / .Build.cs` **直接走 gtags**, 跳过 clangd 和 csearch.
对这些文件 gtags 是唯一靠谱的.

**关联 skill**:
- `gnu-global-hlsl-via-exuberant-ctags-langmap`

### 2.6 cache (lua/utils/ue_goto/cache.lua) — 会话内热路径

**它做什么**

所有上面拿到的"好答案" (`sym, receiver, location`) 都缓存在 lua table 里.
下次同一个 gd 直接 hit, **0 ms 不动任何工具**.

**key 设计**

```
primary_key   = "<receiver>::<symbol>"   -- e.g. "FWindows::CreateProc"
secondary_key = "<symbol>"               -- e.g. "CreateProc"
```

跨平台同名函数 (FAndroid::CreateProc / FWindows::CreateProc) 用 receiver 区分.
同一份源码两个平台都有定义, 但用户站在 windows / android 不同的 buffer 里
按 gd, 应该跳到对应平台的实现.

**失效时机**

- buffer 改动
- lsp_fallback chain 重新 resolve 出新答案时覆盖

**实战命中分布** (本人会话感知, 非精确数字)

| 层 | 命中比例 |
|---|---|
| cache | ~70% |
| clangd LSP | ~25% |
| csearch | ~4% |
| gtags | ~1% |

**cache 是体感最重要的层**, 但它要靠下面三层填充.

### 2.7 jumper (lua/utils/ue_goto/jumper.lua) — 跳转执行 + cursor 守护

**它做什么**

拿到 location, 执行 `nvim_buf_call + nvim_win_set_cursor`. 但这步在
我们的环境里有**漂移问题**: snacks.scroll smooth-scroll 动画 / PreserveBufferView
autocmd 在跳完后异步改 cursor.

所以 jumper 内部还有 `_on_reassert` 钩子: 跳完 ~10ms 后再 verify cursor 还在不在
目标, 如果被 race 改走了就 reassert.

**关联**:
- commit `252e9e0` (砍 snacks.scroll + PreserveBufferView, 双修)
- sessions: `nvim-jump-drift.md`
- skill: `nvim-cross-buffer-jump-drift-autopsy`

---

## 3. 一次完整的 gd 走的路径

以按 gd 在 `.cpp:58` 的 `DECLARE_GLOBAL_SHADER` 上为例:

```
[1] gd 触发
    └─ vim keymap → ue.lua → lsp_fallback.M.definition()
                                    │
[2] 三层早期 bail (TS, 总耗时 <5ms)
    ├─ is_at_definition_at_cursor  → false
    ├─ is_dependent_at_cursor      → false
    └─ is_in_unresolvable_context  → false (是真符号)
                                    │
[3] cache 查询 (lua table lookup, <1ms)
    ├─ key = "DECLARE_GLOBAL_SHADER" (no receiver)
    ├─ HIT → 拿 location, 直接 jumper.jump → 完
    └─ MISS → 继续
                                    │
[4] 文件类型分流
    ├─ .usf / .py / .Build.cs → 直接 GTAGS (不走 clangd)
    └─ .cpp / .h → clangd LSP
                                    │
[5] clangd textDocument/definition (200-500ms)
    ├─ 命中 → 写 cache + jumper.jump
    └─ 空 → 继续 csearch fallback
                                    │
[6] csearch (~50-200ms)
    ├─ 把 sym 当正则搜全仓
    ├─ 过滤"像定义的行" (class/struct/template/...)
    ├─ 命中 → quickfix 列表 / 直跳第一个
    └─ 空 → 继续
                                    │
[7] gtags (~10-50ms)
    └─ global -d sym → 命中即跳 / 否则 "no def" 兜底
                                    │
[8] jumper 执行 + 100ms 后 reassert
```

**spinner 策略**: clangd request 600ms 后才显示进度提示,
快路径 (cache HIT, 早期 bail) 永远不闪 spinner.

---

## 4. 为什么需要这么多层 — 能力矩阵

每一层补另一层的盲区. 删掉任何一层都会打开一类盲区:

|              | clangd | clangd-indexer | tree-sitter | csearch | gtags |
|--------------|--------|----------------|-------------|---------|-------|
| 模板/重载精确定义 | ✓ | ✓ | ✗ | ✗ | ✗ |
| macro 展开后符号 | ✓ | ✓ | ✗ | ✗ | ✗ |
| 注释/字符串短路 | (会答错) | — | ✓ | ✗ | ✗ |
| .usf / .py / .Build.cs | ✗ | ✗ | (有 langmap 才行) | ✓ | ✓ |
| 跨翻译单元 references | (慢) | ✓ | ✗ | ✓ | ✓ |
| 任意字符串/注释搜索 | ✗ | ✗ | ✗ | ✓ | ✗ |
| 即时反馈 (<10ms) | ✗ | (离线) | ✓ | ✓ | ✓ |
| 用户刚改的脏代码 | ✓(buffer 内) | ✗ | ✓ | ✗ | ✗ |
| Workspace symbol | ✓ (要 indexer) | ✓ | ✗ | (能搜, 噪音) | ✓ |
| 启动时延 | 几秒-几十秒 | 50s 全量 | <100ms | 即时 | 即时 |
| 索引磁盘成本 | (preamble cache) | 244 MB | 0 | ~3 GB | ~500 MB |

---

## 5. 设计哲学 (这套实际遵循的)

1. **TS 永远做"省调用"判定, 不做"给答案"**
   它没语义. 一旦想用 TS 给精确 definition, 就走进 racing-goto-definition 的死路.

2. **clangd 永远是权威源, 但永远不在前台 block 用户**
   spinner 600ms 后才显示, 30s 硬超时. 快路径跳过它.

3. **csearch / gtags 是 fallback 不是替代**
   只在 clangd MISS / 无 LSP 时上. 别用它们做主路.

4. **cache 是体感的实际承载者**
   一切优化的目标是"让 cache 命中率高 + cache HIT 路径无副作用".
   cache HIT 路径 = lua table lookup + jumper.jump, 不动任何子进程.

5. **每个工具的索引都是离线的**
   clangd-indexer / csearch / gtags 都靠后台 / 手动 rebuild,
   不让用户体感等待. 用户感觉等待 = 我们的 bug.

6. **每一层失败都不能崩, 必须 fall through**
   任何一层 timeout / exception / 空结果都进入下一层, 最后兜底 toast "no def".
   绝不让用户看到 "lua error in lsp_fallback" 这种东西.

---

## 6. 不要走的反例路径

这些都试过, 有 commit / skill 留档, 别再走:

- ❌ **TS 给 goto-definition 答案** —— 跨翻译单元 / 模板 / macro 都看不见.
  见 .archive `racing-goto-definition`.
- ❌ **csearch 当主路** —— 噪音太大, 重载/同名挑不出来. 只能兜底.
- ❌ **gtags 当主路** —— ctags 不懂模板, UE 大量代码会漏 / 错.
- ❌ **clangd LSP 同步阻塞 UI 等结果** —— 200-500ms 用户能感觉.
  必须 async + cache + 快路径.
- ❌ **zoekt 替代 csearch** —— Windows 不可用. 见 skill `zoekt-on-windows-dead-end`.
- ❌ **PreserveBufferView 类的 BufEnter winrestview** —— Vim 原生 cursor 行为足够.
  workaround 反噬模式. 见 commit `252e9e0`.

---

## 7. 关键 commits 时间线

| commit | 内容 |
|---|---|
| `055f1c9` | lsp_fallback chain 折叠成 cache → precise → csearch → gtags 单链, 砍 path-A LSP 覆盖 path-B 的脏路径 |
| `252e9e0` | 跨 buffer jump cursor 漂修复 (snacks.scroll + PreserveBufferView 双砍) |
| `636ac8b` | TS dead-zone early-bail (注释/字符串/字面量), 省 ~22.6% 无效 LSP 请求 |

---

## 8. 进一步阅读

代码:
- `lua/utils/lsp_fallback.lua` — router
- `lua/utils/ue_goto/symbol.lua` — TS 检测器集合 + receiver 提取
- `lua/utils/ue_goto/cache.lua` — cache 实现
- `lua/utils/ue_goto/jumper.lua` — 跳转 + 反漂守护
- `lua/utils/ue_goto/provider.lua` — LSP / csearch / gtags 三个 provider
- `tools/inject_definitions_to_cdb.py` — clangd-indexer 加速 pipeline 之一
- `tools/build_unity_cdb.py` — super-unity pipeline 入口

文档:
- `docs/release_1.0.0.md` — 全仓概览
- `docs/ue_lazyvim_cheatsheet.md` — keymap 总表
- `docs/plans/2026-04-17-instant-goto-architecture.md` — instant-goto 早期设计 (历史)

外部 sessions (Hermes memories):
- `sessions/ue-clangd-indexing.md` — clangd indexer pipeline 全细节
- `sessions/nvim-jump-drift.md` — cursor 漂双因诊断 + autopsy harness
- `sessions/clangd-h-inject.md` — .h CDB inject 调研
