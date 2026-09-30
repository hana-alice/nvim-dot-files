## Why

prepare 后首次冻结激活把约 33k 个保留 TU 冷重建进独立 `verified/.cache`：实测 1713.6 s wall /
12,937 CPU s / 11.9 GB 峰值。保留命令与原命令逐字节相同（activation coverage 已证明），
而 clangd 22 按源路径寻址 shard、只按内容 digest 判过期，原缓存 shard 对这些 TU 直接有效。

## What Changes

- 新增 `tools/clangd_shard_seed.py` 与 `lua/ue/index/batch_shard_seed.lua`：冻结缓存无 `*.idx`
  且原缓存有 shard 时，于 watch probe 之前 add-only 硬链接（跨卷回落独占复制）缺失 shard。
- `batch_runtime` 在 `prepare_local_cache` 之后调用播种；结果不授予也不撤销冻结权威。
- spec `cpp-semantic-index-coverage` 的冻结激活 requirement 新增播种场景。

## Impact

- 隔离副本冻结 CDB 索引：冷缓存 1713.6 s → 播种后 42.3 s；另一轮 headless prepare 播种后因 receipt 失效回落，随后独立启动 clangd 测得 54.2 s。两者均不是有效 receipt 下的完整激活→切换→索引验收，剩余项见 tasks 2.4。
- 不改变原缓存、原 CDB 权威、receipt 校验与回落路径。
