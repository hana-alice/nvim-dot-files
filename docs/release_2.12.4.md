# hana-alice/nvim 2.12.4 — 大型 CDB 摘要内存修复

> Patch；保持 generation 摘要算法和编译命令身份不变。
> 发布：沿用已授权的脱敏归档、拉取/rebase、提交与推送；不创建 tag。

## 修复

真实准备流程在摘要计算时同时保留原始 JSON、解码元数据、规范化记录和编码结果，导致一个 292 MB CDB 在 2 GiB 进程/Job 限额下失败。现在在最终编码前释放不再需要的输入，并对大型输入执行回收；仍使用原有规范化、SHA、输入身份校验和异步 worker。

同输入、同限额下，修复后的生产 worker 用时 2.68s、峰值 Job commit 1.66 GB，摘要与独立现有 Python 实现一致。真实私有标准 CDB 发布成功；新进程重复发布没有变化，四个 CDB/manifest 文件的字节与时间戳保持一致。这些结果不等于完整 UEPrepare 或日常编辑器接收验收。

## 验证

本次 required-native 全量回归：4419/4419 通过、0 失败、2 SKIP，259 specs。耗时 1133.35s、Job CPU 1066.14s、峰值 Job commit 547.73 MB。866 个代码/测试/工具文件与实测时的字节绑定一致。两项 SKIP 分别是未提供私有 GTAGS 原生证明输入，以及当前宿主具备 PCH 能力、不适用不支持场景。

受影响范围252/252通过，零失败/跳过；异步 worker 单独10/10通过。归档后 `structure` 85/85 通过；改动 Lua 文件语法与 AST bare-global 检查通过。

## 尚未完成

全工程约180秒的冷索引目标、完整暖加载语义，以及普通首次/重复 prepare 和实际 reader 验证仍在推进。最新有效全工程索引阶段结果仍为979.0467s；本补丁修复发布失败，没有宣称新的全工程加速比。私有输入、原始日志及工程路径不进入公开归档。

## 归档记录

### 2026-10-29 — Let large generation digests fit the existing memory budget

**Task**
- Fix a real publication failure where the generation digest worker exhausted its 2 GiB memory budget on a 292 MB compilation database.

**Implemented**
- Release the raw JSON and decoded metadata after canonicalization, then collect unreachable allocations for large inputs before encoding the canonical digest. Preserve the existing normalization, hash, identity checks and asynchronous worker protocol.

**Validation**
- Under the same 2 GiB process/Job limit, phase instrumentation reproduced the original failure during canonical hashing. The fixed production worker completed the same real CDB in 2.68s with 1.66 GB peak Job commit; its digest exactly matched the existing independent Python canonical implementation.
- Required-native affected-scope regression: `index_generation` 46/46, `index_subset_async` 11/11, `cpp_semantic_index` 1/1, `clangd_commands` 23/23, `ue_api` 66/66, `ue_platform_boundary` 20/20 and `structure` 85/85; all zero failures/skips. The asynchronous worker cases also passed independently (10/10). Required-native full regression: 4419/4419 passed, zero failures, two explicit skips (1133.35s, 1066.14s Job CPU).
- Actual private standard publication completed in 3.99s. A fresh-process repeat completed in 4.23s with no publication change; four CDB/manifest artifacts retained exact bytes and filesystem timestamps. This does not establish complete UEPrepare or actual reader delivery.

**Follow-ups**
- Complete ordinary first/repeat preparation and reader verification. The full cold-index target and complete warm semantics remain unaccepted.
