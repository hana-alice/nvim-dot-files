## MODIFIED Requirements

### Requirement: picker 与 Git sidebar 保留真实交互语义

picker 跳转完成后用户有意进行的光标移动 SHALL 被保留，MUST NOT 用通用 CursorMoved 回拉保护撤销正常输入。原 Git sidebar 入口 SHALL 转入统一完整文件审阅，不再维护独立的 Git 状态视图；Git 文件导航 SHALL 保留原始路径及 rename/copy 语义，不把展示用引号或转义作为真实文件名。消费 porcelain 输出的路径 SHALL 使用 NUL 分隔记录。

#### Scenario: picker 跳转后立即向下移动
- **WHEN** Neovide picker 跳转完成后用户在 500 ms 内按 j
- **THEN** 光标 SHALL 保持用户移动后的行，不被跳转保护拉回

#### Scenario: Git 文件名包含空格、中文或发生重命名
- **WHEN** Git 导航返回特殊字符路径或 rename/copy 记录
- **THEN** 统一审阅 SHALL 打开准确的目标文件并正确标识比较双方
- **AND** 不 trim 文件名、不残留展示引号、不把原路径单独解析为状态项

#### Scenario: 原侧栏入口迁移
- **WHEN** 用户触发原 Git sidebar 快捷入口
- **THEN** 聚焦或打开统一 Git 审阅，而非创建第二个状态视图
- **AND** buffers、symbols、diagnostics、quickfix、loclist、TODO 侧栏保持可用
