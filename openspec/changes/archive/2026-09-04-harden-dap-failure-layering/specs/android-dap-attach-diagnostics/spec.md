## ADDED Requirements

### Requirement: 分层定位 SHALL 有可执行判定，不只有文档排查顺序

Android attach 的分层定位 SHALL 除文档排查顺序之外，提供**机器可判定**的逐层结论：
每层给出通过 / 失败 / 不适用，并附带其判定所依据的确切命令与输出。首个失败层 SHALL 被
明确标识为阻塞层。

诊断输出 SHALL 携带层归属；MUST NOT 只给症状文本让读者自行推断层。该判定 SHALL 可在
没有活跃调试会话时运行——历史上的诊断入口需要活会话才能给信息，导致「attach 都起不来」
时恰恰拿不到诊断。

#### Scenario: 无活跃会话也能取得逐层判定

- **WHEN** 用户在没有任何活跃 DAP 会话时请求分层判定
- **THEN** 系统 SHALL 逐层给出判定与 evidence
- **AND** MUST NOT 因为缺少活跃会话而拒绝给出结论

#### Scenario: 判定指认阻塞层

- **WHEN** 某层判定为失败
- **THEN** 该层 SHALL 被标识为阻塞层
- **AND** 其后各层 MAY 标注为未判定
- **AND** 输出 SHALL 给出该层 owner 与下一步动作

#### Scenario: 诊断输出携带层归属

- **WHEN** 诊断报告任何失败或异常
- **THEN** 该条目 SHALL 带明确层归属
- **AND** 层不可判定时 SHALL 显式标注未判定而非猜测
