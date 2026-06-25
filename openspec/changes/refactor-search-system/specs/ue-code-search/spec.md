# ue-code-search Specification (delta)

> 本文件为 change `refactor-search-system` 对 `openspec/specs/ue-code-search/spec.md` 的修改增量。
> 标注 ADDED / MODIFIED / REMOVED；未列出的既有 Requirement 保持不变。

## MODIFIED Requirements

### Requirement: `<leader>/` SHALL use csearch exclusively (never rg, ever)

UE 全代码搜索（`<leader>/`）SHALL **只**使用 csearch 索引后端，**任何情况下都不得在此入口使用 rg 或目录遍历**——无论是静默降级、cached-file-list + rg 批量搜索、还是 snacks 默认目录遍历兜底，一律 MUST NOT 出现在 `<leader>/` 路径。当 csearch 索引可用时使用 csearch；当 csearch 索引不可用时，`<leader>/` SHALL 给出可见错误并引导用户运行 `:UEPrepare`，而不是回落到任何 rg / 遍历路径。

理由：`<leader>/` 是「索引级精确搜索」入口，**任何**走 rg / 目录遍历的路径都会产生「搜不全却看似搜过」的体验欺骗，且与「亚秒」承诺相悖。用户明确要求此入口「从不加 rg」。rg 在本仓有专用入口（`<leader>sg` / `<leader>sG`）；`code_search.stream()` 内部 rg 分支保留供 gd/gr 跳定义兜底（P12），那是**另一个调用点**，不在本入口消失。

#### Scenario: csearch 索引可用
- **WHEN** 用户触发 `<leader>/` 且当前 UE context 含可用 `csearch.idx`
- **THEN** 搜索 SHALL 使用 csearch backend
- **AND** picker 标题 SHALL 标识 `[csearch]`

#### Scenario: csearch 索引不可用
- **WHEN** 用户触发 `<leader>/` 且 csearch 索引缺失 / 0 字节 / 损坏
- **THEN** `<leader>/` MUST NOT fall 到 rg、cached-list+rg、或目录遍历中的任何一种
- **AND** 系统 SHALL 给出可见错误，明确提示运行 `:UEPrepare` 重建索引
- **AND** 系统 SHALL NOT 打开一个走 rg 的 picker

#### Scenario: 有 cached file list 但无 csearch 索引（堵死 rg-batched 暗门）
- **WHEN** 用户触发 `<leader>/`，csearch 索引不可用，但存在 cached workspace file list
- **THEN** `<leader>/` MUST NOT 启用 cached-list + 批量 rg 搜索（旧 rg-batched fallback）
- **AND** 行为 SHALL 与「csearch 索引不可用」一致：报错引导 `:UEPrepare`

#### Scenario: 用户显式要 rg
- **WHEN** 用户需要无索引的 rg 搜索
- **THEN** `<leader>sG`（`ue_grep_all`）SHALL 提供专用 rg 入口
- **AND** 该入口的行为不受本契约约束

### Requirement: csearch index SHALL be platform-independent (single shared index)

csearch trigram 索引 SHALL 全平台共用一份，路径为 `csearch/csearch.idx`（不再按 `platform_key` 分片）。gtags workspace DB 与 cdb compile-db 资产 SHALL 仍按 `platform_key` 分片——它们是平台相关产物（编译参数 / 宏 / include / 条件编译符号按平台不同）。

理由：csearch 索引的输入文件集（`workspace_all.files`）由 `engine_root` + `project_root` + 平台无关常量（`ENGINE_PICKER_DIRS` / `SCAN_EXCLUDES`）+ 平台无关白名单（`.ueprepare-scan-paths`）决定，不含任何平台维度。per-platform 分片是 cache layout v3.1 让 csearch 搭便车的结果，去之使「索引维度」与「`csearch_input_hash` 校验维度（per-engine_root，本就一份）」对齐，并令切平台不再重建 csearch 索引。

#### Scenario: 解析 csearch 索引路径
- **WHEN** 系统为任一平台 / 配置解析 csearch 索引路径
- **THEN** 路径 SHALL 为 `csearch/csearch.idx`（与 `platform_key` 无关）

#### Scenario: gtags / cdb 仍分平台
- **WHEN** state 含 `target_platform = "Android"` 且 `target_configuration = "Development"`
- **THEN** gtags 文件清单与 DB SHALL 仍位于 `gtags/Android-Development/`
- **AND** cdb compile-db 资产 SHALL 仍按平台 / 配置分片

#### Scenario: 切换平台
- **WHEN** 用户在平台 / 配置间切换
- **THEN** csearch 搜索 SHALL 继续使用同一份 `csearch/csearch.idx`，MUST NOT 因切平台而被判为缺失或需重建
- **AND** 切平台 SHALL NOT 删除任何既有 csearch 索引

### Requirement: legacy grep caches SHALL migrate without data loss

当缓存布局变更时，既有 grep 缓存 SHALL 安全迁移，不丢数据、不覆盖更新的文件，且可重复运行。迁移 SHALL 覆盖两个方向：早期「扁平 → 平台子目录」（gtags，历史 v3.1）与本次「csearch 平台子目录 → 扁平共用」。

#### Scenario: csearch 从平台子目录迁移到共用扁平路径
- **WHEN** 共用 `csearch/csearch.idx` 不存在，但存在一个或多个 `csearch/<platform_key>/csearch.idx`
- **THEN** 系统 SHALL 要么将其中一份提升为共用 `csearch/csearch.idx`，要么将共用索引判为 stale 以触发首次 `:UEPrepare` 重建
- **AND** 旧的 `csearch/<platform_key>/` 索引 SHALL NOT 仅因去平台化被主动删除

#### Scenario: 共用 csearch 索引已存在
- **WHEN** 共用 `csearch/csearch.idx` 已存在
- **THEN** 迁移 SHALL NOT 用平台子目录的旧索引覆盖它
- **AND** 操作 SHALL 可重复安全运行

## ADDED Requirements

> 说明：下列「分组/计数」与「可视化修饰开关」契约对应的行为在 `cached_grep` 中**已实现**
> （见 change design.md 决策2 对账表）。本 change 将其**固化为 spec 契约以防回归**——尤其是
> `<leader>/` 去 rg 后，主搜索路径变为纯 csearch，这些行为必须在 csearch 后端下保持成立。
> 「面板内 scope 过滤」是其中唯一新增的行为。

### Requirement: `<leader>/` 结果呈现 SHALL 提供分组、计数与后端状态

`<leader>/` 的结果面板 SHALL 按文件分组，每文件 SHALL 显示命中计数；picker 标题 SHALL 标识当前后端（`[csearch]`）与当前 scope。

#### Scenario: 多文件多命中
- **WHEN** 一次 `<leader>/` 搜索在多个文件命中
- **THEN** 结果 SHALL 按文件分组
- **AND** 每个文件分组 SHALL 显示该文件内的命中数

#### Scenario: 标题反映后端与 scope
- **WHEN** `<leader>/` 面板打开并完成一次搜索
- **THEN** 标题 SHALL 包含后端标识 `[csearch]`
- **AND** 标题 SHALL 包含当前 scope（全工程 / 当前模块 / 插件 / 目录）

### Requirement: `<leader>/` SHALL 提供可视化搜索修饰开关

`<leader>/` 面板 SHALL 提供可视化的 大小写 / 全词 / 正则 开关（无需用户手输 `-- -w/-s/-F`），开关状态 SHALL 在标题栏可见，切换后 SHALL 以新修饰重跑当前搜索。开关 SHALL 翻译为底层后端等价语义。

#### Scenario: 切换全词
- **WHEN** 用户在 `<leader>/` 面板内切换「全词」开关
- **THEN** 搜索 SHALL 以全词边界（等价 `--word-regexp` / `-w`）重跑
- **AND** 标题栏 SHALL 反映「全词」为开启

#### Scenario: 切换大小写 / 正则
- **WHEN** 用户切换「大小写敏感」或「正则」开关
- **THEN** 搜索 SHALL 以对应修饰（等价 `-s` / 正则模式）重跑
- **AND** 标题栏 SHALL 反映该开关状态

### Requirement: `<leader>/` SHALL 支持面板内 scope 过滤

`<leader>/` 面板 SHALL 允许用户在面板内将搜索范围一键切换到「当前模块 / 插件 / 目录」，无需退出改走单独的 scope grep 键。

#### Scenario: 面板内切到当前模块
- **WHEN** 用户在 `<leader>/` 面板内触发「限定当前模块/插件」scope
- **THEN** 搜索 SHALL 重跑并仅在该 scope 内命中
- **AND** 标题栏 SHALL 反映该 scope

## REMOVED Requirements

### Requirement: grep-facing caches SHALL be isolated by platform and configuration

**Reason**: 该契约要求 csearch 索引按平台 / 配置分片。本 change 证实 csearch 索引输入平台无关（见 design.md 风险1 证伪），故对 csearch 移除此约束，改由「csearch index SHALL be platform-independent」承接。gtags / cdb 的 per-platform 隔离需求迁移到各自契约措辞中保留，不再由这条统管 csearch。

**Migration**: csearch 索引路径由 `csearch/<platform_key>/csearch.idx` 改为 `csearch/csearch.idx`，迁移由「legacy grep caches SHALL migrate」的新方向覆盖。
