## ADDED Requirements

### Requirement: 约束文档 SHALL 记录 DAP 归属分层契约与「失败先报层」纪律

`docs/CONSTRAINTS.md` SHALL 在约束小节记录 DAP 五层归属契约（宿主工具链 / 传输 /
目标 OS 策略 / 调试引擎 / 符号语义），每层给出 owner 与判定手段指针，并 SHALL 记录
「任何 DAP 失败必须先指认层再给处置」这条纪律。

该小节 SHALL 说明分层的目的：34 条 DAP 坑中仅少数属本仓代码，多数是外部契约
（目标 OS 策略与调试引擎），分层的作用是让读者一步区分「不是我们能修的」与
「我们的 bug」，而不必每次现场取证。

#### Scenario: 读者查阅约束小节取得分层

- **WHEN** 读者查阅约束小节
- **THEN** 它列出 DAP 五层归属契约与每层 owner
- **AND** 它声明失败先报层的纪律
- **AND** 它指向治理该契约的 capability spec 作为权威出处

#### Scenario: 踩坑条目可按层归类

- **WHEN** 新增一条 DAP 坑
- **THEN** 维护契约 SHALL 要求该条目标注其归属层
- **AND** 标注 SHALL 使读者能判断该坑是外部契约还是本仓缺陷
