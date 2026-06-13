## Context

`<leader>/` 通过 `lua/plugins/snacks.lua` 的 `ue_project_grep` 调用 `require("ue").cached_grep()`，健康路径应优先使用 csearch index；无 csearch index 但有 cached file list 时走 rg；两者都不可用时才回落到 `snacks.picker.grep` 的目录遍历。

当前未修好的问题有两个层面：一是 csearch/rg backend 的流式交付可能让 `on_done` 先于尾部 `on_line` 被 picker drain loop 观察到，导致最后若干命中滞留；二是索引/文件列表状态变化后缓存没有可靠失效，`cached_grep` 可能静默返回 nil，让 `<leader>/` 呈现一个会漏 ThirdParty/索引外文件的慢速 fallback。

约束：
- 不引入 telescope 或新 picker 抽象，继续复用 snacks.picker。
- 不引入新依赖。
- 搜索、索引和 prepare 流程必须保持 async，不阻塞 UI 线程。
- fallback 必须可见，但不得做周期性 ticker 通知。
- 改动涉及 `lua/ue.lua`、`lua/utils/code_search/init.lua`、`lua/plugins/snacks.lua` 和回归测试，完成时必须更新 changelog 并跑匹配回归。

## Goals / Non-Goals

**Goals:**
- 保证 csearch/rg backend 在 `on_done` 前交付所有已解析命中，避免 `<leader>/` 丢尾部结果。
- 避免冷启动或 UEPrepare 重建期的一次 csearch/cindex 探测失败污染整会话。
- 让 csearch index、gtags file list、workspace_all file list 按平台/配置隔离，切平台不复用旧平台 grep 缓存。
- 在没有完整索引或 cached file list 时清楚标记 slow fallback，并给一次性 WARN。
- 用 headless 测试锁住路径推导、迁移、探测重置、流式完成顺序和 fallback 标题/提示行为。

**Non-Goals:**
- 不改变 `<leader>/` 键位、用户命令名称或 snacks picker 外部 API。
- 不重写 `cached_grep` 为新的搜索框架。
- 不改变 csearch/cindex 工具链安装方式。
- 不试图让最底层 `snacks.picker.grep` fallback 覆盖与 csearch 相同的完整文件集合；该路径只作为可见降级。

## Decisions

### D1：用单一 flusher 串行化 `on_line` 与 `on_done`

`stream_csearch` 和 `stream_rg` 在 stdout read callback 中同步解析命中，追加到 backend 内部 `parsed` 队列；只通过一个 scheduled flusher 交付 `callbacks.on_line`。exit callback 只记录进程退出状态并请求最终 flush。flusher 每次先 drain 完所有未交付命中，只有在进程已退出且 backlog 为空时才调用 `callbacks.on_done`。

替代方案：继续 per-line `vim.schedule(on_line)`，只延迟 `on_done` 一个 tick。拒绝原因是 libuv stdout data 与 exit callback、以及多个 scheduled callback 的相对顺序仍没有足够强的契约，不能证明尾部命中一定先于 done 被消费。

### D2：工具探测只缓存成功路径

`csearch_exe()` 与 `cindex_uefilter_exe()` 只在找到可执行文件时缓存路径；探测失败返回 nil，不设置“已探测失败”的会话级标记。新增 `_reset_probe_cache()`，由 UEPrepare 完成、项目切换、平台切换和测试调用。

替代方案：保留负缓存并缩短 TTL。拒绝原因是 cold GUI start 与索引重建期失败的恢复点明确，直接允许下次重探更简单，也避免引入定时器或额外状态。

### D3：grep-facing 缓存按平台/配置分路径

`cache_paths(engine_root, platform_key)` 支持为 csearch index、gtags workspace DB、`project.files`、`engine.files`、`workspace.files`、`workspace_all.files` 生成 `csearch/<platform_key>/...` 与 `gtags/<platform_key>/...` 路径。`platform_key` 由 state 的 `target_platform` 与 `target_configuration` 推导，空 key 回落旧单一路径。

只有 grep-facing 工件分平台；`state.json`、cdb 顶层结构、clangd index、pch、logs、runtime 继续保持现有位置。旧单一路径缓存通过幂等迁移移动到当前平台目录，新目录已有文件时不覆盖。

替代方案：平台切换时删除并重建所有 grep 缓存。拒绝原因是 Android/Win64 往返开发会产生不必要的重建成本，也违背 cdb shard 已采用的保留多平台缓存模型。

### D4：fallback 可见且只警告一次

`cached_grep` 在无 csearch index 且无 cached file list、即将返回 nil 给 `ue_project_grep` 时，发一次性 WARN，说明当前会走可能漏文件的 slow directory walk 并提示运行 `:UEPrepare`。`ue_project_grep` 的 fallback picker 标题使用 `Grep All Code (slow fallback - run :UEPrepare)`，让用户从 UI 上能分辨它不是完整索引路径。

替代方案：fallback 直接失败，不打开 picker。拒绝原因是用户仍可能需要临时搜索当前工作区；显式降级比硬失败更实用。

## Risks / Trade-offs

- [Risk] 单一 flusher 持有 `parsed` 队列，在超大搜索结果下比逐行 schedule 保留更多 Lua table 状态。→ Mitigation：继续遵守 `max_count`，并保持 streaming flush，队列只保留当前搜索的已解析命中。
- [Risk] 平台分路径改变 cache layout，可能让旧索引短期不可见。→ Mitigation：`platform_key == ""` 时完全兼容旧路径；首次有 key 时执行 move-once 迁移；新目录已有索引时不覆盖。
- [Risk] fallback WARN 可能打扰用户。→ Mitigation：按 buffer 一次性去重，不做 ticker；标题也作为轻量长期信号。
- [Risk] 仅 headless 测试难以完整模拟 GUI picker drain。→ Mitigation：测试 backend 回调顺序和 `cached_grep` 决策契约；必要时保留临时诊断日志到验证完成后再移除。

## Migration Plan

1. 保留用户已有改动方向，先移除或收敛临时 `DIAG v2` 日志，只留下必要的可测试逻辑。
2. 完成 csearch/rg single-flusher 实现，并补测试证明 `on_done` 后没有未交付命中。
3. 完成 probe cache reset、平台分路径、旧缓存迁移和 fallback 可见化。
4. 更新 `docs/changelog.md`，必要时同步 `docs/architecture/grep-cache-invalidation.md` 与 `docs/CONSTRAINTS.md`。
5. 运行匹配回归；由于涉及 `ue.lua`、`code_search`、`snacks` 和 tests，最终运行 `nvim --headless -l tests/run.lua`。
