# Neovim Config Changelog

Working log for every change inside `~/AppData/Local/nvim/`. Every commit
should add an entry here even if it's tiny — the goal is total recall across
sessions, not curated release notes. When entries pile up, slice off a
versioned `RELEASE_vX.Y.Z.md` (see `release_1.0.0.md` for the format) and
keep this file rolling forward as the unreleased section.

## Entry template

```
### YYYY-MM-DD — Short title

**Task** (one line — why you touched the config)

**Implemented**
- bullet list of concrete changes (file paths + function names)

**Pitfalls / Gotchas**
- traps hit during the change, with the fix

**Validation**
- how you proved it works (headless probe, live nvim test, etc.)

**Follow-ups**
- links to `.hermes/plans/*.md` or TODO bullets
```

## How to use

1. Before touching anything under `~/AppData/Local/nvim/`, skim the latest
   N entries here. Fresh sessions don't carry context — this is where you
   recover it.
2. After landing a change (even a one-line patch), append an entry. The
   **Validation** field MUST state which regression scope you ran (a filter
   like `dap`/`commands`, or full `nvim --headless -l tests/run.lua`) and the
   result — see `docs/testing-regression.md` for the change→filter map.
3. When 8–12 entries have piled up OR a coherent multi-change effort wraps,
   cut a **milestone**: bump the version by semver (BREAKING→major, new
   capability→minor, fix→patch), move entries into `docs/release_vX.Y.Z.md`,
   run the **full** regression as a gate, tag the commit (`vX.Y.Z`,
   confirm with the user first), and leave a one-line cross-link under
   "Released" below. If the milestone touched architecture, also update
   `memory/` and `docs/architecture/overview.md`. (Authoritative: root
   `CLAUDE.md` Definition of Done; `docs/CONSTRAINTS.md §三 C7/C8`.)

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`

## Unreleased

### 2026-07-29 — 提升 C/C++ 语义角色对比

**Task**

修复 struct/class 与 field/property 等相邻语义角色层次不够清晰的问题，并系统收敛六个白名单主题中其他同类视觉冲突。

**Implemented**

- `lua/highlights.lua` 新增六主题 palette-source profile：不复制 RGB，而从当前主题既有 `Type` / `Identifier` / `Function` / `Constant` 等基础 group 派生 C/C++ type、field、parameter、variable、function、enum member、macro 与 namespace 八类角色。
- 同一 role 同步覆盖 Treesitter 的当前/兼容 capture、clangd `@lsp.type.*.{c,cpp}` semantic token，以及 LSP 标准实际存在的 `CmpItemKind*` / `BlinkCmpKind*`；不伪造标准中不存在的 Parameter/Macro completion kind。
- type/function/enum 使用 bold，parameter/namespace 使用 italic，macro 使用 bold+italic；declaration/definition、readonly/static/abstract/virtual、deprecated 的 generic 与 `@lsp.typemod.*` group 只叠加 bold/italic/strikethrough，不带 foreground，避免高优先级 modifier 抹掉角色颜色。
- Rider Light 与 Ubuntu Terminal 保留各自完整跨语言映射，只由最终层收敛精确 `.c` / `.cpp` group；其他主题继续获得既有 generic fallback，主题外观不被统一成一套 palette。
- `tests/cases/theme_spec.lua` 新增六主题矩阵回归，逐项冻结关键角色不同色、Treesitter/LSP/completion 同色、modifier 无 foreground，以及 `ColorScheme` 连续切换不泄漏上一主题 RGB。
- 新增并归档 OpenSpec `improve-cpp-semantic-contrast`，主规格为 `cpp-semantic-highlighting`。

**Pitfalls / Gotchas**

- clangd 同一 token 会同时发布 `@lsp.type.*`、`@lsp.mod.*` 和更高优先级的 `@lsp.typemod.*`；只修 type group 不够，若 typemod 带 foreground，最终显示仍会被它覆盖。
- 当前 Treesitter 使用 `@variable.parameter`，旧配置仅写 `@parameter`；两者必须同时覆盖，否则 clangd 到达前后会发生颜色跳变。
- LSP `CompletionItemKind` 没有 Parameter、Macro、Namespace 或 Package 独立 kind；其中 namespace 对应 Module，不能为了测试对称性创建永远不会被 renderer 使用的伪 group。

**Validation**

- 分范围回归：`theme` 11/11 passed、`smoke` 17/17 passed。
- 当前 Neovide 的真实 Sonokai Espresso + clangd C++ buffer 已热加载验证：class/struct `#81d0c9`、field/property `#f08d71`、parameter `#f0c66f`、variable `#e4e3e1`、method `#a6cd77`、enum member `#9fa0e1`、macro `#f86882`、namespace `#90817b`；`vim.inspect_pos` 确认 Treesitter、`@lsp.type.*` 与无 foreground 的 typemod 同时生效。
- 全量 `nvim --headless -l tests/run.lua`：656/656 passed。
- 归档后主规格 `openspec validate cpp-semantic-highlighting --strict` 与 `git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-07-29 — 集成 Sonokai Espresso

**Task**

把 `sainnhe/sonokai` 的 Espresso variant 集成到刚收敛完成的统一主题入口中，同时不暴露其他 Sonokai variants。

**Implemented**

- `lua/plugins/colorscheme.lua` 新增 lazy plugin `sainnhe/sonokai`（name=`sonokai`），`lazy-lock.json` 锁定 commit `b023c5280b16fe2366f5e779d8d2756b3e5ee9c3`。
- `lua/theme.lua` 的有序 registry 新增 canonical theme `sonokai-espresso` / label `Sonokai Espresso`，并扩展统一 loader 以支持 canonical name、runtime colorscheme name 与每次加载前 hook。
- 每次应用或恢复该主题都强制 `g:sonokai_style="espresso"`，实际执行 `:colorscheme sonokai`，`theme.current()` 再映射回 `sonokai-espresso`；直接 `:Theme sonokai` / `sonokai-maia` 等未注册入口仍被拒绝。
- 固定 `g:sonokai_better_performance=0`，避免上游文档所述首次同步生成 syntax cache 最长约 5 秒的 P6 主线程阻塞风险。
- `tests/cases/theme_spec.lua` 扩展为严格六项 surface，新增 Espresso 实际配置、外部篡改 variant 后重置、持久化恢复和 plugin/lock source 回归；两种 cheatsheet surface 同步 canonical name。
- 新增并归档 OpenSpec `add-sonokai-espresso-theme`，更新 `curated-theme-entrypoints` 主规格为严格六项。
- 全量回归还捕获到 probe `_overflow` 在同秒 timestamp tie 下可能被 compaction 随机裁掉；`lua/utils/probe.lua` 现固定保留这条“topic 因洪水自休眠”的关键证据，并为普通 key 加稳定 tie-break。

**Pitfalls / Gotchas**

- Sonokai 的公开 canonical name 与实际 `vim.g.colors_name` 不同：前者必须是唯一入口 `sonokai-espresso`，后者固定为插件提供的 `sonokai`；registry metadata 负责映射，不能把原生 `sonokai` 暴露进 completion。
- 上游 `g:sonokai_better_performance=1` 会在首次使用时同步生成大量 `after/syntax` 文件；这会把一次主题预览变成潜在数秒阻塞，因此本仓有意保持 `0`。
- probe cap compaction 原先对同秒记录的排序不稳定，偶发先删除 `_overflow`；现将特殊证据固定排在淘汰序列末端，普通 key 同 timestamp 时按 key 排序。

**Validation**

- 分范围回归全绿：`theme` 9/9、`smoke` 17/17、`keymaps` 50/50、`commands` 84/84、`cheatsheet` 113/113、`structure` 38/38。
- 完整启动 probe：`:Theme sonokai-espresso` 后 `vim.g.colors_name=sonokai`、`g:sonokai_style=espresso`、`g:sonokai_better_performance=0`、`theme.current()=sonokai-espresso`，且 `Normal` 背景为上游 Espresso palette 的 `#312c2b`；随后恢复默认主题。
- 全量 `nvim --headless -l tests/run.lua`：654/654 passed。
- `openspec validate add-sonokai-espresso-theme --strict` 与 `git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-07-29 — 主题入口收敛为五项

**Task**

把所有项目主题入口严格收敛到 Monokai Ristretto、Rider Light、Ubuntu Terminal、Unokai、Catppuccin，并先处置会话探针报告中由回归测试自产生的假失败证据。

**Implemented**

- `lua/theme.lua` 改为单一有序五项注册表；`:Theme` completion、picker、合法性检查和 plugin lazy-load 均从它派生，删除旧 aliases/flavors，并把非法持久化值迁移到默认 `monokai_ristretto`。
- `lua/plugins/colorscheme.lua` / `lua/config/keymaps.lua` 将 `<leader>ut`、`<leader>uC` 统一接到受限 `ThemePicker`；禁用 LazyVim Tokyo Night、删除 Kanagawa declaration，并同步 `lazy-lock.json` 与 lazy install fallback。
- 删除 `colors/apprentice.lua`、`colors/porcelain-white.lua`；保留本地 Rider Light/Ubuntu Terminal、Monokai/Catppuccin plugin 与 Neovim 内置 Unokai。
- 重写 `tests/cases/theme_spec.lua`，冻结五项 canonical name、label、顺序、旧 state 迁移、旧入口拒绝及五主题实际加载；同步 keymap/cheatsheet tests 与两种 cheatsheet surface。
- 处置探针 `dirty-set-flood` / `foreign-buffer` 记录：确认均由 headless regression 的临时 fixture 触发而非真实工作区故障；`tests/run.lua` 现以 `NVIM_UE_PROBE_PATH` 隔离测试存储，`lua/utils/probe.lua` 在 test path 切换时关闭待写 debounce timer，并新增防延迟串写回归；真实 probe store 已清空。
- 新增并归档 OpenSpec `limit-theme-entrypoints`，主规格为 `openspec/specs/curated-theme-entrypoints/spec.md`。

**Pitfalls / Gotchas**

- 仅从 theme registry 删除旧项不够：旧 `theme.txt` 原先会被重新并入候选列表，上游 `<leader>uC` 也可能打开 runtimepath 全量 colorscheme picker；两条旁路都必须封住。
- Catppuccin 的 canonical 入口为 `catppuccin`，加载后 `vim.g.colors_name` 会成为具体 flavor（当前为 `catppuccin-mocha`）；`theme.current()` 只折叠运行时 identity，不重新暴露 flavor。
- probe tests 的 2 秒异步 save timer 曾在 `_set_path_for_test(nil)` 后把 fixture 写进真实 store；测试路径切换现在先 stop+close timer，runner 另设进程级临时路径形成双保险。

**Validation**

- 分范围回归全绿：`theme` 7/7、`smoke` 17/17、`keymaps` 50/50、`commands` 84/84、`cheatsheet` 112/112、`structure` 38/38、`probe` 19/19。
- 全量 `nvim --headless -l tests/run.lua`：651/651 passed。
- 完整启动 probe 确认当前主题 `monokai_ristretto`、completion 恰为五项，且 `<leader>ut` / `<leader>uC` 最终映射均为 `ThemePicker`（`nowait=1`）；五个 canonical theme 均实际加载成功。
- `openspec validate limit-theme-entrypoints --strict` 通过；`git diff --check` 通过。环境未安装 `stylua`，未执行该非仓库门禁工具。

**Follow-ups**

- 无。

