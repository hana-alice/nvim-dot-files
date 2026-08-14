## Purpose

定义一个只读、分层、可机器判定的 Neovim 基本功能健康审计，覆盖真实启动、编辑、Tree-sitter、
csearch/rg、clangd/CDB、UE 集成与异步稳定性，并准确表达外部能力 gate。

## ADDED Requirements

### Requirement: 健康审计必须按 capability 独立报告

系统必须为每个检查生成稳定 id、状态、阶段、耗时、摘要和可行动下一步；不得用单一成功布尔值掩盖部分失败或外部阻塞。

#### Scenario: 基础编辑正常但 clangd 版本不兼容

- **WHEN** 启动、buffer/file 和 Tree-sitter 检查通过，但实际 clangd 不满足 22.1.x
- **THEN** 基础编辑与 syntax capability 必须为 `PASS`
- **AND** compiler semantics 必须为 `BLOCKED`
- **AND** overall 不得声称所有能力端到端通过

#### Scenario: deterministic 必需检查失败

- **WHEN** 完整配置无法启动、临时文件事务损坏或 mandatory parser 无法解析合法 fixture
- **THEN** 对应检查必须为 `FAIL`
- **AND** runner 必须以非零退出码结束

### Requirement: 审计必须验证真实配置启动和最小编辑事务

系统必须以真实配置启动隔离 Neovim 进程，并在临时目录完成 create/open/edit/write/reopen；不得仅以 Lua module 可 require 代替启动和编辑证据。

#### Scenario: 配置完整启动

- **WHEN** runner 执行 deterministic startup probe
- **THEN** 必须加载实际 init 和启动阶段 critical plugin specs
- **AND** 必须捕获 Lua error、命令冲突和启动退出码
- **AND** 不得自动安装或更新 plugin

#### Scenario: 最小文件编辑

- **WHEN** runner 在已验证的临时目录创建测试文件
- **THEN** 必须验证写入、重开、内容、filetype、关键 option 与 autocmd 结果
- **AND** 必须在结束时删除 runner 创建的文件和目录

### Requirement: Tree-sitter 检查必须解析真实语法树

系统必须从配置声明得到 mandatory parser 集合，加载每个真实 parser 并解析合法 fixture；不得只检查 parser 名称出现在配置中。

#### Scenario: C++ parser 正常

- **WHEN** `cpp` parser 已安装并解析合法 C++ fixture
- **THEN** 必须产生预期 root type 和非空 named nodes
- **AND** fixture 覆盖范围不得包含 `ERROR` 或 missing node

#### Scenario: mandatory parser 缺失

- **WHEN** 配置声明的 `c`、`cpp` 或 `hlsl` parser 不可加载
- **THEN** 对应 syntax check 必须为 `FAIL`
- **AND** 报告必须给出显式安装/修复方向
- **AND** 不得在审计过程中执行安装

#### Scenario: clangd 不可用

- **WHEN** Tree-sitter parser 正常但 clangd 或 CDB 不可用
- **THEN** syntax tree 仍必须为 `PASS`
- **AND** compiler semantics 必须单独为 `BLOCKED` 或 `FAIL`

### Requirement: 搜索检查必须覆盖 rg fallback 和真实 csearch 闭环

系统必须在临时语料上验证公共搜索 dispatcher 的命中内容、完成时序和 backend identity；工具齐备时必须执行真实 cindex/csearch 查询。

#### Scenario: csearch 和 cindex 均可用

- **WHEN** 两个工具均可执行
- **THEN** runner 必须在临时目录构建独立索引并查询已知 token
- **AND** 公共 dispatcher 必须返回精确文件和行号
- **AND** 不得读取或覆盖用户现有 csearch index

#### Scenario: csearch 不可用但 rg 正常

- **WHEN** csearch/cindex 工具缺失且 `rg` fallback 查询通过
- **THEN** project search 必须报告 `DEGRADED` 或等价的 backend gate
- **AND** 不得把整个基础编辑器标记为失败

#### Scenario: 用户已有 CSEARCHINDEX

- **WHEN** runner 启动前环境已有 `CSEARCHINDEX`
- **THEN** 临时 csearch probe 必须使用自己的显式 index identity
- **AND** runner 结束后原环境和用户 index 必须保持不变

### Requirement: clangd、CDB 与 UE 检查必须区分 fixture 和 live 证据

系统必须在 deterministic 模式验证 schema、provenance 和纯规划契约，并且只在用户显式提供 live context 时读取真实 workspace 证据。

#### Scenario: deterministic 模式

- **WHEN** 用户未提供 live UE context
- **THEN** runner 可以验证 fixture CDB、semantic contract 和 target plan
- **AND** 不得执行 UE build、prepare、package、device、install、launch 或 DAP
- **AND** live capability 必须标记为 `SKIP`

#### Scenario: live workspace 模式

- **WHEN** 用户显式请求 live audit 且已有 active tuple/CDB/index
- **THEN** runner 必须只读检查 provenance、freshness、backend 和工具版本
- **AND** 不得生成、修复或替换任何 workspace artifact

### Requirement: 所有探测必须有界、可清理且保护现场身份

系统必须为子进程和异步探测设置 deadline，清理自己创建的 process/handle/temp artifact，并对报告中的用户身份进行脱敏。

#### Scenario: probe 超时

- **WHEN** parser、search、clangd 或 startup probe 超过 deadline
- **THEN** runner 必须停止该 probe、关闭其 handle 并报告超时 stage
- **AND** 不得无限等待或阻塞 Neovim UI

#### Scenario: 生成结构化报告

- **WHEN** runner 输出 JSON evidence
- **THEN** 报告不得包含完整用户目录、工程名、设备 identifier、证书 identity、密码或环境秘密
- **AND** 清理失败必须作为独立非 PASS 检查可见

### Requirement: 健康审计必须可重复且不改变系统状态

连续运行审计必须产生相同 capability 集合，且第二次运行不得依赖第一次留下的 cache、global、临时文件或后台任务。

#### Scenario: 连续运行两次 deterministic audit

- **WHEN** 同一环境连续执行两次
- **THEN** 两次必须产生相同 check id 集合和兼容的状态 shape
- **AND** 第一轮创建的任务、timer、pipe 和临时目录不得残留到第二轮

#### Scenario: 审计过程中发现缺失工具

- **WHEN** parser、csearch、clangd 或 live workspace 前置条件缺失
- **THEN** runner 必须只报告状态和修复建议
- **AND** 不得自动下载、安装、更新或修改配置
