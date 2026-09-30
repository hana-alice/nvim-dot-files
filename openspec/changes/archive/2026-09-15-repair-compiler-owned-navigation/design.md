## Context

必须保留 compiler identity 权威、真实编译输入、异步和请求新鲜度约束。公开报告只保留通用源码 basename、
测量值和可复核的机制，原始机器路径与响应保留在忽略的本地状态目录。

## Goals / Non-Goals

- 目标：修复已证实的错误门禁，并让失败分类与证据一致。
- 非目标：用文本搜索代替 compiler、假装 HOT 等于全引擎覆盖、修复所有 Core 编译/索引错误。

## Decisions

- cold finalize 的实际回调测试锁住交付顺序，不再以全文件调用次数代替行为。
- 删除过早 PCH 注入，仅对相邻文本 include、已有 recipe 和生成器路径共同证明的缺失 binary 做修复。
- source symbolInfo 无跨 TU body 时，用同一 client 的目标 exact AST 验证相同 USR 和 definitionRange。
- 宏遵守 clangd 的 macro-first referent 语义；alias/namespace 用精确位置 AST 与每个 client 自身的唯一目标关联。
- 声明不标为 definition；多 client 缺失/冲突、纯声明、未知角色和过期请求继续拒绝。

## Risks / Trade-offs

- 首次目标 AST 解析可能较慢；保持异步、有界和取消机制。
- `symbolInfo`/AST 属于 clangd 扩展；使用已安装 LLVM 22 的真实矩阵验证。
- 5 个 Core 函数仍有索引缺口，4 个宏展开位置无 canonical USR；见 `docs/cpp-navigation-kind-audit.md`，不计入修复完成。
