## Context

见 `proposal.md` §Why（8 条 FAIL、悬空引用、spec 不在任何 agent 的自动读取路径上）。
设计层面只需锁定三个既有事实：

1. **三 agent 的自动上下文交集只有 `AGENTS.md` 层级**（已验证）：Codex 由
   `~/.codex/config.toml` 原生读 `AGENTS.md`；pi 按 `~/.pi/agent/AGENTS.md` → 各级父目录 →
   cwd 逐级拼接 `AGENTS.md`/`CLAUDE.md`（`AGENTS.override.md` 优先）；Claude Code 读
   `CLAUDE.md`，本仓已把它做成 `@AGENTS.md` 单行 stub。所以「让 spec 生效」的注入点唯一。
2. **`openspec validate` 只做结构校验**：37/37 全绿的同时存在 8 条 FAIL 与多处悬空路径。
   spec ↔ 实现的语义一致性不可能由 openspec CLI 保证，只能由本仓 headless 回归 +
   Definition of Done 承担。
3. **`structure` filter 已是文档纪律的执行器**：`tests/cases/structure_spec.lua` 已在守护
   目录规则存在性、知识库四根、内链不悬空、政策标记。新增的 spec 纪律应长在这里，而不是
   另起一个测试域。

约束（来自 `docs/CONSTRAINTS.md`）：不引入新依赖（P 系列 / C 系列）；文档类改动不得触碰
运行时行为；不做无关重构。

## Goals / Non-Goals

**Goals:**

- spec 成为 SESSION START 的一等公民，三 agent 零额外配置同时生效。
- 从「改动目录」到「治理它的 spec」是一步查表，不是 37 份 spec 的遍历。
- spec ↔ 实现漂移有可执行的拦截点（引用完整性 + 覆盖映射 + DoD 硬条件）。
- 把当前 8 条 FAIL 收敛到 0，且收敛方式本身符合 spec 语义（fail-closed 而非造假宿主）。

**Non-Goals:**

- 不做 spec 语义的自动验证（例如从 spec 的 WHEN/THEN 生成测试）。语义一致性由人/agent
  在 DoD 环节判断，回归只守护「结构可发现 + 引用不悬空 + 映射不腐烂」这类机械不变量。
- 不改 openspec CLI、schema、`openspec/config.yaml` 的 context 段。
- 不新增 `AGENTS.override.md`、`.pi/SYSTEM.md`、`.codex/AGENTS.md` 等 per-agent 文件。
- 不重构 `tests/cases/structure_spec.lua` 既有四段结构。
- 不借本次改动扩大 8 条 FAIL 之外的行为修改面。

## Decisions

### D1：spec 纪律只写进 `AGENTS.md`，不新增第四份入口

**选择**：把「读 spec」写入根 `AGENTS.md` 的 SESSION START，把「spec 与实现一致」写入
Definition of Done；目录级 `AGENTS.md` 的「先读」段补 spec 指针。`CLAUDE.md` 全部保持
`@AGENTS.md` stub。

**否决方案 A：给每个 agent 各写一份规则文件**（`.pi/SYSTEM.md` + `.codex/AGENTS.md` +
`.claude/CLAUDE.md`）。三份并行维护必然分叉，本仓一年前正是为此才收敛到单一内容源
（commit `306c4b8`）；重新分叉是政策回退。

**否决方案 B：用 `AGENTS.override.md`**。它是 pi 专属语义（会**替换**而非叠加该目录的
`AGENTS.md`），Codex/Claude 不认，等于制造一个只对一个 agent 生效的影子入口。

**否决方案 C：把 spec 原文塞进 `AGENTS.md`**。37 份 spec 数千行，违反「索引不复制原文」
维护契约，且每次会话都要付 token 代价。只放指针 + 覆盖映射。

### D2：覆盖映射与 CHANGE-TO-FILTER MAP 同源，物理上放在 `memory/project_overview.md`

**选择**：扩展 `memory/project_overview.md` 既有子系统速查表，加一列
`治理 spec`；`tests/AGENTS.md` 的 CHANGE-TO-FILTER MAP 保持 filter 权威；两者按「同一改动
分类」对齐，回归校验两侧名称都可解析。

**理由**：速查表已经是「子系统 → 代码路径 → 本地规则」的现成三列表，加一列是最小增量；
且 `memory/project_overview.md` 本就在 SESSION START 必读序列里，agent 读完就自然拿到映射。

**否决方案**：新建 `openspec/COVERAGE.md`。会多出一个没人读、必然腐烂的文件，且不在任何
agent 的自动读取路径上——正是本次要修的病。

### D3：引用完整性校验用「路径形态识别 + 占位符白名单」，不做 Markdown 链接解析

**选择**：从 spec 与规则文档中提取反引号包裹的、形如 `<dir>/<...>` 且首段命中已知仓内
顶层目录（`lua`/`tests`/`docs`/`scripts`/`tools`/`openspec`/`memory`/`decisions`/`lessons`/
`colors`/`data`）的 token，跳过含 `<` `>` `*` `...` 的模板形态与带 `§` 后缀的锚点尾巴，
再逐个 `filereadable`/`isdirectory`。

**理由**：spec 里的路径引用几乎全是反引号内的裸路径（`` `lua/ue/dap/android.lua` ``），
不是 Markdown 链接。既有 `extract_links` 只抓 `](...)`，对 spec 无效。

**Trade-off**：路径形态识别有漏检（例如未加反引号的路径不会被检查）。接受——本次要拦的是
「spec 声称产出某文件而该文件不存在」这类，全部是反引号形态。宁可漏检不可误报，误报会
让 `structure` filter 变成噪音源，反而被绕过。

**处理 `§` 锚点**：`docs/CONSTRAINTS.md §三 C8` 这类引用把 `§...` 后缀剥掉再校验文件本身。

### D4：8 条 FAIL 按根因分三类处置，宿主类走能力守卫

已定位的根因：

| # | 用例 | 根因 | 处置 |
|---|---|---|---|
| 1 | `platform_spec` macOS 工具断言 | 断言 `m.ios_deploy_entry()` 无错，但 `exepath("ios-deploy")` 在 Windows 宿主为空 → 返回 fail-closed 错误。**实现正确，测试假设错** | 按宿主能力守卫：仅在能解析到该工具时断言成功路径；否则断言其 fail-closed 语义（与 `host-platform-driver` spec「能力不存在时 fail closed」一致） |
| 2 | `ue_context_spec` `assert_eq("adb", ...)` | 本机 `PATH` 里存在真实 `C:\WINDOWS\adb.EXE`，`adb_executable()` 按设计返回 `exepath` 结果。**实现正确，测试把「未解析时的 fallback 字面量」当成不变量** | 断言改为「argv[1] 以 `adb` 结尾（basename 匹配）」，保留 `-s <serial>` 顺序断言（`global-android-device-selection` 的真实不变量是 `-s` 存在与顺序，不是可执行文件字面量） |
| 3 | `ue_context_spec` markdown 断言 | 同 #2 的下游 | 同 #2 |
| 4 | `ue_api_spec` `Source/SampleGame` | `lua/ue.lua:2037` 是**注释里的示例**（`.ueprepare-scan-paths` 用法说明），非硬编码路径。断言用全文 `find` 无法区分代码与注释 | 断言收紧为「非注释行不得出现该字面量」，或改判 `PROJECT_INDEX_DIRS` 表本身不含该值 |
| 5–8 | `ue_target_integration` 4 条 | `ios/semantic.lua:104` 在 `targets.supports("IOS","semantic_cdb", host_driver)` 为假时早退（Windows 宿主 `supports=false`，已实测）。**实现正确且正是 spec 要求的 fail-closed**；测试注入了 deps 却没注入 host_driver | 用例注入 macOS host driver（该 spec 域其它用例已用 `require("utils.platform.macos")` 这么做，共 8 处），使 IOS 分支可在任意宿主上被验证 |

**统一原则**：8 条全部是「测试把宿主偶然事实当成不变量」，**没有一条是实现漂移**。因此
本次收敛不改 `lua/**` 运行时。这个结论已在 spec 侧固化为 `spec-authority-loop` 的
「宿主相关失败按能力守卫」scenario：禁止用注入假可执行文件的方式让断言碰巧通过。

**否决方案**：把这 8 条标记为 skip/known-fail。会让红灯常态化，正是本次要根治的病。

### D5：先修 spec（反向对齐），再补回归，最后收敛 FAIL

顺序上先把 7 份 delta 落到主规格，再写新回归，最后修用例。理由：新回归（引用完整性）
一旦上线，未修正的悬空引用会立刻 FAIL；若顺序颠倒，会出现「为了让新测试过而临时改 spec」
的倒置压力。

## Risks / Trade-offs

- **[SESSION START 变长，agent 可能跳读]** → spec 一步明确写「按改动范围读，不遍历」，
  并给出覆盖映射一步定位；不引入新的必读全文。
- **[引用完整性回归误报导致被绕过]** → 保守策略（只查反引号内命中顶层目录白名单的路径，
  跳过一切模板形态），宁漏不误；FAIL 输出必须打印「哪条引用、在哪个文件」，可直接修。
- **[覆盖映射双份维护（memory 表 + tests filter 表）]** → 回归校验两侧名称可解析，
  且维护契约要求同步；两表本就服务不同问题（找 spec / 找 filter），合并会两头不讨好。
- **[「spec 一致性」是人判断，可能被敷衍]** → 通过 changelog Validation 字段强制留痕
  （三选一：同步 spec / 立 change / 判定无 spec 影响），把敷衍变成可审计的显式声明。
- **[修 8 条用例时可能掩盖真实缺陷]** → 每条的处置都必须能指向一条 spec requirement 作为
  「为什么这才是不变量」的依据（见 D4 表格最后一列）；无法指向 spec 的一律按实现漂移处理。
- **[`lua/nio`、`lua/trouble` 是 vendored 第三方目录]** → 它们已有 `AGENTS.md` 且已被
  `structure_spec` 的 `MAJOR_DIRS` 覆盖，本次只把 spec 清单补齐到与回归一致；不为它们
  编造 capability，按「显式声明无对应 capability」处理。

## Migration Plan

纯文档 + 测试改动，无运行时迁移、无数据格式变更。回滚 = `git revert` 单个提交。
上线顺序即 D5；每步后跑 `structure` filter，全部完成后跑全量并要求 0 FAIL。

## Open Questions

- `docs/plans/2026-06-03-android-dap-handshake-rootcause.md` 已随脱敏移除。本次按「结论保留
  在 spec + CONSTRAINTS §二，spec 不再要求该文件」处理。若后续需要重建该报告，属独立
  change，不阻塞本次。
