# ue-code-search Specification

## Purpose

TBD

## Requirements

### Requirement: `<leader>/` SHALL prefer complete indexed search

UE 全代码搜索 SHALL 在 UE context 可解析时优先使用完整的 indexed backend：存在 csearch index 时使用 csearch；不存在 csearch index 但存在 cached workspace file list 时使用 rg；只有两者都不可用时才允许回落到 snacks 的目录遍历。

#### Scenario: csearch index 可用
- **WHEN** 用户触发 `<leader>/` 且当前 UE context 含有效 `csearch_idx`
- **THEN** `cached_grep` SHALL 使用 csearch backend
- **AND** picker 标题 SHALL 标识 `[csearch]`

#### Scenario: csearch index 不可用但 cached file list 可用
- **WHEN** 用户触发 `<leader>/` 且 csearch index 不可用，但 cached workspace file list 可用
- **THEN** `cached_grep` SHALL 使用 rg backend
- **AND** picker 标题 SHALL 标识 `[rg]`

#### Scenario: indexed backend 与 cached file list 都不可用
- **WHEN** 用户触发 `<leader>/` 且 csearch index 与 cached workspace file list 都不可用
- **THEN** `cached_grep` SHALL 返回 nil 以允许最底层 fallback
- **AND** fallback picker 标题 MUST 明确包含 slow fallback 与运行 `:UEPrepare` 的提示
- **AND** 系统 MUST 发出一次性 WARN，说明该 fallback 可能漏文件

### Requirement: 流式 backend SHALL deliver all parsed hits before done

`utils.code_search.stream` 的 csearch 与 rg backend SHALL 保证同一次搜索中所有已解析命中均在 `on_done` 前通过 `on_line` 交付。

#### Scenario: stdout 尾部数据晚于 exit callback 调度
- **WHEN** csearch 或 rg 进程退出信号与 stdout 尾部数据在同一轮事件循环附近到达
- **THEN** backend SHALL 先交付所有 parsed-but-undelivered hits
- **AND** backend SHALL only call `on_done` after backlog is empty

#### Scenario: 搜索被 stop 后
- **WHEN** caller 调用 backend 返回的 stop 函数
- **THEN** backend SHALL stop delivering future `on_line` callbacks
- **AND** backend SHALL NOT call `on_done` for that stopped search after stop has taken effect

### Requirement: csearch tool probing SHALL NOT cache failures

csearch 与 cindex-uefilter 的 executable probing SHALL cache only successful executable paths. A failed probe MUST NOT prevent later probes in the same Neovim session.

#### Scenario: 冷启动首次探测失败
- **WHEN** 首次探测 csearch executable 返回 nil
- **THEN** 后续再次调用 probing 逻辑 SHALL retry discovery
- **AND** 一旦 executable 可用，后续调用 SHALL reuse the successful path

#### Scenario: UEPrepare 或上下文切换完成
- **WHEN** UEPrepare finalize、项目切换或平台切换完成
- **THEN** 系统 SHALL reset csearch/cindex probe cache
- **AND** 下一次 `<leader>/` SHALL re-evaluate backend availability

### Requirement: grep-facing caches SHALL be isolated by platform and configuration

UE grep-facing cache artifacts SHALL be keyed by the active platform/configuration when that state is known. This includes csearch index, gtags workspace DB, and grep file lists.

#### Scenario: active platform key exists
- **WHEN** state contains `target_platform = "Android"` and `target_configuration = "Development"`
- **THEN** cache paths SHALL place csearch index under `csearch/Android-Development/`
- **AND** grep file lists SHALL be under `gtags/Android-Development/`

#### Scenario: no platform key exists
- **WHEN** no active platform is known
- **THEN** cache paths SHALL use the legacy single-path layout
- **AND** existing no-platform workflows SHALL continue to resolve cache files without platform subdirectories

#### Scenario: switching platform
- **WHEN** user switches from one platform/configuration to another
- **THEN** UE grep SHALL resolve to the new platform/configuration cache directory
- **AND** the previous platform/configuration cache SHALL NOT be deleted solely because of the platform switch
- **AND** if the new cache is missing, the next `<leader>/` SHALL surface visible fallback instead of silently presenting incomplete results

### Requirement: project or engine switch SHALL invalidate project-scoped grep caches

Project-scoped grep caches SHALL be invalidated when either the project root or engine root changes.

#### Scenario: project root changes
- **WHEN** `UESetProject` records a different project root than the persisted state
- **THEN** all platform-specific csearch and gtags grep caches for that engine cache root SHALL be invalidated
- **AND** cdb shard caches tied to the old project SHALL be invalidated

#### Scenario: engine root changes
- **WHEN** `UESetProject` records the same project root but a different engine root than persisted state
- **THEN** all project-scoped grep caches SHALL be invalidated
- **AND** the new `engine_root` SHALL be persisted in state for future comparisons

### Requirement: legacy grep caches SHALL migrate without data loss

When a platform key becomes available, legacy single-path grep caches SHALL be migrated into the active platform/configuration directory without overwriting newer platform-specific files.

#### Scenario: legacy cache exists and active platform cache is empty
- **WHEN** legacy `csearch/csearch.idx` and `gtags/*.files` exist
- **AND** active platform-specific target files do not exist
- **THEN** migration SHALL move those files into the active platform directory
- **AND** the legacy source files SHALL no longer remain at their old paths

#### Scenario: active platform cache already exists
- **WHEN** legacy cache files exist but the active platform-specific target file already exists
- **THEN** migration SHALL NOT overwrite the active platform-specific file
- **AND** the operation SHALL be safe to run repeatedly
