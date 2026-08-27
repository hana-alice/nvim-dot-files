# project-scan-root-discovery Specification

## Purpose

定义项目侧**扫描根（scan roots）的推导契约**：应扫哪些目录必须从 UE 的权威构建元数据
（`*.Build.cs` / `*.uplugin` / `*.uproject`）推导，而不是按目录名猜测或用单一 `.uproject`
位置把范围钉死在某个子树内。契约覆盖推导来源、有界成本、前缀收敛、与显式白名单及既有默认值的
优先级与合并语义、歧义布局下不得放大到工具链目录，以及推导结果参与缓存身份从而触发刻意重建。

## Requirements

### Requirement: 扫描根从 UE 构建元数据推导

系统确定项目侧扫描根时 SHALL 以 UE 的**构建元数据声明**为权威来源：`*.Build.cs`（模块）、
`*.uplugin`（插件）、`*.uproject`（项目）所在目录即「存在可编译代码」的证据。系统 MUST NOT
仅凭目录名猜测（如固定尝试 `Source`/`Shaders`/`Script` 等名称），也 MUST NOT 因发现单一
`.uproject` 就把扫描范围钉死在该 `.uproject` 所在子树内、从而排除同层的其它模块目录。

#### Scenario: 同层新增模块目录被发现

- **WHEN** 项目为嵌套布局（`<project_root>/Source/<Proj>/<Proj>.uproject`），且在
  `<project_root>/Source/<Other>/` 下新增了含 `*.Build.cs` 的模块
- **THEN** 推导所得扫描根 SHALL 覆盖该新增模块所在目录
- **AND** 该模块的源文件 SHALL 出现在索引输入集中，无需用户手写任何白名单文件

#### Scenario: 不以目录名作为唯一依据

- **WHEN** 项目把可编译代码放在不属于任何常见默认名的目录下（既非 `Source` 亦非 `Plugins`）
  且该目录含 `*.Build.cs` 或 `*.uplugin`
- **THEN** 该目录 SHALL 被推导为扫描根
- **AND** 系统 MUST NOT 因其目录名不在默认列表内而遗漏它

#### Scenario: 声明文件识别不受大小写影响

- **WHEN** 模块声明文件的大小写形式不一致（如 `Foo.Build.cs` 与 `Foo.build.cs`）
- **THEN** 两者 SHALL 均被识别为模块声明
- **AND** 识别 MUST NOT 因大小写差异而漏判（Windows/macOS 文件系统大小写不敏感）

### Requirement: 推导成本有界

推导过程 SHALL 是**有界**的：SHALL 限制目录递归深度、SHALL 复用既有 `SCAN_EXCLUDES`
跳过构建产物与版本控制目录（`Intermediate`、`Binaries`、`Content`、`DerivedDataCache`、
`Saved`、`node_modules`、`.git` 等），且 MUST NOT 对项目根做无界全递归扫描。推导 SHALL
在主线程可接受的时间内完成，或按 P6 走异步；MUST NOT 造成可感知的 UI 卡顿。

#### Scenario: 深度与排除共同限制遍历量

- **WHEN** 在一个包含数十万文件的大型 UE 项目上执行推导
- **THEN** 遍历 SHALL 受递归深度上限约束
- **AND** SHALL 跳过 `SCAN_EXCLUDES` 列出的目录，不进入其子树
- **AND** 推导耗时 SHALL 保持在数十毫秒量级，不随项目总文件数线性增长

#### Scenario: 排除目录不产生扫描根

- **WHEN** 构建产物目录（如 `Intermediate`）下存在生成的 `*.Build.cs` 副本
- **THEN** 该目录 MUST NOT 成为扫描根
- **AND** 推导结果 MUST NOT 把构建产物纳入索引输入集

### Requirement: 推导结果按前缀收敛

推导所得的候选目录集 SHALL 按路径前缀**收敛**：若目录 A 是目录 B 的祖先（或相等），则只保留 A，
避免把同一子树拆成大量碎片扫描根。收敛 MUST NOT 改变被覆盖的文件集合——收敛前后索引输入集
SHALL 等价。

#### Scenario: 多个模块收敛为共同祖先

- **WHEN** 推导在同一子树下发现大量模块声明目录（例如上百个 `*.Build.cs`）
- **THEN** 结果 SHALL 收敛为覆盖它们的最浅祖先集合
- **AND** 收敛后的扫描根数量 SHALL 显著少于原始候选数
- **AND** 收敛后覆盖的文件集合 SHALL 与收敛前一致

### Requirement: 显式白名单优先于推导

`<project_root>/.ueprepare-scan-paths` 存在且非空时 SHALL 作为**最高优先级**的显式覆盖被完整
尊重：系统 SHALL 使用该文件声明的目录作为扫描根，且 MUST NOT 把推导结果合并进去。该文件不存在
或为空时，系统 SHALL 使用推导结果。

#### Scenario: 用户显式声明时不做合并

- **WHEN** 项目根存在非空 `.ueprepare-scan-paths`
- **THEN** 扫描根 SHALL 完全等于该文件声明的条目
- **AND** 推导所得的其它目录 MUST NOT 被追加（保留「显式声明即最终答案」的逃生门语义）

#### Scenario: 白名单缺失或为空时回落推导

- **WHEN** `.ueprepare-scan-paths` 不存在，或存在但去除注释/空行后无有效条目
- **THEN** 系统 SHALL 使用从构建元数据推导所得的扫描根

### Requirement: 推导只扩大不缩小既有覆盖

在无显式白名单的情况下，推导结果 SHALL 与既有默认/anchor 推算所得取**并集**（去重），使本机制
只可能**扩大**覆盖、MUST NOT 缩小任何既有已被索引的范围。唯一例外是「歧义嵌套布局」——该情形下
既有推算会退化为裸 `Source`，并集反而会把工具链重新拖回索引，故 SHALL 由推导结果取代之
（见「歧义布局不得放大到工具链目录」）。该例外 SHALL 仅在推导结果非空时生效，确保覆盖不会被
缩减为空。

#### Scenario: 并集保留既有默认覆盖

- **WHEN** 既有 anchor/默认策略产出一组扫描根，推导产出另一组，且布局非歧义嵌套
- **THEN** 最终扫描根 SHALL 包含两者的全部条目（去重后）
- **AND** 任何原先被索引的目录 MUST NOT 因引入推导而从索引输入集中消失

#### Scenario: 推导盲区由并集兜住

- **WHEN** 某目录属于既有默认列表但不含任何模块声明（例如纯 `Shaders/` 或 `Config/` 树）
- **THEN** 该目录 SHALL 仍出现在最终扫描根中
- **AND** 推导的盲区 MUST NOT 造成新的静默漏搜

### Requirement: 歧义布局不得放大到工具链目录

当项目布局无法唯一确定模块锚点时（例如 `Source/` 下存在多个 `.uproject` 且项目根自身无
`.uproject`），系统 SHALL 使用推导结果界定范围，MUST NOT 退化为把整个 `Source`（或项目根）
作为扫描根。该退化会把配置表、SDK 工具链、打包工具等非源码数据纳入索引，与「白名单优于黑名单、
显著削减扫描输入」的既有结论相悖。系统 SHALL 能区分「歧义嵌套布局」与「标准布局」
（项目根自身持有 `.uproject`）——二者的模块锚点相同，但前者 MUST NOT 使用根级默认列表，
后者 SHALL 正常使用。

#### Scenario: 多 uproject 时不回退根级

- **WHEN** `<project_root>/Source/` 下存在两个及以上 `.uproject`，项目根自身无 `.uproject`，
  且其中某子树含 `*.Build.cs`
- **THEN** 扫描根 SHALL 由推导给出（指向含模块声明的具体子树）
- **AND** 扫描根 MUST NOT 是裸的 `Source`
- **AND** 同层不含任何模块声明的工具链目录（如内嵌 JDK、打包工具）MUST NOT 被纳入

#### Scenario: 标准布局仍使用根级默认列表

- **WHEN** 项目根自身持有 `.uproject`（标准布局）
- **THEN** 该布局 SHALL NOT 被判定为歧义嵌套
- **AND** 根级默认列表（`Source`/`Shaders`/`Config`/`Plugins` 等）SHALL 正常参与并集
- **AND** 扫描根 MUST NOT 包含项目根自身（不得退化为全根遍历）

### Requirement: 扫描根变化触发刻意重建且缓存可失效

推导所得的扫描根 SHALL 参与索引缓存身份（`project_scan_roots`）：扫描根变化时系统 SHALL 判定
既有缓存不可复用并触发一次**刻意重建**，MUST NOT 静默复用按旧范围枚举的文件集。扫描根的
per-project 内存缓存 SHALL 提供显式失效入口，使用户修改 `.ueprepare-scan-paths` 或项目布局后
无需重启 Neovim 即可生效；任何文档/注释承诺的失效命令 MUST 真实存在。

#### Scenario: 扫描根变化使缓存失效

- **WHEN** 推导结果与持久状态中记录的 `project_scan_roots` 不一致
- **THEN** 系统 SHALL 判定缓存文件集不可复用
- **AND** SHALL 重新枚举文件集而非复用旧清单

#### Scenario: 失效命令存在且生效

- **WHEN** 用户在同一 Neovim 会话内修改 `.ueprepare-scan-paths` 或项目模块布局后执行文档承诺的
  扫描根失效命令
- **THEN** 该命令 SHALL 真实注册且可执行
- **AND** 下一次扫描根查询 SHALL 重新推导，不返回本会话早先缓存的结果
