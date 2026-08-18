## ADDED Requirements

### Requirement: Semantic sidecar deadlines SHALL terminate stalled native work

每个 semantic sidecar 请求 SHALL 有明确的 host-side deadline。请求超时后，client SHALL 完成该
请求的结构化失败、清除 pending 状态，并回收仍卡在 native parse 中而无法读取 cancel 的 sidecar
进程；不得让无响应进程继续占用 CPU 或永久阻塞后续导航。下一次请求 SHALL 能按现有 process
manager 冷启动新 sidecar。

#### Scenario: libclang parse 超过请求期限
- **WHEN** sidecar 在 native parse 中超过配置的 request timeout 且无法处理协议 cancel
- **THEN** client SHALL 终止该 sidecar，并以 timeout/provider-unavailable 完成请求
- **AND** pending map SHALL 清空，旧响应不得再产生跳转或状态覆盖

#### Scenario: 超时后的下一次语义请求
- **WHEN** 前一 sidecar 已因超时被回收，用户再次触发语义导航
- **THEN** process manager SHALL 启动新的 sidecar 并接受请求
- **AND** 系统 MUST NOT 因旧进程或旧 pending entry 永久保持 unavailable
