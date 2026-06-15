## 1. 现状收敛

- [x] 1.1 审核当前未提交 diff 中与 `<leader>/` 搜索相关的改动，保留有效实现，隔离无关 DAP/CDB 改动不纳入本 change。
- [x] 1.2 移除或收敛 `lua/ue.lua` 与 `lua/plugins/snacks.lua` 中临时 `DIAG v2` 日志，只保留必要的可测试状态或正式 trace。
- [x] 1.3 对照 `docs/architecture/grep-cache-invalidation.md`，确认实现术语、路径布局和 fallback 文案一致。

## 2. 流式搜索完整性

- [x] 2.1 完成 `lua/utils/code_search/init.lua` 中 csearch backend 的单一 flusher，实现 `on_line` 全部交付后再 `on_done`。
- [x] 2.2 完成 rg backend 的同等 single-flusher 逻辑，确保 stop 后不再回调。
- [x] 2.3 增加 headless 测试或可注入 seam，验证 `on_done` 后不存在未交付 parsed hits。

## 3. 缓存与回退语义

- [x] 3.1 确认 csearch/cindex probing 只缓存成功路径，并暴露幂等 `_reset_probe_cache()`。
- [x] 3.2 确认 UEPrepare finalize、`UESetProject`、`UESetPlatform` 都会清理 context/freshness 状态并重置 probe cache。
- [x] 3.3 确认 `cache_paths(engine_root, platform_key)` 仅让 grep-facing 工件按平台/配置分路径，非 grep 工件保持原位置。
- [x] 3.4 确认旧单一路径 csearch/gtags 缓存迁移逻辑幂等且不覆盖已有平台缓存。
- [x] 3.5 确认 project 或 engine switch 会 invalidates 所有平台的 project-scoped grep caches 与 cdb shards。
- [x] 3.6 确认无 csearch index 且无 cached file list 时，fallback WARN 与 picker 标题都明确说明 slow fallback 可能漏文件。

## 4. 回归测试与文档

- [x] 4.1 扩展 `tests/cases/grep_cache_spec.lua` 覆盖平台路径、旧缓存迁移、engine_root 持久化、probe reset 和 fallback 标题/提示。
- [x] 4.2 必要时扩展 `tests/cases/utils_spec.lua`，覆盖 `utils.code_search` probing 与 stream 回调顺序。
- [x] 4.3 更新 `docs/changelog.md` Unreleased 条目，写明修改文件、风险和验证范围。
- [x] 4.4 如实现与现有说明有偏差，同步 `docs/architecture/grep-cache-invalidation.md` 与 `docs/CONSTRAINTS.md` 中 K26/K27 摘要。

## 5. 验证

- [x] 5.1 运行聚焦回归：`nvim --headless -l tests/run.lua grep_cache`。
- [x] 5.2 运行相关范围回归：`nvim --headless -l tests/run.lua utils`。
- [x] 5.3 运行全量回归：`nvim --headless -l tests/run.lua`。
- [x] 5.4 手动或诊断验证 `<leader>/` 在有 csearch、有 rg cached file list、无缓存 slow fallback 三种状态下标题和结果路径正确。
