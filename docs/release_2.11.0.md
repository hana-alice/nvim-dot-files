# hana-alice/nvim 2.11.0 — 模块优先阶段交付屏障修复

> 版本：2.11.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-23
> 类型：Minor；current/hot/full 分阶段交付屏障对空收据生效、后台激活后按优先级补建、阶段探针。
> 发布流程：按用户授权同步、脱敏归档、提交并推送；tag 待明确请求。

## 1. 本次交付范围

- **空收据不再绕过阶段屏障**：无冻结收据时原子删除 `batches.json`；`batch_metadata.is_ordinary()` 兼容旧空收据，
  current→hot→full 继续等待对应 reader 的 backgroundIndexProgress。
- **后台激活后按优先级补建**：Tier 1 激活改变 live 命令后，按 current→hot 排入已有单 job 队列，异步重建，
  沿用目录复用、宿主准入与 full 单调选择。
- **探针**：`index-phase-barrier` 记录每个阶段屏障的终态与原因；`index-priority-refresh` 记录补建的排队/推迟/跳过/失败。

## 2. 验证与剩余范围

提交前串行全量 `nvim --headless -l tests/run.lua`：**4381/4381 通过、0 失败、2 SKIP**。两项跳过：未提供私有 GTAGS
native 工程输入；当前宿主具备 PCH 能力而不适用的不支持场景。归档写入后另跑 `structure`。

本版**未宣称**渲染等模块已优先完成索引，也未宣称全工程索引性能变化：真实工程首次索引耗时、CPU/内存未实测。
阶段内 clangd 的执行顺序仍不受控，已记为长期优化项，见 `cpp-semantic-index-coverage` spec「选型与踩坑」
末条（包括 shuffle、SeenKeys 阻止重排，以及切模块的两类场景）。

公开文档只保留通用结构与测量数值；工程路径、工作站身份与原始实验产物保留于本地。

## 3. 本次工作归档

### 2026-10-23 — 修复模块优先阶段的交付屏障与 Tier 1 身份复用

**Task**
- 使 current/hot/full 的模块优先交付生效，并保留已有 SuperUnity 二次合并。

**Implemented**
- `lua/ue/index/_publish.lua` 无冻结收据时原子删除 `batches.json`，删除失败返回错误；发布缓存纳入批次元数据签名。
- `lua/ue/index/batch_metadata.lua` 的 `is_ordinary()` 与 `_phase_barrier.lua` 兼容旧空收据，继续等待对应 reader 的 backgroundIndexProgress begin/end。
- `lua/ue/index/_batch_background.lua` 在成功激活改变 live 命令后，消费旧 timer 并按 current→hot 排入已有单 job 队列；释放发布锁后异步重建，沿用目录复用、宿主准入与 full 单调选择。

- 探针（只记录不通知，`:UEProbeReport` 查看）：`index-phase-barrier` 记录每个阶段屏障的终态与原因（indexed / timeout / bypassed:* ），以及 full 在 hot 未完成时发布的 `full:unordered:<原因>`；`index-priority-refresh` 记录后台激活后 current/hot 补建的排队、推迟、跳过与激活失败。

**Pitfalls / Gotchas**
- 文件存在不等于存在冻结批次；非空或损坏元数据仍按保守路径处理。
- collector 调用发布回调时仍持 writer lease，不能同步启动构建；两个独立 timer 也不能保证准入推迟时的 current→hot 顺序。
- 首次资格队列由 full 完成路径启动，等待目录后再交付首阶段会冲突于既有调度依赖。

**Validation**
- 测试先红后绿：空收据屏障 25/26→26/26，发布 132/136→136/136，后台刷新初始 3/6，补充元数据范围用例 6/7，最终 7/7。
- plan/receipt/collect/catalog/reuse_completed 串联夹具确认同组 main/argv/cwd 相同、重复复用零新资格且 catalog/live 字节与 mtime 不变；该夹具显式注入 native 资格 gate，不能代替真实工程验收。
- AST bare-global lint：4 文件通过；`git diff --check` 通过。
- 按指定顺序执行 11 个窄回归，655/655 通过、零失败/跳过：`index_delivery` 149、`index_generation` 46、`cpp_semantic_index` 1、`index_batch_publication` 136、`index_batch_runtime` 85、`index_batch_recovery` 20、`index_batch_activation` 9、`index_batch_background` 102、`index_subset_async` 11、`ue_config` 11、`structure` 85。`_build.lua` 保持 799 行。
- 探针追加后：`index_delivery` 150、`index_batch_background` 103、`index_batch_publication` 136、`index_generation` 46、`structure` 85 全部通过。

**Follow-ups**
- 真实工程缓存与用户 nvim/clangd 未触碰；新代码须在后续会话加载并正常 prepare 才生效。实际首次索引完成时间、CPU/内存与全工程收益仍待独立实测。
