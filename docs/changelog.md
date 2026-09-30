# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)
- `v1.9.0` → `docs/release_1.9.0.md` (tag pending explicit confirmation)

- `v1.9.1` → `docs/release_1.9.1.md` (tag pending explicit confirmation)
- `v1.9.2` → `docs/release_1.9.2.md` (tag pending explicit confirmation)
- `v1.9.3` → `docs/release_1.9.3.md` (tag pending explicit confirmation)
- `v1.10.0` → `docs/release_1.10.0.md` (tag pending explicit confirmation)
- `v1.11.0` → `docs/release_1.11.0.md` (tag pending explicit confirmation)
- `v1.11.1` → `docs/release_1.11.1.md` (tag pending explicit confirmation)
- `v1.11.2` → `docs/release_1.11.2.md` (tag pending explicit confirmation)

- `v1.11.3` → `docs/release_1.11.3.md` (tag pending explicit confirmation)

- `v1.12.0` → [docs/release_1.12.0.md](release_1.12.0.md) (incremental scope; tag pending)
- `v1.12.1` → [docs/release_1.12.1.md](release_1.12.1.md) (tag pending)
- `v1.12.2` → [docs/release_1.12.2.md](release_1.12.2.md) (diagnostic stage; tag pending)
- `v1.12.3` → [docs/release_1.12.3.md](release_1.12.3.md) (demand-driven recovery; tag pending)
- `v1.12.4` → [docs/release_1.12.4.md](release_1.12.4.md) (native junction verification; later ancestor-event fallback recorded; tag pending)
- `v1.12.5` → [docs/release_1.12.5.md](release_1.12.5.md) (stable directory writes and complete ancestor watches; tag pending)
- `v1.12.6` → [docs/release_1.12.6.md](release_1.12.6.md) (modified-document preflight and clean demand recovery; tag pending)
- `v1.12.7` → [docs/release_1.12.7.md](release_1.12.7.md) (automatic clean-document recovery; tag pending)
- `v1.12.8` → [docs/release_1.12.8.md](release_1.12.8.md) (padded search query cancellation; tag pending)
- `v1.12.9` → [docs/release_1.12.9.md](release_1.12.9.md) (durable search overflow recovery; tag pending)
- `v1.12.10` → [docs/release_1.12.10.md](release_1.12.10.md) (second qualified SuperUnity batch; tag pending)
- `v1.12.11` → [docs/release_1.12.11.md](release_1.12.11.md) (retain document-blocked original readers; tag pending)

- `v2.0.0` → [docs/release_2.0.0.md](release_2.0.0.md) (CodeDiff default review; Diffview retained; tag pending)

## Unreleased

### 2026-09-30 — 更正 shard 播种验收范围并复核发布脱敏

**Task**
- 接力已提交并推送的 shard 播种改动，复核 spec 同步、归档与公开内容。

**Implemented**
- 在 `docs/cpp-index-restart-investigation.md` 更正 42.3 s / 54.2 s 的实测范围，并同步主 spec、归档 delta、proposal 与 tasks。
- 保留归档任务 2.4 未完成；副本索引不再表述为成功的线上激活或完整端到端验收。

**Pitfalls / Gotchas**
- 前次提交的 Tested 摘要过宽；详细证据是 prepare 校验失败后另行启动 clangd 索引。本次追加更正，不改写已发布历史。

**Validation**
- 前次提交的元数据、路径和全部新增内容通过专属 denylist 与通用敏感信息扫描。
- Spec 一致性：主 spec 与已归档 delta 同步更正，15 个 scenario 保持一致；主 spec 严格校验与暂存差异检查通过，未改变运行时行为。
- 首次 required-native 全量为 2338/2341，失败涉及多实例缓存刷新、探针重试与 native watcher 就绪。独立复测分别通过 27/27、10/10、15/15；watcher 的原始断言和生产时限未改动。
- 同一原生 helper 的一次配对测量：默认 Python 3.12 启动到 ready 为 9044 ms，已安装 Python 3.14 为 125 ms；后续 Python 3.14 运行也曾超时，因此不能将波动全部归因于版本。测试进程使用现有 `UE_PYTHON` 显式选择真实 Python 3.14，未伪造工具或改变用户会话配置。
- 最终完整回归 **2341/2341 passed，0 failed、0 skipped**：设置进程内 `NVIM_TEST_REQUIRE_NATIVE=1` 与 `UE_PYTHON` 指向已安装的 Python 3.14 后运行 `nvim --headless -l tests/run.lua`。复测通过不代表上述时限波动已修复。

**Follow-ups**
- 有效 receipt 下的完整激活链路、header shard 差异归因及更大范围 SuperUnity 验收仍未完成。
- 本轮异步测试与 helper 就绪时限波动的根因尚未闭环；保留为既存验证稳定性问题，不宣称由文档更正修复。

### 2026-09-29 — 冻结 shard 缓存从原缓存 add-only 播种

**Task**
- 让 prepare 后首次冻结激活不再把约 33k 个保留 TU 冷重建进独立 shard 缓存。

**Implemented**
- 新增 `tools/clangd_shard_seed.py`：仅添加目标缺失的 `*.idx`（硬链接，跨卷回落 exclusive-create 复制；跳过 `.temp-stream-`；失败删除半截副本；拒绝同目录/缺失目标）。
- 新增 `lua/ue/index/batch_shard_seed.lua`，并在 `batch_runtime` 的本地缓存创建之后、watch probe 之前异步播种；结果不影响冻结权威，失败按冷缓存继续。
- spec `cpp-semantic-index-coverage` 新增场景 "A new frozen shard cache is seeded from the original cache"。
- 调查记录见 `docs/cpp-index-restart-investigation.md` 2026-09-29 节（含 priority A/B 假设被证伪的更正）。

**Pitfalls / Gotchas**
- clangd 22 shard 按源路径寻址、只按内容 digest 判过期、以 temp+rename 写回——这三点是播种安全且有效的前提（源码已核对）。
- header shard 在播种/冷建间存在 refs/relations 差异，归因于写入者非确定性，为推测、待闭环。

**Validation**
- 实测（Android target 隔离副本）：冻结 CDB 冷索引 1713.6 s / 12,937 CPU s → 播种后索引 42.3 s / 47.9 CPU s（重索引 4 个 TU，其中 2 个为 batch TU）。
- Headless prepare（真实 `batch_runtime.prepare`，隔离副本）：播种 linked 37,339、11.8 s；冻结校验因 receipt inventory（某插件 Win64 Editor Intermediate 目录 9/28 新增文件）返回 `receipt-input-or-asset-changed`，正确回落原 CDB。随后独立启动 clangd，在播种后的 verified 目录索引 54.2 s / 56.4 CPU s / 5.35 GB、4 TU、0 失败；该数字不是成功激活的端到端耗时。未验证 live 是否同样失效（推测是）。
- `NVIM_TEST_REQUIRE_NATIVE=1` filters：index_batch_runtime 80/80、index_batch 201/201、index_generation 35/35、cpp_semantic_index 1/1、clangd_commands 10/10、ue_api 65/65、index_graph 12/12、index_verified_batch 27/27、index_vfs_aliases 5/5、index_input_directory 4/4、index_inventory 18/18、cpp_semantic_client 33/33、host_resource_discipline 13/13、stability 26/26。
- 单独跑 `index_query_profile` filter 时报 native coverage unavailable（skip 条件 clangd/python 未解析被触发），全量套件中同一用例通过；推测全量里其他用例设置了 `UE_CLANGD`，未验证；本改动未触及该路径。
- 全量 `NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`：2341/2341 passed。
- spec 一致性：以 change `2026-09-29-seed-frozen-shard-cache` 承载并已归档，同步 `openspec/specs/cpp-semantic-index-coverage/spec.md`；知识库同步 architecture overview / project_overview / `lua/ue/index/AGENTS.md` / tests 映射（新增 `index_batch_runtime`）。

**Follow-ups**
- wrapper 命令变更导致新 TU 路径全量重索引；冻结失效源（仓库 `.omx` receipts）迁出；更多真实 L1 二次合并。

### 2026-09-29 — 归档统一 Git 审阅 change

**Task**
- 按用户指令完成 CodeDiff 工作的 spec 同步核对、归档与提交推送流程。

**Implemented**
- 将完整 change 移至 `openspec/changes/archive/2026-09-29-unify-git-review-with-codediff/`，保留 21 项任务及交付证据。
- 更新 `docs/release_2.0.0.md` 的归档路径和授权状态。

**Pitfalls / Gotchas**
- 其他 SuperUnity change 保留原状；tag 未包含在本次授权中。

**Validation**
- Spec 一致性：三个主规格与 delta 的 10 个 requirement 块逐段一致；change 与三个主规格严格校验通过。
- 归档后提交前 required-native 全量复验 **2338/2338**，0 failed、0 skipped；命令为 `NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`。
- 21 个相关 Lua 文件通过 AST lint；暂存差异通过 `git diff --cached --check`。

**Follow-ups**
- 跨平台和 GUI 验证边界沿用 [v2.0.0 交付记录](release_2.0.0.md)。

Original-reader retention and its acceptance limits are
archived in [v1.12.11](release_1.12.11.md). Broader compression, whole-engine index
performance and search responsiveness remain open.
