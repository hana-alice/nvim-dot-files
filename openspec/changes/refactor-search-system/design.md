# Design: search 系统小幅度重构

## Context

三块改动共享一个事实基础：**csearch 是纯文本 trigram 索引，其内容与平台无关；当前的 per-platform 分片是 cache layout v3.1 让 csearch 搭了 gtags/cdb 同一套 `platform_key` 目录的便车，而非 csearch 自身有平台差异需求。** 本文档先证伪「csearch 必须分平台」，再厘清「去 rg」的精确边界，最后给迁移与校验设计。

调研链（前序）：Everything 1.5 内容索引判死（文档限 ≤1GB、默认不含 .cpp/.h、无正则、RAM 常驻）；zoekt Windows 死胡同（P13 已记）；rg/ugrep 慢在 NTFS 遍历而非匹配。结论：csearch 是 Windows 内容搜索天花板，不换引擎。

## 决策1：csearch 索引去平台化

### 风险1 证伪——文件清单输入确为平台无关

去平台化的唯一真实风险是：「若不同平台纳入不同源码目录，共用索引会搜到/漏掉非本平台文件」。用代码逐一证伪：

| 文件清单输入 | 来源 | 是否读平台字段 |
|---|---|---|
| 引擎目录 | `UE_CONST.ENGINE_PICKER_DIRS`（`Engine/Source` / `Plugins` / `Shaders` / `Config` 固定常量） | ❌ |
| 项目目录 | `ctx.project_root` | ❌ |
| 扫描排除 | `UE_CONST.SCAN_EXCLUDES`（固定常量） | ❌ |
| 项目白名单 | `.ueprepare-scan-paths`（`CORE_RT.project_index_dirs`，key=`project_root`，注释明写 "REPLACES PROJECT_INDEX_DIRS for this project"） | ❌ |

`picker_search_dirs(ctx)`（`ue.lua:1830`）与 `scan_relative_files_async`（`ue.lua:3738`）均不接受、不读取 `platform_key`。**文件集 = f(engine_root, project_root, 平台无关常量/白名单)，无平台维度。** 风险1 不成立——去平台化是「去掉一个伪维度」，不是「强行合并有差异的东西」。

### 校验维度本已不一致（去平台化反而修复）

- `csearch_input_hash` 存于 `state.json`，由 `read_state(ctx.engine_root)` 读取 → **per-engine_root，一份**（`ue.lua:3431-3433`）。
- 当前 csearch 索引 → **per-platform，N 份**（`csearch/<key>/csearch.idx`）。

即：一份指纹在「校验」N 份索引。切平台后新平台索引可能为空 / 旧指纹，`prepare_freshness` 的判定与「当前实际使用的那份索引」并不严格对应。去平台化后两者都是「一份」，维度天然对齐，校验逻辑更自洽。

### 承重梁不动：gtags/cdb 仍 per-platform

```
cdb (clangd compile-db)  ── 真·平台相关 ── 编译参数/宏/include 按 Win64/Android 完全不同
gtags                    ── 半平台相关 ── 符号库吃条件编译
csearch (纯文本 trigram) ── 平台无关 ──── 只搭了同一套分片目录的便车  ◀ 仅此项去平台化
```

只把 csearch 抽出共用，cdb/gtags 的 `platform_key` 分片原样保留。代价：目录布局不再「三者一致」（csearch 扁平、gtags/cdb 分平台），需在 `cache_paths` 注释与 `code_search/CLAUDE.md` 写清，否则后人困惑。

### 迁移设计

去平台化后的 `csearch/csearch.idx` 恰是 v3.1 之前的 legacy 扁平路径。`migrate_legacy_csearch_if_needed` 当前做「扁平 → 平台子目录」；本 change 需要反方向。两种实现取其一：

- **方案 M1（提升）**：首次以去平台化 `cache_paths` 解析时，若扁平 `csearch/csearch.idx` 不存在但存在任一 `csearch/<key>/csearch.idx`，MOVE 一份上来作为共用起点。省一次重建。
- **方案 M2（标记 stale）**：不搬运，直接让 `prepare_freshness` 判 stale，首次 `:UEPrepare` 重建扁平索引。实现最简，代价一次全量构建。

倾向 M2（最简、零搬运风险），但 M1 体验更顺——在 tasks 阶段二选一并写测试。无论哪种，旧的 `csearch/<key>/` 残留索引 SHALL NOT 因去平台化被主动删除（与既有「切平台不删旧平台索引」精神一致，留给用户/清理命令）。

## 决策2：`<leader>/` 去 rg 的精确边界

### 重大修正：能力2 的 UI 绝大部分已实现（snacks 源码 + cached_grep 坐实）

调研 snacks 源码（`nvim-data/lazy/snacks.nvim`）与 `ue.lua` 的 `cached_grep`（6130-6520）后，**能力2 不是绿地开发，而是「已基本实现，补 scope + 收尾」**。逐项对账：

| 能力2 子项 | 状态 | 证据 |
|---|---|---|
| 可视化 toggle（大小写/全词/正则） | ✅ 已实现 | `ue.lua:6356-6395`：`<a-r>/<a-g>` regex、`<a-w>/<a-x>` word、`<a-c>` case；toggle 翻转 `picker.opts.*` → `picker:find()` 重跑 |
| 标题栏图标反映开关 | ✅ 已实现 | `ue.lua:6356-6360` `toggles = { regex/word/case = { icon, value=true } }`；snacks 在 `picker.opts[name]==value` 时渲染图标 |
| toggle → csearch 后端生效 | ✅ 已实现 | `stream()` 接 `regex/word/case/ignore_case`（`ue.lua:6440-6447`）→ `init.lua:205/215/219-225` 在 csearch 路径用 RE2 改写（literal 转义 / `\b` 包裹 / `(?i)` 前缀），**不只 rg 分支** |
| 结果分组 + 计数 | ✅ 已实现 | `format_grouped` / `preview_grouped` / `confirm_grouped` / `on_show_picker`（文件头 `_is_grep_header`，`ue.lua:6248-6273,6397-6400`） |
| 后端状态标题 `[csearch]` | ✅ 已实现 | `grep_backend_title(..., backend_label)`（`ue.lua:6334`） |
| preview 高亮 + 布局节流 | ✅ 已实现 | telescope layout + `on_show_picker` 200ms throttle（`ue.lua:6248-6256`） |
| **面板内 scope 过滤** | ❌ **唯一真实缺口** | 无 `ue_grep_toggle_scope` action；scope 仍只在独立键 `<leader>uO`/`ue_scope_grep` |

**snacks 的 toggle 机制（已被 cached_grep 正确使用）**：在 `pick{}` 传 `toggles = { name = { icon, value } }` + `win.input.keys` 绑定 `toggle_<name>`，snacks 自动生成「翻转 `picker.opts[name]` → `picker:find()`」的 action（`actions.lua:745 toggle_live` 是同一范式：改 flag → `input:update()`）。cached_grep 用了自定义 action 版（加 notify 反馈 + `list:set_target()`），等价。

**snacks 内置 grep 源硬编码 `cmd="rg"`（`source/grep.lua:10`）**——这正是 cached_grep 必须用自定义 finder 走 csearch 的原因。所以能力2 的一切都挂在 cached_grep 自定义源上，与 snacks 内置 grep 无关。

### 能力2 收窄后的真实工作量

```
原以为: 实现 toggle + 分组 + 后端标题 + preview + scope   (5 项绿地)
实际:   toggle/分组/后端标题/preview 已实现 ── 仅入口去 rg + 补 scope + 收尾
```

- **入口去 rg**（2.1）：仍要做——见下「精确边界」。
- **面板内 scope**（2.7）：唯一新 UI。复用 csearch 内置 `-f` 文件路径正则过滤（`init.lua:184-194`，目前只服务 `code_only`）：新增 `ue_grep_toggle_scope` action，从 `current_scope_info` 取当前模块/插件 root → 拼成 path-regex 经 `stream` 的 `-f` 传入 → `picker:find()` 重跑；标题反映 scope。**无需新后端能力**。
- **收尾**：toggle 当前对 csearch 已生效；去 rg 后无行为回退，但要回归断言 toggle 在「纯 csearch（无 rg 兜底）」下仍正确（此前 toggle 可能在 rg 路径被验证过，去 rg 后主路径就是 csearch）。
- **清理**：`cached_grep` 内有两处 opt-in/always-on 诊断日志（`ue_grep_trace` + `ue_grep_backend_debug.log`，注释自述 "remove after they confirm the fix"）——本 change 顺带评估是否移除常驻诊断（`ue.lua:6303-6328`）。

### 关键约束：rg 是两个调用方的共享后端

`code_search.stream(ctx, pattern, ...)` 内部 `is_indexed(ctx) ? csearch : rg`（`init.lua:572`），有**两个**调用方：

```
stream()
 ├─ ① ue.lua:6440           <leader>/ 内容搜索        ← 要去 rg 的入口
 └─ ② ue_goto/csearch_fallback.lua:192   gd/gr 跳定义兜底  ← rg 是 P12 承重梁
       lsp_fallback 链: clangd MISS → csearch_fallback → stream()
```

**若在 `stream()` 内删 rg 分支 → 砸穿 gd/gr 最后兜底，违反 P12**（「csearch/gtags 只在 clangd MISS 时兜底，每层失败必 fall through，最终兜底 toast」）。

### 正确做法：去 rg 在入口层，不在后端层

- `ue_project_grep`（`<leader>/`）改为：`is_indexed(ctx)` 为真才调 `stream()`（此时只会走 csearch）；为假则**不调 stream()**，直接可见报错 + 引导 `:UEPrepare`。
- `stream()` 内部 rg 分支**保留原样**，继续服务 gd/gr 兜底（②）。
- `<leader>sG`（`ue_grep_all`）维持显式 rg 入口——用户要 rg 走那边。

结论：**rg 一行不删，只是 `<leader>/` 入口不再 fall 到它。** 这是「小幅度重构」该有的精度。

### 无索引语义（用户硬约束：`<leader>/` 从不加 rg）

用户定调：**`<leader>/` 从不加 rg——任何情况都不走 rg / 目录遍历**。这比「无索引报错」更彻底：连 cached-list+rg 批量搜索、连 snacks 默认目录遍历兜底都不要。

`cached_grep` 当前有**三层**入口分支，后两层都是 rg 暗门，本 change 从 `<leader>/` 路径**整段移除**：

```
cached_grep 入口分支:
 ① has_index → csearch fast-path           (ue.lua:6330)  ✅ 唯一保留
 ② rg-batched fallback (cached list + rg)   (ue.lua:6676)  ❌ 移除 — 暗门1
 ③ cached_file_list_info==nil → return nil  (ue.lua:6699)  ❌ 移除 — 暗门2
    → 旧行为是 return nil 让 snacks 默认目录遍历接管(更慢的 rg-ish 路径)
 + rg fast-path (source="ue_grep_rg")        (ue.lua:6731-6747) ❌ 移除 — 暗门3
   (含 _ue_grep_csearch_hint_shown 一次性提示)
```

**实施时发现的第 4 个暗门（design 原稿漏列，已修正）**：`ue_project_grep`
（`snacks.lua` 的 `<leader>/` 包装器）在 `cached_grep` 返回 nil 时会 fall 到
`snacks.picker.grep`（rg 目录遍历，旧标题 "slow fallback — run :UEPrepare"）。
这才是终端暗门。一并移除：`cached_grep` 返回 nil 时 `ue_project_grep` 直接返回
（cached_grep 已弹可见 ERROR），**不开任何 picker**。

去 rg 后，②③及 rg fast-path 整段由单一「无索引 → 报错引导 `:UEPrepare`」替代：`is_indexed(ctx)==false` 时 `ue_project_grep` 直接可见报错、**不打开任何 picker**（避免打开一个走 rg 的 picker）。

边界澄清：
- **`stream()` 内部 rg 分支保留**（`init.lua:572`）——那是 gd/gr 跳定义兜底（②号调用点，P12 承重梁），与 `<leader>/` 无关。
- **`<leader>sG`（`ue_grep_all`）保留显式 rg**——用户要 rg 走这里。
- 即：「从不加 rg」只约束 `<leader>/` 这一个入口；rg 后端本身一行不删。

## 决策3：UI Rider 化（snacks 呈现层）

全部走 snacks picker 既有扩展点，零后端改动：

- **分组 + 计数**：grep source 自定义 `format`，按文件聚合 + 命中数。
- **可视化 toggle**：picker `actions` 注册 `<A-w>/<A-c>/<A-r>`，维护 toggle 状态 → 重启搜索时翻译为 csearch/rg flag；状态字串拼进标题。
- **后端状态 / scope**：标题栏渲染 `[csearch]` + 当前 scope 名。
- **preview**：grep source 已用 telescope layout（`snacks.lua:529`），加匹配高亮 + 可调 context/比例。
- **面板内 scope**：`actions` 注册切 scope 键，复用 `current_scope_picker_options` / `scope_opts` 逻辑，原地重开搜索。

## 风险与回归

| 风险 | 缓解 |
|---|---|
| 去平台化误删/漏迁旧索引 | 迁移测试覆盖 M1/M2；旧 `<key>/` 索引不主动删 |
| 在 stream() 误删 rg 砸穿 gd/gr | spec 明确 rg 分支保留；`ue_goto_behavior` 回归断言兜底链完整 |
| UI toggle 状态与 flag 翻译错位 | `cached_grep` 行为测覆盖 flag 等价（`-- -w/-s/-F`） |
| freshness 维度简化引入假 fresh/stale | 保留指纹判据测试；去掉的仅「切平台」维 |

影响面跨缓存布局 + 入口策略 + UI → **提交前必跑全量** `nvim --headless -l tests/run.lua`。
