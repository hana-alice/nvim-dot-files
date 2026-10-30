# hana-alice/nvim 2.12.5 — 无缓存时的准备事务收尾

> Patch；沿用已授权的脱敏归档、拉取/rebase、提交与推送，不创建 tag。

## 修复与简化

目标索引缓存和迁移历史都不存在时，先完整校验已有 overlay，再重新确认路径缺失，直接返回不落盘的 no-op。已有缓存、历史、恢复和写入保护继续走原来的流程。改动位于 `lua/workarounds/clangd/header_path_case_cache.py`，没有新增依赖。

`tests/cases/ue_cdb_header_path_case_spec.lua` 新增真实 clangd 存活时的无缓存回归及未知路径/校验期间创建检查。首次全量发现既有监听测试监听了超出其断言范围的工作区父目录；`tests/cases/index_batch_runtime_spec.lua` 现在直接订阅实际测试的 input/cache/log 三个目录，生产撤销规则及另一项真实祖先改名测试保留。

## 实测范围

真实私有准备事务收尾用时17.75s；新进程再次执行完整生成、pipeline、partition、commit、cleanup 用时124.33s，16个被检查的 CDB、receipt、分片和发布文件字节及时间戳均未改变。这证明本次准备链路的重复行为，没有证明普通编辑器已接收索引。重复准备仍有约两分钟成本。

## 尚未完成

普通 reader 交付、完整暖加载语义、扩大真实二次合并范围，以及本机约180秒全工程冷索引目标仍未完成。最近有效全工程测量仍为979.0467s；本补丁没有宣称新的全工程加速。原始私有输入与日志不进入公开归档。

## 归档记录

### 2026-10-29 — Let preparation finish when its owned cache has never existed

**Task**
- Avoid deferring an already committed CDB solely because another clangd is alive when neither the selected cache nor its migration history exists.

**Implemented**
- Validate owned overlays and check path components without following links, then recheck cache/history absence before returning a non-persisted no-op. Existing cache, history, scan, mutation and restore paths retain their writer guards.

**Validation**
- Before the repair, the required-native header-case suite passed 9/11: a real live clangd reproduced the absent-cache deferral, and unknown path-state handling failed the new regression. After the repair it passed 11/11. Affected scopes passed 364/364 with zero failures and one host-capability skip: `ue_cdb` 212, `workarounds` 48, `smoke` 19, `structure` 85.
- The actual retained private transaction committed and cleaned up in 17.75s without changing six active/publication artifacts. A genuine fresh-process raw-generation/pipeline/partition/commit/cleanup repeat took 124.33s, returned `changed=false`, and preserved bytes and timestamps of all sixteen checked CDB, receipt, partition and publication artifacts. Current named source/build inputs were independently revalidated afterward. No cache/history marker was created, and reader activation was not claimed.
- A private filesystem fixture passed eleven groups, including later cache creation, pending backups, real reparse paths and post-validation creation. An initial negative fixture incorrectly hid its intended permission error behind a missing parent; after constructing the actual existing parent, that check passed. Mocked branch checks are not evidence of host writer absence.
- The first new full run passed 4420/4421 with one existing real-watch filtering failure and two skips. Actual event capture reproduced an unclassified input-directory write even without subsequent cache/log writes; a setup delay did not solve it. The filtering fixture now subscribes to its actual input/cache/log directories, while the separate real ancestor-rename test retains workspace-parent coverage. The private candidate passed 80/80 real repetitions without skips; production invalidation rules are unchanged. The corrected runtime scope passed 86/86 with no skips. The second required-native full run passed 4421/4421, zero failures, two explicit skips (1193.62s wall, 1101.41s Job CPU, 543.87 MB peak Job commit). All 866 bound code/test/tool files match the tested bytes.

**Follow-ups**
- Complete ordinary reader delivery; reduce the remaining repeat-prepare cost. Full cold-index performance and complete warm semantics remain unfinished.
