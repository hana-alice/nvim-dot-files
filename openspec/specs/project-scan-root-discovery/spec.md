# project-scan-root-discovery Specification

## Purpose

定义项目侧扫描根（scan roots）的推导契约：应扫哪些目录必须从 UE 的权威构建元数据
（`*.Build.cs` / `*.uplugin` / `*.uproject`）推导，而不是按目录名猜测或用单一 `.uproject`
位置把范围钉死在某个子树内。契约覆盖推导来源、有界成本、前缀收敛、与显式白名单及既有默认值
的优先级与合并语义、歧义布局下不得放大到工具链目录，以及推导结果参与缓存身份从而触发刻意
重建。不管扫描本身的性能实现细节，只管「该扫哪些目录」这一契约。

## Requirements

### Requirement: 扫描根从 UE 构建元数据推导

系统确定项目侧扫描根时 SHALL 以 UE 的构建元数据声明为权威来源：`*.Build.cs`（模块）、
`*.uplugin`（插件）、`*.uproject`（项目）所在目录即「存在可编译代码」的证据。系统 MUST NOT
仅凭目录名猜测（如固定尝试 `Source`/`Shaders`/`Script`），也 MUST NOT 因发现单一 `.uproject`
就把扫描范围钉死在其所在子树内、从而排除同层的其它模块目录。声明文件识别 MUST NOT 因大小写
差异而漏判（Windows/macOS 文件系统大小写不敏感）。

#### Scenario: 同层新增模块目录被发现
- **WHEN** 项目为嵌套布局（`<project_root>/Source/<Proj>/<Proj>.uproject`），且在
  `<project_root>/Source/<Other>/` 下新增了含 `*.Build.cs` 的模块
- **THEN** 推导所得扫描根 SHALL 覆盖该新增模块所在目录，其源文件 SHALL 出现在索引输入集中，
  无需用户手写任何白名单文件

### Requirement: 推导成本有界

推导过程 SHALL 是有界的：SHALL 限制目录递归深度、SHALL 复用既有 `SCAN_EXCLUDES` 跳过构建
产物与版本控制目录（`Intermediate`、`Binaries`、`Content`、`DerivedDataCache`、`Saved`、
`node_modules`、`.git` 等），且 MUST NOT 对项目根做无界全递归扫描，不得造成可感知的 UI 卡顿。

#### Scenario: 排除目录不产生扫描根
- **WHEN** 构建产物目录（如 `Intermediate`）下存在生成的 `*.Build.cs` 副本
- **THEN** 该目录 MUST NOT 成为扫描根，推导结果 MUST NOT 把构建产物纳入索引输入集

### Requirement: 推导结果按前缀收敛

推导所得的候选目录集 SHALL 按路径前缀收敛：若目录 A 是目录 B 的祖先（或相等），则只保留 A，
避免把同一子树拆成大量碎片扫描根；收敛 MUST NOT 改变被覆盖的文件集合。

#### Scenario: 多个模块收敛为共同祖先
- **WHEN** 推导在同一子树下发现大量模块声明目录（例如上百个 `*.Build.cs`）
- **THEN** 结果 SHALL 收敛为覆盖它们的最浅祖先集合，收敛后覆盖的文件集合 SHALL 与收敛前一致

### Requirement: 显式白名单优先于推导，推导只扩大既有覆盖

`<project_root>/.ueprepare-scan-paths` 存在且非空时 SHALL 作为最高优先级的显式覆盖被完整
尊重，MUST NOT 与推导结果合并；缺失或为空时回落推导。无显式白名单时，推导结果 SHALL 与既有
默认/anchor 推算所得取并集（去重），本机制只可能扩大覆盖、MUST NOT 缩小任何既有已被索引的
范围——唯一例外是「歧义嵌套布局」，见下一条 Requirement。

#### Scenario: 用户显式声明时不做合并
- **WHEN** 项目根存在非空 `.ueprepare-scan-paths`
- **THEN** 扫描根 SHALL 完全等于该文件声明的条目，推导所得的其它目录 MUST NOT 被追加

#### Scenario: 推导盲区由并集兜住
- **WHEN** 某目录属于既有默认列表但不含任何模块声明（例如纯 `Shaders/` 或 `Config/` 树）
- **THEN** 该目录 SHALL 仍出现在最终扫描根中，推导的盲区 MUST NOT 造成新的静默漏搜

### Requirement: 歧义布局不得放大到工具链目录

当项目布局无法唯一确定模块锚点时（例如 `Source/` 下存在多个 `.uproject` 且项目根自身无
`.uproject`），系统 SHALL 使用推导结果界定范围，MUST NOT 退化为把整个 `Source`（或项目根）
作为扫描根——该退化会把配置表、SDK 工具链、打包工具等非源码数据纳入索引。系统 SHALL 能区分
「歧义嵌套布局」与「标准布局」（项目根自身持有 `.uproject`）：二者模块锚点相同，但前者
MUST NOT 使用根级默认列表，后者 SHALL 正常使用（且 MUST NOT 包含项目根自身，不退化为全根
遍历）。

#### Scenario: 多 uproject 时不回退根级
- **WHEN** `<project_root>/Source/` 下存在两个及以上 `.uproject`，项目根自身无 `.uproject`，
  且其中某子树含 `*.Build.cs`
- **THEN** 扫描根 SHALL 由推导给出（指向含模块声明的具体子树），MUST NOT 是裸的 `Source`
- **AND** 同层不含任何模块声明的工具链目录（如内嵌 JDK、打包工具）MUST NOT 被纳入

### Requirement: 扫描根变化触发刻意重建且缓存可失效

推导所得的扫描根 SHALL 参与索引缓存身份（`project_scan_roots`）：扫描根变化时系统 SHALL 判定
既有缓存不可复用并触发一次刻意重建，MUST NOT 静默复用按旧范围枚举的文件集。扫描根的
per-project 内存缓存 SHALL 提供显式失效入口，使用户修改 `.ueprepare-scan-paths` 或项目布局后
无需重启 Neovim 即可生效；任何文档/注释承诺的失效命令 MUST 真实存在。

#### Scenario: 失效命令存在且生效
- **WHEN** 用户在同一 Neovim 会话内修改 `.ueprepare-scan-paths` 或项目模块布局后执行文档承诺
  的扫描根失效命令
- **THEN** 该命令 SHALL 真实注册且可执行，下一次扫描根查询 SHALL 重新推导，不返回本会话早先
  缓存的结果

## 选型与踩坑

- **选型**：选「构建元数据推导」不选「目录名白名单/黑名单猜测」——理由是目录名猜测在非
  常见布局（模块目录不叫 `Source`/`Plugins`）下必然漏搜，而 `*.Build.cs`/`*.uplugin`/
  `*.uproject` 是 UE 自身认定"可编译代码"的权威声明，不依赖命名约定。
- **踩坑**：早期实现发现单一 `.uproject` 就把扫描范围钉死在其子树内，导致同层新增的兄弟
  模块目录（`<project_root>/Source/<Other>/`）永远不会被扫到；根因是把 `.uproject` 误当作
  唯一锚点而非布局判定信号之一，处置为改用构建元数据推导 + 前缀收敛。
- **踩坑**：歧义嵌套布局（`Source/` 下多个 `.uproject`、根无 `.uproject`）如果沿用「既有
  默认列表并集」逻辑会退化为裸 `Source` 扫描，把 SDK/工具链一起拖入索引；根因是并集语义
  假设了标准布局下根级默认列表是安全超集，歧义布局打破了这个假设，处置为对该布局单独排除
  根级默认列表参与并集。
- **重要事项**：前缀收敛与并集的「覆盖不缩小」保证依赖递归深度上限和 `SCAN_EXCLUDES`
  共同起效；两者任一失效都可能让有界性假设不成立，这一交互尚未有独立于本 spec 的验证记录。
