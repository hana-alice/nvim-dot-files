## ADDED Requirements

### Requirement: Visual 替换必须消费当前选择并正确定位替换文本

Visual 替换 SHALL 从当前 Visual anchor、cursor 与 selection type 捕获文本和行范围，不能依赖上一次完成选择的 marks。进入替换命令后插入点 SHALL 位于 replacement 字段。

#### Scenario: 首次与后续不同选区
- **WHEN** 用户首次选择文本或改变选区后执行 Visual replace
- **THEN** SHALL 使用本次选区，不抛无效行号错误、不使用旧选区
- **AND** 输入 replacement 后执行 SHALL 替换所选文本，不修改搜索 pattern
