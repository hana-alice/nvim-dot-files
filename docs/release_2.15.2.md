# hana-alice/nvim 2.15.2 — prepare 提示 UHT 过期、Diffview gd 不再拆散 diff、索引日志降噪

> Patch。用户 2026-11-12 授权 sync / archive / commit / push，按脱敏要求归档。tag 待用户确认。

## 新能力与修复

- **prepare 后提示 UHT 过期**：`:UEPrepare` 从上次编译留下的 `.rsp` 文件拼 compile_commands，不运行 UnrealHeaderTool。切分支后 `*.generated.h` 没有重新生成，clangd 会在共享 PCH 上报出大量误报。现在 prepare 完成后会后台对比各模块的 `Inc/<Module>/Timestamp`，发现过期就弹 WARN，提示先编一次，再 `:LspRestart`。只提示，不自动编译。
- **Diffview 里 `gd` 跳到编辑 tab**：不再替换某一侧的 diff 窗口，两侧都保持原 buffer 和 diff 模式。
- **日志降噪与稳健性**：
  - Git 文件清单超时从 15s 放宽到 120s，超时和其他失败分开报。
  - `write_all` 在 EPERM/EACCES/EBUSY 时有限重试。
  - 后台 proof 遇到重复的失败原因只记一次。

## 实测范围与结论

- 本地完整回归：4490/4490 通过，2 skip。改动前基线为 4486/4486。
- 在真实工程中间目录上，UHT 检测扫 238 个模块、4605 个头文件，耗时 0.74s，查出 75 个过期头。
- **未做 / 待验证**：
  - `controlled index build failed … no longer matches its successful manifest` 未处理。推测与多个 Neovim 同时写同一份发布文件有关，尚未闭环验证。
  - 夜间 in-process 主循环卡顿的根因未定位。

## 归档记录

### 2026-11-11 — UEPrepare warns about stale UHT output; quieter index logs

**Task**
- UEPrepare builds compile_commands from the last build's `.rsp` files and never runs UnrealHeaderTool. After a branch switch, `*.generated.h` and its line-keyed `GENERATED_BODY` macros went stale, and clangd reported dozens of false errors that came from the shared PCH.
- Daily logs showed recurring noise: `Git tracked inventory unavailable:` with an empty reason, `atomic replace failed: EPERM`, and thousands of identical `background proof retained originals` WARN lines.

**Changes**
- New `ue.cdb.uht_freshness`: after prepare, compares each UHT `Inc/<Module>/Timestamp` against the headers it lists for the active platform. If any are newer, prepare shows a WARN asking you to build once and then `:LspRestart`. It runs asynchronously and finished in under 1s on 4.6k headers.
- The Git tracked-file inventory timeout goes from 15s to 120s. A timeout (exit 124) is now reported as a timeout, and other failures include the exit code.
- `write_all` retries the rename up to three times (10/25/50ms) on EPERM/EACCES/EBUSY. Windows rejects the replace while another process briefly holds the target open.
- The background proof logs a repeated failure reason once instead of every 5s retry.

**Tests**
- `tests/cases/ue_uht_freshness_spec.lua` (4 cases), plus `file_inventory` and `index_batch` regressions.

### 2026-11-11 — gd inside Diffview no longer breaks the diff pair

**Task**
- In a Diffview tab (`<leader>gv`), `gd` replaced the current diff pane's buffer with the target file. The other pane was left alone and the diff became unusable. CodeDiff already routed `gd` to the editing tab; Diffview did not.

**Implemented**
- New `lua/utils/layout_diffview.lua`: reads the already-loaded `diffview.lib` (`tabpage_to_view`) and builds review-group options (valid/focus/restore, repo, selected path). It never loads Diffview.
- `lua/utils/layout.lua`: `navigation_owner` and `discover_groups` register a Diffview tab as a `review` group. `routes_to_normal` is therefore true there, and `gd`, LSP jumps and picker confirmations go to the normal editing tab (`<leader>w[` returns). CodeDiff-only token retirement is restricted to `owner == "codediff"`.

**Validation**
- New `tests/cases/git_review_diffview_goto_spec.lua` (real LazyVim child, real `<leader>gv`): a jump from either pane lands in the editing tab, and both panes keep their buffer and `diff` mode. After `DiffviewClose` the tab routes normally again. It fails without the fix ("Diffview tab is not a review owner").
- `layout` 158/158, `review` 128/128.
