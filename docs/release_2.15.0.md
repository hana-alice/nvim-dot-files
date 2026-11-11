# hana-alice/nvim 2.15.0 — 离线前缀 PCH 索引提速：冷全量稳定低于 300 s

> Minor；用户 2026-11-11 授权 sync / archive / commit / push，脱敏归档，不创建 tag。

## 新能力与调整

- **离线索引默认开启 4 个 fork 开关**（`tools/clangd_pch_offline.py`）：FILTER_NATIVE_PATH、THIN_NOLOAD、SKIP_INDEX_REBUILD、VFS_OVERLAY_CACHE。私有 clangd 没有对应 hook 时忽略这些变量。每个都可以用 `PCH_OFFLINE_<名字>=0` 关闭。
- **并行与调度**：
  - PCH producer 一次性提交（produce_all）。
  - Tier 1 prepare/commit 用 4 线程。
  - paired / ordinary lane 并行，`PCH_OFFLINE_SERIAL_LANES=1` 恢复串行（A/B 开关）。
  - lane 内 didOpen 后立即 didClose，`PCH_OFFLINE_KEEP_OPEN=1` 恢复旧行为。
- **失败索引计入编译失败**：PCH 被拒时只有 `Indexing X failed`，没有 `Failed to compile`。这类 TU 现在也计入 `compile_failure_tus`，按编译失败处理。
- **实验开关，默认关**：
  - `PCH_OFFLINE_FOLD_RETRY=1`：Tier 1 失败行并入 paired。修复了"折叠行成员 shard 未发布"的 bug，但两对 A/B 都更慢，所以不采用。
  - `PCH_OFFLINE_SPECULATE=1`：投机 producer，全量 CPU 增加 19%，判为负收益。
  - `PCH_OFFLINE_MERGE_SEPARATORS=1`：按路径分隔符合并上下文，全量输出差异超出噪声，已撤回为 opt-in。
- **默认私有 bin** 从 `metadata-v21` 改为 `metadata-v24c`（`ue.config` 的 `index.pch_offline.bin_dir`）。下文的计时用的是更新的私有构建（v26：PGO + ThinLTO + rpmalloc + overlay 解析缓存）。要用它，需在本机配置里把 `bin_dir` 指向该构建。私有二进制不进公开仓。
- **README 中英文**：
  - 去掉没有当前实测支撑的"约 3 分钟全量索引"说法，换成可复现的冷全量数字。
  - 更新知识库计数。
  - 新增"优化清单"。

## 实测范围与结论

- 全量回归 `nvim --headless -l tests/run.lua`：**4485 通过，0 失败，2 个显式跳过**。py 单测 42/42。
- **冷全量（离线工具墙钟，同一大型 UE 工程，安静宿主）**：
  - 基线 1261 s，依次降到 830、545、510、357 s，最后到 253–293 s。
  - 预登记判据是"一批 3 次的中位数 ≤ 300 s"，连续 7 批达标，中位数 254.9–294.7 s。
  - 磁盘清理后共 15 次，15/15 ≤ 300 s，中位数 267.7 s。
  - 正确性门禁每次都过：ok、回落 0、mismatch 0。
- **不宣称的部分**：
  - 同机有大量外部 clangd/python 负载时仍是 370–430 s。工具 worker 以 IDLE 优先级运行，会让出 CPU。
  - "磁盘接近满会拖慢索引"只有时间上的相关，没有对照实验，**待验证**。
  - nvim 内端到端（plan → 工具 → collect 发布）没有在本版本重新计时。

## 归档记录

### 2026-11-11 — R50 离线索引提速收尾、README 刷新

**Task**
- 冷全量从 357 s 压到 300 s 以下，并在安静宿主上稳定复现。
- README 去掉失效的部分，补上优化清单。

**Implemented**
- `tools/clangd_pch_offline.py`：
  - 新增上述开关与并行 lane。
  - 新增 `fold_kept_shards`：干净的折叠行除了自身 shard，还保留它直接包含的成员 shard。
  - fold 的 covered 与 retry lane 的 covered 取并集。
  - 失败索引行计入 `compile_failure_tus`。
  - report 先写临时文件再改名。
- `tools/pch_offline_tier1.py`：prepare/commit 用 4 线程，结果保持计划顺序，报告不变。
- `tests/py/test_clangd_pch_offline.py`：新增分隔符上下文、失败索引计数、fold 成员 shard 三组用例。
- `lua/ue/config.lua`、`lua/ue/index/pch_offline.lua`、`tests/cases/index_pch_offline_spec.lua`：默认 bin 改为 `metadata-v24c`。
- `README.md`、`docs/README.zh-CN.md`：刷新基准、计数和优化清单。

**Pitfalls / Gotchas**
- 外部负载是主要噪声源。宿主 CPU 计数器把我们自己的 worker 也算进去了，区分不了外部负载。改为在每次运行期间单独累计外部 clangd/python 的 CPU 秒，并加了起跑门禁：宿主 ≤ 25%，外部 < 0.5 核。
- **已证伪**："只要有用户的离线索引在跑就慢"。真正决定快慢的是外部进程实际消耗的 CPU 量。
- 实验 scratch 曾经写满数据盘，导致一次运行 `Errno 28`，该次结果作废。之后每次运行前检查剩余空间，运行结束后清理 scratch。
- EcoQoS 在这个 clangd 构建里是被编译掉的（`_WIN32_WINNT 0x0601`），background 和 low 等价。

**Validation**
- `python -B -I tests/py/test_clangd_pch_offline.py`：42/42。
- 全量回归 4485/4485，2 个显式跳过；文档改动后 `structure` 85/85。
- 冷全量：7 批达标（见上文），每次的数据都在私有研究记录里。

### 2026-10-26 — Use double brackets for review hunk navigation（从 Unreleased 归档）

- `lua/plugins/codediff.lua`：CodeDiff 的 `prev_hunk` / `next_hunk` 改为 `[[` / `]]`，cheatsheet 和用户指南同步更新。
- Validation：`git_review` 77/77、`review_editor` 9/9、`keymaps` 85/85、`cheatsheet` 223/223、`workarounds` 48/48、`smoke` 19/19、`structure` 85/85。

### 2026-10-26 — Sync main while preserving uncommitted workspace fixes（从 Unreleased 归档）

- `git pull --rebase` 快进，恢复本地修改，解决了 3 处冲突。
- 当时的全量回归是在受限环境里跑的，有 175 个失败（路径权限、`ENAMETOOLONG`、clangd 版本门禁）。之后的版本（2.12–2.14）全量回归已全绿，这条遗留问题已关闭。

### 2026-10-03 — Pull/rebase while preserving ordinary C++ workspace fixes（从 Unreleased 归档）

- ownership / toolchain 门禁迁到 `semantic_environment`，普通 C++ 的 LSP-only 策略迁到 `compat_navigation`。主规格合入 `cpp-contextual-definition-navigation`。

### 2026-09-13 — Restore ordinary C++ workspace isolation（从 Unreleased 归档）

- 以 buffer 的 canonical path 和 UE 根目录划定 ownership 边界，非 UE 的 C/C++ 只走 LSP definition。
- 新增有界的 CMake CDB 发现：不递归扫描 vendor 目录。
- Validation：当时全量 1330/1330。
