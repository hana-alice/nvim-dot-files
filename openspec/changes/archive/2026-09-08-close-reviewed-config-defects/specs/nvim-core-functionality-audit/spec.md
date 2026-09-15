## MODIFIED Requirements

### Requirement: 审计必须验证真实配置启动和最小编辑事务

MUST：系统必须以真实配置启动隔离 Neovim 进程，并在临时目录完成 create/open/edit/write/reopen；不得仅以 Lua module 可 require 代替启动和编辑证据。

#### Scenario: 配置完整启动

- **WHEN** runner 执行 deterministic startup probe
- **THEN** 必须加载实际 init 和启动阶段 critical plugin specs
- **AND** 必须捕获 Lua error、命令冲突和启动退出码
- **AND** 不得自动安装或更新 plugin

#### Scenario: 只读启动缺少 lazy.nvim
- **WHEN** health startup 的既有数据目录没有 lazy.nvim
- **THEN** SHALL 明确报告缺失依赖并退出该启动检查
- **AND** MUST NOT 执行 git clone、等待交互输入或安装插件

#### Scenario: 最小文件编辑

- **WHEN** runner 在已验证的临时目录创建测试文件
- **THEN** 必须验证写入、重开、内容、filetype、关键 option 与 autocmd 结果
- **AND** 必须在结束时删除 runner 创建的文件和目录
