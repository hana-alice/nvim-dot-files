# nvim-core-functionality-audit Specification

## Purpose

定义一个只读、分层、可机器判定的 Neovim 基本功能健康审计，覆盖真实启动、编辑、Tree-sitter、
csearch/rg、clangd/CDB、UE 集成与异步稳定性，并准确表达外部能力 gate（不把「工具缺失」和
「配置本身坏了」混为一谈）。只管审计契约本身，不管被审计功能的实现细节。

## Requirements

### Requirement: 健康审计必须按 capability 独立报告

系统 MUST 为每个检查生成稳定 id、状态、阶段、耗时、摘要和可行动下一步；不得用单一成功布尔值
掩盖部分失败或外部阻塞。deterministic 必需检查失败时，对应检查必须为 `FAIL`，runner 必须以
非零退出码结束。

#### Scenario: 基础编辑正常但 clangd 版本不兼容
- **WHEN** 启动、buffer/file 和 Tree-sitter 检查通过，但实际 clangd 不满足要求版本
- **THEN** 基础编辑与 syntax capability 必须为 `PASS`，compiler semantics 必须为 `BLOCKED`
- **AND** overall 不得声称所有能力端到端通过

### Requirement: 审计必须验证真实配置启动和最小编辑事务，不得自动安装依赖

系统 MUST 以真实配置启动隔离 Neovim 进程，并在临时目录完成 create/open/edit/write/reopen；
不得仅以 Lua module 可 require 代替启动和编辑证据。审计过程中缺少依赖（如 lazy.nvim）时，
MUST 明确报告缺失并退出该检查，MUST NOT 执行 git clone、等待交互输入或安装插件。

#### Scenario: 只读启动缺少 lazy.nvim
- **WHEN** health startup 的既有数据目录没有 lazy.nvim
- **THEN** SHALL 明确报告缺失依赖并退出该启动检查，MUST NOT 执行 git clone、等待交互输入或
  安装插件

### Requirement: Tree-sitter 检查必须解析真实语法树

系统 MUST 从配置声明得到 mandatory parser 集合，加载每个真实 parser 并解析合法 fixture；
不得只检查 parser 名称出现在配置中。mandatory parser 缺失时对应 syntax check 必须为 `FAIL`
并给出修复方向，审计过程中不得执行安装。

#### Scenario: clangd 不可用
- **WHEN** Tree-sitter parser 正常但 clangd 或 CDB 不可用
- **THEN** syntax tree 仍必须为 `PASS`，compiler semantics 必须单独为 `BLOCKED` 或 `FAIL`

### Requirement: 搜索检查必须覆盖 rg fallback 和真实 csearch 闭环，不得污染用户索引

系统 MUST 在临时语料上验证公共搜索 dispatcher 的命中内容、完成时序和 backend identity；
工具齐备时必须执行真实 cindex/csearch 查询，且不得读取或覆盖用户现有 csearch index。
csearch/cindex 缺失但 `rg` fallback 正常时，project search 必须报告 `DEGRADED` 或等价的
backend gate，不得把整个基础编辑器标记为失败。

#### Scenario: 用户已有 CSEARCHINDEX
- **WHEN** runner 启动前环境已有 `CSEARCHINDEX`
- **THEN** 临时 csearch probe 必须使用自己的显式 index identity
- **AND** runner 结束后原环境和用户 index 必须保持不变

### Requirement: clangd、CDB 与 UE 检查必须区分 fixture 和 live 证据

系统 MUST 在 deterministic 模式验证 schema、provenance 和纯规划契约，并且只在用户显式提供
live context 时读取真实 workspace 证据；deterministic 模式下不得执行 UE
build/prepare/package/device/install/launch 或 DAP，live capability 必须标记为 `SKIP`。
live workspace 模式下 runner 必须只读检查，不得生成、修复或替换任何 workspace artifact。

#### Scenario: deterministic 模式
- **WHEN** 用户未提供 live UE context
- **THEN** runner 可以验证 fixture CDB、semantic contract 和 target plan，不得执行 UE
  build/prepare/package/device/install/launch 或 DAP，live capability 必须标记为 `SKIP`

### Requirement: 所有探测必须有界、可清理且保护现场身份

系统 MUST 为子进程和异步探测设置 deadline，清理自己创建的 process/handle/temp artifact，
并对报告中的用户身份进行脱敏；probe 超时必须停止该 probe、关闭其 handle 并报告超时 stage，
不得无限等待或阻塞 Neovim UI。

#### Scenario: 生成结构化报告
- **WHEN** runner 输出 JSON evidence
- **THEN** 报告不得包含完整用户目录、工程名、设备 identifier、证书 identity、密码或环境秘密
- **AND** 清理失败必须作为独立非 PASS 检查可见

### Requirement: 健康审计必须可重复且不改变系统状态

连续运行审计 SHALL 产生相同 capability 集合，且第二次运行 MUST NOT 依赖第一次留下的
cache/global/临时文件/后台任务；发现缺失工具时 runner SHALL 只报告状态和修复建议，MUST NOT
自动下载、安装、更新或修改配置。

#### Scenario: 连续运行两次 deterministic audit
- **WHEN** 同一环境连续执行两次
- **THEN** 两次必须产生相同 check id 集合和兼容的状态 shape
- **AND** 第一轮创建的任务、timer、pipe 和临时目录不得残留到第二轮

## 选型与踩坑

- **选型**：区分 `BLOCKED`（外部能力缺失）与 `FAIL`（配置本身坏了），不用单一 pass/fail
  布尔值——理由是「clangd 版本不兼容」和「配置启动崩溃」需要用户采取完全不同的行动，混为
  一谈会让用户误判该修配置还是该换环境。
- **踩坑**：早期若不显式隔离 csearch probe 的 index identity，审计会读取或覆盖用户真实的
  `CSEARCHINDEX`；处置为要求 probe 必须使用自己的显式 index identity，且 runner 结束后原
  环境和用户 index 必须保持不变。
- **重要事项**：deterministic 模式与 live workspace 模式的边界依赖「用户是否显式提供 live
  context」这一信号；如果调用方遗漏该显式声明，审计会默认走 deterministic 模式并把 live
  capability 标记 `SKIP`，这是保守但可能让用户误以为「UE 集成已验证」的已知歧义点。
