# hana-alice/nvim 2.13.1 — 缓存跟随引擎、选择器确认修复与冷索引研究留底

> Patch；用户 2026-11-05 授权 sync / archive / commit / push，脱敏归档，不创建 tag。

## 修复与调整

- **缓存与工作目录跟随引擎**：除 Neovim 配置本身外，clangd TEMP、批次证明工作目录、日志、诊断 trace、Editor 测试报告、定义缓存、搜索历史与工作上下文统一经新模块 `lua/ue/engine_cache.lua` 落到 `<engine>/.cache/nvim-ue/`，无引擎时回落 stdpath。原因：生产 clangd 以 background 优先级运行，Windows 上同时降低 IO 优先级，系统盘写入被放大（K76）。刻意例外见 K76。
- **`vim.ui.select` 回车报错**：`:UESetPlatform` 等选择器按 `<CR>` 报 `Either item.buf or item.file is required`；默认确认动作改注册为 `picker.actions.confirm`。
- **冷索引研究留底（K77）**：写 shard 慢的根因是 `llvm::writeToOutput` 临时文件路径每文件调用 `GetVolumePathNameW`；修掉后前缀 PCH 恢复为杠杆。仅为文档，私有研究数据不进公开仓。

## 实测范围与结论

全量回归（required-native）：**4472 通过，0 失败，2 个显式跳过**。冷索引数字（全工程 481 s 等）来自私有离线索引器实验，与旧基线输入不同，同 CDB 对照与严格门禁尚未完成；本版本不改生产索引路径，不宣称性能恢复。

## 归档记录

### 2026-11-05 — Record the shard-write root cause and the full-project PCH measurement

**Task**
- Keep the defensive record of the cold-index research current (research data stays private).

**Implemented**
- `docs/CONSTRAINTS.md` K77: shard writes were slow because `llvm::writeToOutput`'s temp-file path
  calls `GetVolumePathNameW` per file (~3.5 ms); with tmp+rename in the private offline indexer,
  prefix PCH is a lever again (6-row sample 1.77x; full project 481 s + 95 s PCH production vs
  the older 1028 s baseline on a different CDB; stock clangd loads the store with 0 re-index).
  Lessons: manifest keys must match clangd's effective command (backslashed source after `--`),
  and gates/attribution use small samples, not full runs. `lessons/README.md` K77 line updated.

**Validation**
- Full regression (required-native) 4472 OK, 0 FAIL, 2 explicit skips (includes `structure`). No code change.

### 2026-11-05 — Everything except the Neovim config follows the engine

**Task**
- User rule: apart from the Neovim configuration itself, caches/state/logs/work outputs live
  with the engine (`<engine>/.cache/nvim-ue/...`); stdpath only when no engine is known.

**Implemented**
- New `lua/ue/engine_cache.lua` (`dir` / `dir_or` / `file`): engine from explicit root, a path
  inside the engine, or the current buffer/cwd; a recorded engine that no longer exists falls back.
- Moved: `ue.config` `paths.state_dir`/`cache_dir`; Editor test reports (`ue-tests`);
  `_logged_jobstart` pipeline logs (`logs/<tag>`, engine from `opts.cdb`/`cwd`); grep trace/error/diag/
  backend-debug logs; DAP breakpoint-diag and lldb-dap protocol logs (diag report lists them);
  `ue_def_trace` (now lazy, first trace); no-selection definition cache; cursor-shim build cache
  (from the controlled CDB's `.cache/nvim-ue` ancestor); search history and work contexts
  (per project engine, read-only import of the old stdpath bucket); batch-work inventory reports.
- Kept outside on purpose (documented in K76): CDB transaction staging, watch probes and
  short-lived request JSON under watched roots; nvim-dap's own logger; private machine policy
  files (SDK policy, BuildDispatch); nvim-intrinsic state (lazy, shada, sessions, probes, recovery).

**Validation**
- New `engine_cache` 7/7. All green: `ue_config` 11, `smoke` 19, `ue_api` 67, `commands` 167,
  `dap` 308, `platform` 93, `ide_ue_tools` 16, `search_` 137, `ide_work_context` 41,
  `multi_instance_state` 28, `ue_cdb` 212 (1 skip), `index_switch_reindex` 28, `utils` 51,
  `cpp_semantic_sidecar` 58, `cpp_semantic_client` 71, `cpp_semantic_context` 13,
  `ue_goto_behavior` 107, `android_ide` 45, `structure` 85, `stability` 26, `clangd_temp` 6,
  `ue_distributed` 9, `ue_target_drivers` 56, `grep_query` 6, `workarounds` 48,
  `ue_platform_boundary` 20, `ide_workbench` 20, `ide_workspace` 24, `host_resource_discipline` 13,
  `index_batch_work_inventory` 11. Full regression not run (agile mode). CONSTRAINTS K76 extended.
- Close-out: stale stdpath wording in comments (`_logged_jobstart`, pipeline step logs, history hub,
  Android bp-diag) updated; legacy stdpath grep/pipeline logs removed. `structure` 85, `smoke` 19,
  `engine_cache` 7, `ue_api` 67 green.

### 2026-11-04 — Keep clangd TEMP and batch proof work with the engine

**Task**
- Record the cold-index research lessons defensively, and move cache/work directories
  from the system drive to the engine (`<engine>/.cache/nvim-ue/`).

**Implemented**
- `docs/CONSTRAINTS.md`: K76 (background-priority clangd is IO-throttled; C: shard writes
  7–10 ms vs ~1 ms on the engine drive), K77 (cold-index research method); corrected the
  "Windows 未验证" note on `--background-index-priority`. `lessons/README.md` navigation.
- `lua/ue/clangd_temp.lua`: TEMP root is `<engine>/.cache/nvim-ue/clangd-tmp/<pid>` when the
  engine is known; stdpath fallback otherwise; dead sessions in the legacy root are still swept.
  `lua/plugins/ue.lua` passes `ue.engine_root_of(config.root_dir)` (new helper in `lua/ue.lua`).
- `tools/cdb_verified_batch.py` `_proof_work_root`: outputs inside an engine cache use
  `<engine>/.cache/nvim-ue/batch-work/<hash>`; others keep `%TEMP%/nvim-ue-batch-work`.
  `lua/ue/index/switch_commands.lua` inventory mirrors that root.
- `tools/cdb_batch_work_inventory.py`: do not walk the work root (or `clangd-tmp`) as metadata
  when it sits inside a reference root.

**Pitfalls / Gotchas**
- CDB prepare staging stays outside live roots on purpose (native watcher overflow risk);
  not moved in this change.
- Existing data in `%TEMP%/nvim-ue-batch-work` (~35 GB) is not migrated or deleted; new work
  goes to the engine cache, old receipts still resolve via their recorded paths.

**Validation**
- `clangd_temp` 6/6, `smoke` 19/19, `ue_api` 67/67, `index_batch_work_inventory` 11/11 (new
  `engine_cache` case RED without the inventory fix), `index_verified_batch` 131/131,
  `index_batch_migration` 1/1, `index_batch_background_tier2` 11/11, `index_switch_reindex` 28/28,
  `structure` 85/85. Full regression not run (agile mode). Spec note added (cpp-semantic-index-coverage).

### 2026-11-04 — Keep vim.ui.select confirm out of the global file-jump route

**Task**
- `:UESetPlatform` (and every other `vim.ui.select` picker) failed on `<CR>` with
  `snacks/picker/actions.lua:97: Either item.buf or item.file is required`.

**Implemented**
- `lua/plugins/snacks.lua`: register the layout-routed default confirm as
  `picker.actions.confirm` instead of the top-level `picker.confirm` shortcut.
- `tests/cases/layout_spec.lua`: assert the new option shape and drive a real
  `Snacks.picker.select` under the repo options, checking `<CR>` returns the choice.

**Pitfalls / Gotchas**
- `Snacks.picker.select` calls `config.get` once itself and `Picker.new` calls it again
  on the already-merged opts; the second pass re-expands a global `confirm` shortcut
  over select's own `actions.confirm`, so the select item got a file jump.
  Reproduced in isolated `nvim -u NONE` with only snacks loaded (shortcut → error,
  `actions.confirm` → choice returned). Introduced by 334cb34 (2026-10-16).

**Validation**
- `layout_spec` RED without the fix (99/100, "default confirm did not use layout" after
  spec update), GREEN with it (100/100). `review_editor` 11/11, `smoke` 19/19,
  `file_inventory` 24/24, `ide_editing_feedback` 21/21, `ue_goto_reading` 58/58,
  `layout_management` 23/23, `ide_hub` 34/34. Full regression not run (agile mode).

**Follow-ups**
- Restart Neovim (or `:Lazy reload snacks.nvim`) to pick up the option change.
