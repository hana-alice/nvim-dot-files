# Design — macOS Unreal semantics and search recovery

## Context

语义准确性由两类外部事实决定：clangd 必须消费当前工程/tuple 的受控 CDB，搜索增量 merge
必须精确知道哪些文件替换旧索引。Apple no-rsp 情况下可以从 active CDB 取得 compiler-authored
argv，但只有完全一致的编译上下文才允许共用一个 wrapper。任何从目录、文件名或 flag 并集推导
语义的做法都会把性能优化变成静默错误。

## Decisions

### 1. LSP root 解析后再选择 CDB

clangd `cmd` 使用 root-aware factory，按 canonical project bucket 选择 active controlled CDB。
启动时保存 resolved argv，exact-command transport 不再读取静态函数或配置仓库根的旧路径。

### 2. CDB 在边界处归一化为 arguments

受控 Python 工具共享 command parser，分别遵守 POSIX 与 Windows command-line 语义。后续工具
只处理 argv 数组，不把字符串拆开后重新猜引号。

### 3. Apple no-rsp grouping 是严格等价证明

group admission 要求 member 唯一映射、相同 cwd、相同 normalized semantic context，以及 Apple
target 或 SDK/sysroot 证据。重写仅替换原 source 并删除对象/依赖写出 flags；PCH、target、arch、
sysroot、defines、includes 全部保留。不能证明即 exact per-file fallback。

### 4. cindex add 只 shadow exact delta files

upstream merge 用 staged Paths 作为替换前缀。空 Paths 会 panic，workspace root 又会删除未列入
delta 的旧 Names。因此 add 的 Paths 必须恰好是去重后的清单文件；reset 才记录显式 roots。
删除仍升级为 reset，因为 add 无法表达已消失文件的内容。

### 5. sidecar timeout 回收整个进程

libclang native parse 期间 sidecar 无法读取 cancel。host deadline 到期后只移除 pending entry 不足以
恢复服务，因此回收进程并结构化完成失败；下一请求沿已有 process manager 冷启动。

## Risks / Trade-offs

- 严格 Apple context equality 会牺牲一部分压缩率，但保持编译语义正确。
- sidecar timeout 会丢弃该进程的 warm TU cache，但比无限占用 CPU 和永久排队可恢复。
- 增量删除仍需 reset；这是 cindex merge 表达能力的保守边界。
- Go 工具发现支持多路径，但只缓存成功结果，避免 session 内首次缺失成为永久失败。

## Privacy

文档、测试夹具、日志与提交只使用临时目录、抽象 workspace 和公开工具名；不记录真实用户目录、
工程名、公司域名、设备/签名身份、访问令牌或凭据。
