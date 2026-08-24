## ADDED Requirements

### Requirement: csearch toolchain SHALL bootstrap and resolve portably

系统 SHALL 为 POSIX 宿主提供可复现的 csearch/cindex 安装入口，并在运行时统一发现 `PATH`、
`GOBIN`、多段 `GOPATH/bin` 与宿主惯用 Go bin 目录。安装入口 SHALL 固定 upstream csearch
版本并安装仓内 `cindex-uefilter`，缺失提示 SHALL 指向该入口。仅检查工具或索引可用性时
MUST NOT 创建缓存目录或修改磁盘状态。

#### Scenario: macOS 首次安装搜索工具
- **WHEN** 用户在装有 Go 的 macOS/POSIX 宿主运行仓库安装入口
- **THEN** 系统 SHALL 把固定版本的 `csearch` 与仓内 `cindex-uefilter` 安装到同一可执行目录
- **AND** 安装结束前 SHALL 验证两个程序都可执行

#### Scenario: 工具位于自定义 Go bin
- **WHEN** `csearch` 或 `cindex-uefilter` 不在 `PATH`，但位于 `GOBIN`、任一 `GOPATH/bin` 或宿主惯用 Go bin
- **THEN** executable probing SHALL 找到并返回该程序
- **AND** health、live health 与 UEPrepare SHALL 复用同一发现结果和安装提示

#### Scenario: 只读检查一个尚不存在的索引
- **WHEN** `is_indexed`、health 或 backend probing 检查一个父目录尚不存在的 index path
- **THEN** 检查 SHALL 返回 unavailable/not-indexed
- **AND** MUST NOT 为探测创建该父目录或抛出写目录错误

### Requirement: cindex incremental merge SHALL replace only listed files

仓内 `cindex-uefilter -files-from` 在非 reset 模式 SHALL 以清单中的每个 exact file path 作为
staged merge replacement path，并只重建这些文件的 trigrams；MUST NOT 把宽泛 CLI root 当作
delta replacement prefix。reset 模式 SHALL 只登记显式 CLI roots，避免把全量文件清单复制进
index path table。删除事件 SHALL 继续升级为 reset，而不是伪装成 add。

#### Scenario: 修改文件并增量合并
- **WHEN** 清单包含一个已索引后修改的文件和一个新文件
- **THEN** merge SHALL 移除修改文件的旧 trigram、加入两个文件的新 trigram且不 panic
- **AND** 未列入清单的旧文件 SHALL 继续可搜索

#### Scenario: 增量命令同时传入宽泛 root
- **WHEN** add 模式的 CLI 参数包含 workspace root，但 `-files-from` 只含一个 delta 子集
- **THEN** staged Paths SHALL 只包含 delta 文件的 exact paths
- **AND** merge MUST NOT 因 root prefix shadow 删除其他已索引文件

#### Scenario: reset 使用全量文件清单
- **WHEN** reset 模式通过 `-files-from` 索引大型 workspace
- **THEN** index Names SHALL 覆盖清单中的有效文件
- **AND** index Paths SHALL 只保留显式 roots，不复制全部文件路径
