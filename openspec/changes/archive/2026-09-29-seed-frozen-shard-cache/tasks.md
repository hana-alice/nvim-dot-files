## 1. 实现

- [x] 1.1 `tools/clangd_shard_seed.py`：add-only 硬链接/独占复制，跳过 `.temp-stream-`，拒绝同目录/缺失目标。
- [x] 1.2 `lua/ue/index/batch_shard_seed.lua` + `batch_runtime` 接入（watch probe 前，失败不影响权威）。
- [x] 1.3 spawn 审计登记（`host_resource_discipline`）。

## 2. 验证

- [x] 2.1 `index_batch_runtime` 新增 3 个用例（播种、跳过条件与 helper 异常、工具只增不改）。
- [x] 2.2 映射 filter 全绿；全量 `nvim --headless -l tests/run.lua` 2341/2341。
- [x] 2.3 离线副本实测 1713.6 s → 42.3 s；headless 真实 prepare 端到端播种 37,339 shard / 11.8 s，随后索引 54.2 s。
- [ ] 2.4 receipt 有效状态下的激活→切换→索引完整链路实测（本次副本 receipt inventory 已失效，回落原 CDB），留作后续。

## 3. 收尾

- [x] 3.1 spec delta、changelog、调查文档、知识库（overview / project_overview / index AGENTS / tests 映射）同步。
