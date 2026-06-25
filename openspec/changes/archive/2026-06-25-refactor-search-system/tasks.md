# Tasks: refactor-search-system

> 完成硬标准（根 CLAUDE.md Definition of Done）：改完跑对应 filter 回归；提交前必跑全量
> `nvim --headless -l tests/run.lua`；记 changelog（含 Validation）。本 change 影响面跨缓存布局
> + 入口策略 + UI → 全量回归门禁。

## 能力1：csearch 索引去平台化

- [x] 1.1 `cache_paths`：`csearch_idx` 改为 `csearch/csearch.idx`（去 `platform_key`）；gtags/cdb 保持 per-platform。更新 `cache_paths` 顶部 layout 注释（v3.x）。
- [x] 1.2 迁移逻辑：实现「平台子目录 → 扁平」迁移（design.md M1 提升 或 M2 标记 stale，二选一并注释理由）；旧 `<key>/` 索引不主动删。
- [x] 1.3 确认 `csearch_input_hash`（per-engine_root）与单份索引对齐，无需改维度；清理任何按平台读写索引路径的残留调用点。
- [x] 1.4 回归：`utils`、`grep_cache_spec`、`csearch_build_guard_spec`；新增迁移测试（扁平不存在/已存在两分支，幂等）。
- [x] 1.5 文档：`code_search/CLAUDE.md` 去平台化布局说明（删除「索引按平台+配置分路径」旧描述，改为「索引全平台共用；gtags/cdb 仍分平台」）；`grep-cache-invalidation.md` 失效维度简化。

## 能力2：`<leader>/` 去 rg + UI 收尾

> 重大修正（见 design.md 决策2）：UI 主体**已实现**于 `cached_grep`（toggle / 分组 / 后端标题 /
> preview 全部在了，且 toggle 已通向 csearch 后端）。本能力收窄为：入口去 rg + 补 scope + 收尾。

- [x] 2.1 入口从不加 rg：从 `<leader>/`（`ue_project_grep`/`cached_grep`）路径**整段移除**三处 rg 暗门——② rg-batched fallback（`ue.lua:6676`）、③ `return nil` → snacks 目录遍历（`ue.lua:6699`）、rg fast-path `source="ue_grep_rg"`（`ue.lua:6731-6747`）。`is_indexed==false` 时直接可见报错引导 `:UEPrepare`，**不打开任何 picker**。**不改 `stream()` 内 rg 分支**（gd/gr 兜底，P12）；`<leader>sG` 保留显式 rg。
- [x] 2.2 回归断言两面：(a) `<leader>/` 在无索引时 **MUST NOT** 打开任何 rg picker（堵死三处暗门，新增断言）；(b) rg 兜底链未被砸穿：`ue_goto_behavior`（clangd MISS → csearch_fallback → stream → rg 仍可达）。
- [x] 2.3 结果分组 + 计数 — 已实现（`format_grouped`/`preview_grouped`/`confirm_grouped`/`on_show_picker`）。本 change 仅做去 rg 后回归验证。
- [x] 2.4 后端状态标题 — 已实现（`grep_backend_title` → `[csearch]`）。
- [x] 2.5 可视化 toggle（regex/word/case）— 已实现（`<a-r/g/x/w/c>` + 标题图标 + notify），且经 `stream` 通向 csearch（RE2 改写）。
- [x] 2.6 preview 高亮 + 布局 — 已实现（telescope layout + `on_show_picker` 200ms throttle）。
- [x] 2.7 **面板内 scope 过滤（唯一新 UI）**：新增 `ue_grep_toggle_scope` action，从 `current_scope_info` 取当前模块/插件 root → 拼 path-regex 经 csearch `-f`（复用 `init.lua:184` 机制）→ `picker:find()` 重跑；标题反映 scope。无需新后端能力。
- [x] 2.8 回归：`cached_grep` 行为测确认 toggle 在「纯 csearch（去 rg 后主路径）」下仍正确（flag 等价 `regex/word/case` → RE2 改写）；`keymap-command-regression`（新增 scope 键位 / 改键位描述时同步冻结清单）。
- [x] 2.9 诊断清理：评估移除 `cached_grep` 内常驻诊断（`ue_grep_backend_debug.log` 注释自述「确认修复后移除」；`ue_grep_trace` 保留为 opt-in）。
- [x] 2.10 文档：cheatsheet / README grep 用法与键位表（说明 `<leader>/` 无 rg、rg 走 `<leader>sG`；补 scope 键位；toggle 已是现状，校对叙述）。

## 能力3：UEPrepare 对 csearch 的校验强化

- [x] 3.1 `:UEPrepare` 全量成功后断言 `csearch.idx` 可用（复用 `usable_index_stat`）+ 记录 `csearch_input_hash`（复用 `on_full_csearch_success`，确认所有全量路径一致）。
- [x] 3.2 freshness 维度简化：去掉「切平台 → 换索引」维，保留「内容指纹 + persistent_dirty + 存在性」。
- [x] 3.3 回归：freshness 指纹判据测试（集合不变=fresh、增删改名=stale、字节相同=fresh）保持通过；确认去平台化未引入假 fresh/stale。

## 收尾（Definition of Done）

- [x] 4.1 全量回归 `nvim --headless -l tests/run.lua` 全绿。
- [x] 4.2 `docs/changelog.md` Unreleased 追加一条，Validation 写明所跑回归范围与结果。
- [x] 4.3 若触发 semver/milestone（缓存布局破坏性变更），按 milestone 政策处理（release 文档 + changelog 归档 + git tag〔须用户确认〕 + 知识库同步）。
