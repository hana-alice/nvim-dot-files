## ADDED Requirements

### Requirement: derived CDB 必须保留 active command 的编译语义

full/current/hot 生成器 SHALL 只消费当前 active argv 明确引用且可验证的编译输入，MUST NOT 从源码路径猜测其他 target/platform/configuration 的 response、Definitions 或 UHT include。不能证明兼容时 SHALL 保留 exact command 或明确失败，不得把混合上下文作为 ready 产物发布。

#### Scenario: Android 与 Win64 Editor 中间产物共存
- **WHEN** active CDB 属于 Android，而磁盘还存在 Win64 Editor 的 response/Definitions/UHT
- **THEN** production default full pipeline SHALL 保留 Android 的语义 argv
- **AND** MUST NOT 注入 Editor 宏或 include 路径

#### Scenario: controlled CDB 显式依赖 Definitions 或 PCH
- **WHEN** active argv 明确引用 Definitions header 或 PCH
- **THEN** controlled Full/current pipeline SHALL 验证该显式文件存在，并保留原 argv 的条件宏与 PCH 语义
- **AND** 文件缺失 SHALL 返回失败且不发布 ready marker；不能用邻近 Editor 文件补齐

#### Scenario: unity response 与 active command 矛盾
- **WHEN** response 的宏、include、target、语言或 PCH 与 active command 不同
- **THEN** unity 证明 SHALL 被拒绝，并使用 exact-command fallback
- **AND** 比较 MAY 忽略仅影响输出位置的参数和规范化后的 source 占位
- **AND** 已验证匹配的语义输入 MUST NOT 在最终 argv 中再次被删除

#### Scenario: 显式响应文件无法完整展开
- **WHEN** active argv 的 response 文件缺失或循环引用
- **THEN** 展开阶段 SHALL 保留整个原始 command，而不能发布部分展开的混合 argv
