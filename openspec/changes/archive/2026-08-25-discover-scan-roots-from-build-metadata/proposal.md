## Why

嵌套布局项目的**扫描根是猜出来的，不是推导出来的**，导致同事新增的代码目录在 csearch 与
文件 picker 里**结构性不可见**——重跑 `:UEPrepare` 也永远搜不到，因为该目录一开始就不在
扫描范围内。

实测证据（当前选中项目，嵌套布局 `project_root` ≠ uproject 目录）：

`CORE_RT.project_module_anchor`（`lua/ue.lua:1994`）发现 `Source/*/*.uproject` 唯一命中时，
把 anchor 挪到 uproject 目录，于是全部扫描根被钉死在该子树内：

```
project_root = <PROJECT_ROOT>                      （嵌套布局）
uproject     = <PROJECT_ROOT>/Source/<Proj>/<Proj>.uproject
scan roots   = Source/<Proj>/{Source,Config,Plugins}  （+5 个不存在的默认项）
```

核对实际索引清单（`csearch.idx.files`，180431 条）后，项目侧**只有这三个前缀**被索引：
`Source/<Proj>/Plugins` 42879、`Source/<Proj>/Source` 876、`Source/<Proj>/Config` 530。
**任何落在 `Source/<Proj>/` 之外的模块都不在索引输入集里**；因为 csearch 与文件 picker 共用
同一份 `workspace_all.files`，所以「csearch 和文件系统都没找到」是同一个根因的两个表现。

已用 fixture 复现出两类真实失效，二者都由「以目录名猜范围」这一机制缺陷导致：

| 场景 | 现行启发式结果 | 后果 |
|---|---|---|
| A：同层新增 `Source/Tools/Source/ToolMod/ToolMod.Build.cs` | 只给 `Source/<Proj>/*` | **漏掉该模块**（本次故障） |
| B：出现第二个 `.uproject`（anchor 歧义） | 回退到根级 `Source` | 把 `Source/` 下的 JDK/apktool 工具链**全部拖进索引**，正是当年 877k→116k 优化要避免的 |

Why now：这不是索引过期（虽然该 bucket 的 `csearch.idx` 已 stale 12 天），而是**范围推导错误**；
过期可由重建修复，范围错误不能。`ue-code-search` 现有 freshness 契约用内容指纹回答「集合变了
吗」，**回答不了「集合一开始就漏了吗」**——这是 spec 层的覆盖缺口。

同时发现两处既有漂移：`lua/ue.lua:2050` 注释声称「Use :UEReloadScanPaths to invalidate」，
但该命令**全仓不存在**，而 `project_index_dirs_cache` **没有任何失效点**——即使用户手写
`.ueprepare-scan-paths`，同一会话内也不生效。

## What Changes

- **扫描根改为从 UE 权威构建元数据推导**：以 `*.Build.cs` / `*.uplugin` / `*.uproject`
  （UE 模块的声明式真相）反推应扫目录，替代「按目录名猜 + anchor 钉死子树」。
  有界浅扫（depth ≤ 6，复用既有 `SCAN_EXCLUDES`）实测 **10ms / 333 目录**，
  再按前缀收敛（A 是 B 前缀则只留 A），142 个碎片收敛为 1 个真实模块根。
- **discovery 与既有结果取并集，不替换**：保守策略——推导所得与 anchor/默认所得合并去重，
  确保本次改动**只可能扩大覆盖、不可能缩小**，避免把「漏扫」换成「漏另一批」。
- **歧义不再粗暴回退根级**：多 `.uproject` 时用 discovery 结果，而非把整个 `Source`
  （含工具链、配置表、SDK）纳入扫描。
- **`.ueprepare-scan-paths` 仍是最高优先级显式覆盖**：用户显式声明时完全尊重，不做 discovery
  合并（保留「declarative 逃生门」语义，且不因本次改动改变既有项目行为）。
- **补上缺失的缓存失效路径**：注册 `:UEReloadScanPaths` 使 `project_index_dirs_cache` 可失效，
  兑现 `lua/ue.lua:2050` 已承诺但不存在的命令（否则删除该悬空注释——本 change 选择兑现）。
- **补 spec 覆盖缺口**：给 `ue-code-search` 增加「扫描根 SHALL 覆盖全部模块声明」的 requirement，
  使「范围是否漏了」成为可回归守护的契约，而非只有 freshness 指纹。

不改动：不引入新依赖；不改 csearch/gtags/cdb 的缓存布局与平台维度；不改 freshness 指纹机制；
不动 `SCAN_EXCLUDES` 既有条目（`Intermediate` 等排除是正确的，已核对 cdb 的 4662 条命中属预期）。

## Capabilities

### New Capabilities

- `project-scan-root-discovery`: 定义项目侧扫描根的**推导契约**——以 UE 构建元数据
  （`*.Build.cs` / `*.uplugin` / `*.uproject`）为权威来源推导应扫目录、有界成本、前缀收敛、
  与显式白名单/既有启发式的优先级与合并语义、以及歧义布局下不得放大到工具链目录。

### Modified Capabilities

- `ue-code-search`: 增加「扫描根覆盖完整性」要求——索引输入集 SHALL 覆盖项目内全部模块声明所在
  目录；freshness 指纹只判集合变化，不足以保证集合完整，二者 MUST 同时成立。

## Impact

- 运行时：`lua/ue.lua` 的 `CORE_RT.project_index_dirs`（+ 新增 discovery helper、
  `:UEReloadScanPaths` 命令与 `project_index_dirs_cache` 失效）。这是**本 change 唯一的运行时
  行为变更点**，10 个调用方（`3138`/`3609`/`3635`/`6440`/`8252`/`8334`/`8864`/`9167` 等）
  透明受益，无需逐个改动。
- 缓存：`project_scan_roots` 已是缓存身份的一部分（`lua/ue.lua:2403`
  `project_scan_roots_match`），扫描根一旦变化会**自动触发一次刻意重建**，无需手工清缓存，
  也不会静默复用旧文件集。
- 命令：新增 `:UEReloadScanPaths` → `commands_spec.lua` 的 `UE_COMMANDS` 冻结清单 +1（81→82）。
- Spec：新增 `project-scan-root-discovery`；修改 `ue-code-search`。
- 文档：`lua/ue.lua:2050` 悬空注释兑现；`lua/utils/code_search/AGENTS.md` 与
  `memory/project_overview.md` 治理 spec 列同步新 capability。
- 回归：`ue_api`（`_project_index_dirs_for_test` 已有嵌套/歧义布局用例，需扩充）、
  `csearch_build_guard`、`ue_watch_csearch`、`utils`、`commands`、`structure`。
