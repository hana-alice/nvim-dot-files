# 2026-05-08 — .h CDB Inject for clangd LSP

> Status:    ✅ shipped (PoC v6, 2026-05-08)
> Scope:     clangd LSP per-file diag on Unreal Engine headers
> Owner:     hana-alice
> Related:   docs/skills/ue-ide-bootstrap.md (consumer of this work)
>            docs/plans/README.md (overall plan log)

---

## 1. Problem

打开一个孤立的 UE header（业务轻量 .h、umbrella header、`.inl` 模板实现等）时，
clangd LSP 的 header inference fallback 无法复制代理 `.cpp` 的完整 include
闭包，结果：

- 业务符号找不到 → 一片红错
- 模板深度展开报 `unknown type name 'template'`
- `.inl` 文件 baseline 3 ERROR 起步

代表案例：
- `Renderer/Private/PrivateRender/RenderShading.h` baseline 6 ERROR
  (`FGlobalShader` / `DECLARE_GLOBAL_SHADER` / 业务 proxy 类全找不到)
- `Renderer/Public/MeshPassProcessor.h` baseline 22 ERROR
- `Renderer/Public/PrimitiveSceneInfo.h` baseline 22 ERROR

约束（用户红线）：
- **不动源码**
- **不全局 `-include`**
- **离线生成**，不靠 LSP 实时启发

---

## 2. Decision

**方案 D' — `.cpp.json` 反查表 + wrapper 双路径 donor**。
零启发式，全部由 UnrealBuildTool 编译时落盘的 `.cpp.json` 闭包数据驱动。

```
数据源:
  Engine/Intermediate/Build/Win64/<Editor>/Development/<Module>/<File>.cpp.json
  含 Source / PCH / Includes 字段, UBT 自动写, 编译时存在闭包

算法:
  for each .h in 源码树:
    candidates = 所有 .cpp.json 中 Includes 列表包含此 .h 的 TU
    if not candidates:
      skip (这个 .h 在本次 target 里没被任何人 include)
    pick first candidate with PCH

    路径 A (cdb-donor):  donor .cpp 在 raw CDB 中存在
      → clone donor entry, 把 file 字段换成 .h
      → 补 /FI=PCH.<Module>.h (raw CDB 主动剥了 /Yu /Fp /FI=SharedPCH,
        但 .h 解析时需要补回, 否则 unknown type name 'template')

    路径 B (wrapper-donor):  donor .cpp 不在 raw CDB (是 unity wrapper 的一员)
      → 读 wrapper 的 .cpp.obj.response
      → 剥 /Yu /Fp /Fo /Tp (避免触发真编译)
      → 保留 /FI /D /I /imsvc (preamble 必需)
      → 包成新 entry
```

效果：34/34 .h 0 ERROR (含业务轻量 / 自治 umbrella / pair / `.inl` / nested 五种类型)。

---

## 3. Design Walkthrough

### 3.1 为什么是 `.cpp.json` 而不是文件名启发式

UBT 在编译每个 TU 时会落盘 `<Module>/<File>.cpp.json`，结构：

```json
{
  "Source": "...\\Renderer\\Private\\Foo.cpp",
  "PCH":    "...\\Engine\\PCH.Engine.h.pch",
  "Includes": [ "...\\Foo.h", "...\\Bar.h", ... ]
}
```

这是**编译期真相**：编译器实际打开了哪些 header。任何"按文件名/路径猜 donor"
的算法都是猜测，会产生例外名单 → 永无止境的补丁。

仓内统计（measured on UE 4.27 Editor target）：

```
.cpp.json 文件数:           ~992
含 PCH 字段的:              ~989 (99.7%)
被任一 TU include 的 .h:    ~27201
有 PCH-bearing donor 的 .h: ~26637 (98%)
源码树 .h 总数:             ~76734 (其余是别的 target 的 module)
最终 inject .h entries:     ~15286 (cdb-donor 2017 + wrapper-donor 13269)
                            (差额来自 .hpp/.inl 之外的非 header 过滤)
```

### 3.2 双路径的必要性

raw CDB 是 UBT 用 `GenerateClangDatabase` 模式生成的，**主动剥掉了
`/Yu /Fp /FI=SharedPCH`** —— 因为 clangd 只做语义分析不真编译，PCH 引用对它
反而会触发"找不到 .pch 文件"。

- 路径 A 命中时，必须**手动补回** `/FI=PCH.<Module>.h`，否则 .h 内的模板深度展开
  会拿不到 PCH 里预定义的宏 / 类型 → `unknown type name 'template'`。
- 路径 B 直接从 wrapper 的 `.obj.response` 拿原始 cl.exe 命令行，但要剥掉
  会触发真编译的开关（`/Yu` 用 PCH、`/Fp` 写 PCH、`/Fo` 写 obj、`/Tp` 强制 C++ 模式）。

### 3.3 与既有索引轨道的关系

```
            ┌──────────────────────────────────────────┐
            │       UnrealBuildTool (UBT)              │
            └────┬───────────────┬─────────────────────┘
                 │               │
                 │ .cpp.json     │ .cpp.obj.response
                 │ (闭包真相)    │ (原始 args)
                 ▼               ▼
          ┌────────────────────────────┐
          │   inject_h_entries.py      │  ← 本设计
          │   (cdb-donor + wrapper)    │
          └─────────┬──────────────────┘
                    │
                    ▼
   compile_commands.json (29620 entries, 551 MB)
                    │
                    ├──► clangd LSP (per-file 解析, 直接吃)
                    └──► clangd-indexer 走另一条 super-unity CDB,
                         不读这份 (由 docs/plans/2026-05-07-cdb-pipeline-split.md
                         拆分保证)
```

---

## 4. Failed Approaches (反面例子, 必须留档)

按尝试顺序：

| # | 思路 | 结果 | 教训 |
|---|---|---|---|
| v1 | 拼 SharedPCH `/FI` 加到 .h 自身 args | ❌ preamble 损坏, 3 ERROR 反增 | proxy 自身预定义宏 vs SharedPCH 冲突 |
| v2 | 继承同名 `.cpp` 全套 args | ✅ pair 文件类 .h 有效 / ❌ 启发式不通用 | 只对 pair 文件 (.h ↔ .cpp) 有效 |
| v3 | 同 module 任一 `.cpp` 当 donor | ❌ umbrella header 1→3 ERROR | PCH 与 .h 自身 include 顺序冲突 |
| v4 | 同名/同 module 启发式 + 文件类型黑白名单 | ❌ 用户判反面: 永无止境补丁 | 任何"按路径猜"必死, 只能让 build system 告诉你 |
| v5 | `.cpp.json` 反查表, 仅 cdb-donor | ✅ 9/9 跨 module 全 0 ERROR / ⚠ 覆盖率不够 | 大半 .h 的 donor 是 wrapper TU, 不在 raw CDB |
| v5b | + wrapper-donor 兜底 (`.obj.response` 解析) | ✅ 跨 6 module 全 0 ERROR | wrapper response 必须剥 `/Yu /Fp /Fo /Tp` |
| v5c | 9 个混合样本 (cdb / wrapper / `.inl` / nested) 回归 | ✅ 全 clean | 验证 `.inl` 也吃这套 |
| **v6** | **全量推 15286 .h** | ✅ 34/34 (12 直接 + 22 间接 buffer) | 第一次推完后 MeshPassProcessor.h 22 ERROR → 修 cdb-donor 路径忘补 PCH |

---

## 5. Pitfalls / 实施踩坑详录

按踩到的顺序，不按重要性。

### 5.1 raw CDB 主动剥 /Yu /Fp /FI=SharedPCH

**症状**：cdb-donor 路径下，第一次全量推完 MeshPassProcessor.h / PrimitiveSceneInfo.h
出现 22 ERROR `In included file: unknown type name 'template'`。

**根因**：UBT 生成 raw CDB 时会主动 strip 掉 PCH 相关 flag —— 因为 clangd 不真编译，
保留 `/Yu` 反而触发 "cannot find precompiled header"。但对**孤立打开的 .h**
来说，PCH 里的预定义类型/宏（`UE_BUILD_DEVELOPMENT`、`WITH_EDITOR`、各种
`*_API` 宏…）是必需的，否则模板深度展开崩盘。

**修复**：cdb-donor 分支额外从 `.cpp.json` 的 `PCH` 字段反推 PCH header 路径
（`SharedPCH.Engine.ShadowErrors.h.pch` → 去掉 `.pch` 后缀），插入到 `args[1]` 位置：

```python
donor_pch = ...  # .cpp.json 的 PCH 字段
pch_header = donor_pch[:-4] if donor_pch.endswith('.pch') else donor_pch
already_have = any(
    'sharedpch' in a.lower() or 'pch.' in a.lower()
    for a in args if a.lower().startswith(('/fi', '-fi', '-include'))
)
if not already_have:
    args.insert(1, f'/FI{pch_header}')
```

### 5.2 wrapper response file 解析陷阱

**症状**：第一次写 wrapper-donor 解析时，args 数量正常，但 `/FI` 项显示
`/FI..\\Intermediate\\...\\Definitions.h /clang:-MD` —— 两个 token 黏成一个。

**根因**：response file 用 `\r\n`+ 引号格式，`/FI"path"` 是单 token。
我的 split 把所有空白都视为分隔符，但忘了考虑双引号内的空白要保留。

**修复**：手写 char-by-char tokenizer，遇 `"` 翻转 `inq` 标志：

```python
def parse_response(rsp):
    txt = open(rsp, encoding='utf-8', errors='ignore').read()
    args, cur, inq = [], [], False
    for ch in txt:
        if ch == '"':
            inq = not inq          # 引号本身不进 cur
        elif ch.isspace() and not inq:
            if cur:
                args.append(''.join(cur)); cur = []
        else:
            cur.append(ch)
    if cur: args.append(''.join(cur))
    return args
```

### 5.3 wrapper response 必须剥的 4 个 flag

```
/Yu<pch>      使用 PCH (会触发找不到 .pch)
/Fp<pch.pch>  写 PCH 输出路径
/Fo<obj>      写 .obj 输出路径 (clangd 不需要)
/Tp           force C++ language mode (clangd 自己根据扩展名判断)
```

漏剥任何一个，clangd 会以为自己要真编译，要么去找不存在的文件，要么走错的
preamble 路径。

保留 `/FI /D /I /imsvc /clang:* /std:* /Z* /D*`。

### 5.4 公开仓 push 红线

**踩点**：第一次写 PoC commit message 时差点把项目代号（公司内部 module 名）写进去推到公开 GitHub。已固化为 skill
`pre-commit-codename-audit-public-remote` —— 推 `hana-alice/*` 仓前必跑：

```bash
git diff --cached | grep -iE '<禁词列表>'
git log -1 --format=%B | grep -iE '<禁词列表>'
git config user.email | grep -v '@<公司域名>'  # 必须是公开邮箱
```

本仓 / 本设计文档已经全程脱敏，使用 `PrivateRender` / `RenderShading` 等占位词。

### 5.5 hermes terminal 吞 `$VAR`

**踩点**：写脚本调试 wrapper response 时，bash heredoc `<< 'PYEOF'` 单引号
也救不了 —— hermes terminal 在交给 bash/pwsh 前会做一遍 shell 变量展开，
Python 通过 stdin 接收时 `$XXX` 已经是空字符串。

**绕法**：脚本里先写占位符 `@@`，Python 内 `replace('@@', chr(36))` 还原成 `$`
再写文件。已在 user profile 备忘。

### 5.6 uv-managed Python 跑 inject 脚本会 crash

**症状**：`AssertionError: SRE module mismatch` —— `_sre.MAGIC` 与 `re/_compiler.py`
里编译的 MAGIC 对不上。

**根因**：uv 管理的 Python 在某些 PYTHON* 环境变量被外部污染时，会让
`_sre`(C 扩展) 与 `re`(Python 模块) 出自不同 Python 版本。

**绕法**：跑 inject 脚本必须 pin 绝对 Python 3.12 路径 + 清空环境：

```bash
PYTHONPATH= PYTHONHOME= /c/Users/.../Python312/python.exe inject_h_entries.py
```

已固化为 skill `nvim-spawn-python-pin-absolute`。

### 5.7 bash sleep > 60s 被 hermes 60s timeout 截断

调试时要等 clangd 跑完 90s diag，foreground bash `sleep 90` 会被截。
必须分两段或走 `terminal background=true notify_on_complete=true`。

### 5.8 ghost clangd-indexer 进程吃 24 核

bench 前必须 `tasklist /fi "imagename eq clangd-indexer.exe"` 清场，
不然之前 `:UEIndexFull` 的残留索引子进程会和 bench 的 clangd 抢 CPU，
误读所有数据。已固化为 skill `clangd-lsp-benchmark-isolation`。

---

## 6. Numbers (measured)

```
CDB 体积:           323 MB → 551 MB  (+228 MB / +71%)
.h inject 生成:      7.1 s         (单线程 Python, 解析 992 个 .cpp.json)
.h entries 注入:    15286          (cdb-donor 2017 / wrapper-donor 13269 / skip 2)
脚本峰值内存:       ~500 MB
backup 文件:         compile_commands.json.before_h_poc (自动)
回滚:               python inject_h_entries.py --restore
```

clangd LSP 实测（v6 全量推送后）：

```
打开 .h (cold attach):        2-5 s
打开 .h (warm):               <1 s
diag 出现:                    open 后 ~0.5-3 s
34 个测试 .h 全 0 ERROR (12 直接打开 + 22 间接 buffer)
```

---

## 7. Out of Scope / Follow-ups

1. **CDB 体积优化**：551 MB 单 JSON 第一次加载几秒。可考虑：
   - 按 module 切多 CDB（clangd 支持多目录 lookup）
   - 跨 entry 共享 `-I` 列表（dedup at write time）
2. **fs_event watcher 联动 .h inject**：新增 .h 时自动跑增量 inject。
   现在 watcher 只动 raw CDB / csearch / gtags，inject 还是手动触发。
3. **inject_h_entries.py 落盘到 tools/**：目前还在 `C:/tmp/`。下次想干净化时
   搬到 `tools/inject_h_entries.py` 并接入 `:UEPrepare` 后置钩子。
4. **测耗时口径**：本次只在 UnrealEngine 仓测，UEProj 同情况未量化。

---

## 8. Pointers

实现脚本 (本仓暂无, 仍在 `C:/tmp/` 阶段, 见 follow-up #3)：
- `inject_h_entries.py`           生产脚本, 7s 全量, `--restore` 回滚
- `cpp_json_reverse.py`           调研用, 统计 `.cpp.json` 闭包覆盖率
- `poc_v6_full.lua`               nvim probe (restart clangd + 12 .h + diag dump)

相关 skill：
- `docs/skills/ue-ide-bootstrap.md` —— 把本设计当作第 4 步消费
- `clangd-pch-precompile` (umbrella for clangd-on-UE perf)
- `clangd-indexer-ue-defs-injection` (super-unity 主线, .idx 生成)
- `super-unity-cdb-pipeline` (super CDB 与 raw CDB 双轨)
- `clangd-h-cdb-entry-inject` (老的 PoC 阶段总结, **v6 后部分过时**)
- `clangd-asymmetric-diag-vs-gd-cdb-shape-mismatch` (LSP 不能吃 unity CDB)

相关历史 plan：
- `docs/plans/2026-05-07-ue-unity-cdb-handoff.md` (super-unity 上一阶段)
- `docs/plans/2026-05-07-cdb-pipeline-split.md` (active CDB 与 indexer CDB 拆分)
- `docs/plans/2026-05-07-ueprepare-csearch-pipeline.md` (csearch 集成)
