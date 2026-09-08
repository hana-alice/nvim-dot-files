## ADDED Requirements

### Requirement: 工具链安装保持显式

Mason 与 mason-lspconfig 的继承安装列表 SHALL 清空，已配置 LSP server SHALL 使用外部工具链而非触发自动安装；手动 Mason 操作 MAY 保留。

#### Scenario: 全新插件数据目录启动
- **WHEN** LazyVim 默认包含 formatter 或 LSP 自动安装项
- **THEN** 本仓配置 SHALL 阻止这些自动安装，并保留已有 server 的启用/禁用选择
- **AND** 不因为缺少某工具而在编辑器启动时下载替代版本

### Requirement: picker 与 Git sidebar 保留真实交互语义

picker 跳转完成后用户有意进行的光标移动 SHALL 被保留，MUST NOT 用通用 CursorMoved 回拉保护撤销正常输入。Git sidebar SHALL 消费 NUL 分隔的 porcelain 原始路径及 rename/copy 记录，不把展示用引号或转义作为真实文件名。

#### Scenario: picker 跳转后立即向下移动
- **WHEN** Neovide picker 跳转完成后用户在 500 ms 内按 j
- **THEN** 光标 SHALL 保持用户移动后的行，不被跳转保护拉回

#### Scenario: Git 文件名包含空格、中文或发生重命名
- **WHEN** Git porcelain -z 返回特殊字符路径或双路径 rename/copy 记录
- **THEN** sidebar SHALL 打开准确的目标文件
- **AND** 不 trim 文件名、不残留展示引号、不把原路径单独解析为状态项
