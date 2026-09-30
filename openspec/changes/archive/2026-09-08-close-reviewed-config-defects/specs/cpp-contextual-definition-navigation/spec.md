## ADDED Requirements

### Requirement: 精确位置与异步副作用必须绑定不可变请求

LSP 请求 SHALL 按所选 client 的 position encoding 将捕获行文本的字节光标转换为协议位置。self/declaration 过滤 SHALL 比较精确位置或语义范围，MUST NOT 仅以同文件同行否决不同实体。所有结果跳转及 lineage 更新 SHALL 在副作用发生前通过请求和 generation 新鲜度门禁。

#### Scenario: 光标前存在非 ASCII 文本
- **WHEN** 调用位置前有中文或其他多字节字符
- **THEN** UTF-8、UTF-16 或 UTF-32 client SHALL 收到各自编码下的正确位置

#### Scenario: 同一行存在不同 definition
- **WHEN** declaration/reference 与目标 definition 位于同一行的不同位置
- **THEN** 系统 MUST NOT 仅因行号相同把目标当作 self jump 移除

#### Scenario: 取消后的头文件查询晚到
- **WHEN** 旧 header 响应晚于取消、新 lineage 或 generation 切换
- **THEN** 旧响应 SHALL 被拒绝
- **AND** MUST NOT 跳转、清除或覆盖新窗口的 origin lineage

### Requirement: warm sidecar 缓存必须验证已解析文件的新鲜度

warm TU 与 destination cache SHALL 绑定 compiler-authored inclusion 集合及主文件的磁盘签名，除 overlay 和编译命令外也验证已保存内容的新鲜度。签名变化 SHALL 触发 reparse/重新 lookup，不能复用旧 USR 或行号。依赖枚举与检查 SHALL 在 sidecar 执行，不扫描整个项目或阻塞编辑器主线程。

#### Scenario: 保存 source 或已包含的 header
- **WHEN** 两次查询之间 source/header 保存发生变化，而 CDB 与 overlay 集合未变
- **THEN** 下次查询 SHALL 基于重新解析的 TU 返回新实体及位置
- **AND** 缓存 destination MUST NOT 保留旧源码行号
