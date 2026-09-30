## Context

冻结 BackgroundIndex 使用独立目录与缓存，首次激活时缓存为空。

## Decisions

- **只增不改**：只添加目标缺失的 shard；`FileExistsError` 跳过；复制失败删除半截文件。
  clangd 以 temp+rename 写回 shard，所以冻结侧重写只替换冻结目录项，不影响硬链接的原文件。
- **时机**：本地缓存目录创建之后、任何 watch/冻结客户端之前，避免播种写入触发输入撤权。
- **权威隔离**：播种失败/超时/helper 缺失均按未播种继续；receipt 校验与 watch 流程不变。

## Risks

- header shard 在播种与冷建之间存在 refs/relations 差异（6,472 个），归因于写入者非确定性，**推测、待闭环**。
- 依赖 clangd 22 的 shard 寻址/过期语义；升级 clangd 需重新核对源码。
