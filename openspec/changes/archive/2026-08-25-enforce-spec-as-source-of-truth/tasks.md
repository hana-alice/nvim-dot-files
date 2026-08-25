## 1. 反向对齐既有 spec 漂移（spec 落后于实现）

- [x] 1.1 把 `openspec/specs/test-regression-policy/spec.md` 中 5 处「根 `CLAUDE.md` 为强制
  入口 / `tests/CLAUDE.md` 为映射表」的表述改为 `AGENTS.md` 内容源 + `CLAUDE.md` stub，
  Purpose 段同步；SESSION-START 序列补探针反馈与 spec 一步；DoD 由三条改四条
- [x] 1.2 把 `openspec/specs/local-subsystem-rules/spec.md` 的本地规则内容源由 `CLAUDE.md`
  改为 `AGENTS.md`（+ stub 约定），新增「目录规则声明其治理 spec」与「本地规则不与 spec 冲突」
  两个 scenario
- [x] 1.3 把 `openspec/specs/structure-discoverability-regression/spec.md` 的目录清单补齐
  `lua/ue/index`、`lua/ue/targets`、`lua/ue/workflows`、`lua/trouble`、`lua/nio`，并把断言
  对象改为 `AGENTS.md` 源 + `CLAUDE.md` stub
- [x] 1.4 把 `openspec/specs/project-constraints-doc/spec.md` 与
  `openspec/specs/ai-knowledge-base/spec.md` 的 `CLAUDE.md` 表述更正为 `AGENTS.md`，并加入
  指向 `openspec/specs/` 与覆盖映射的导航要求
- [x] 1.5 给 `openspec/specs/probe-feedback-loop/spec.md` 补 `:UEProbeCompact`（已实现于
  `lua/utils/probe.lua:385`，spec 未声明）
- [x] 1.6 把 `openspec/specs/android-dap-handshake-diagnostics/spec.md` 对
  `docs/plans/2026-06-03-android-dap-handshake-rootcause.md` 的产出物要求改为「结论保留在
  spec + `docs/CONSTRAINTS.md §二`，不再要求已脱敏移除的报告文件」
- [x] 1.7 修掉规则文档里的悬空引用：`lua/ue/workflows/AGENTS.md` 与 `lua/ue/targets/AGENTS.md`
  指向的 3 个 `openspec/changes/<name>/` 路径改指 `openspec/changes/archive/<dated-name>/`；
  `lua/utils/code_search/AGENTS.md` 移除已删除的 `scripts/test_cached_grep.lua`
- [x] 1.8 跑 `openspec validate --all`，确认 37 份主规格仍全绿

## 2. 建立 capability 覆盖映射

- [x] 2.1 在 `memory/project_overview.md` 子系统速查表新增「治理 spec」列，为每行填入
  `openspec/specs/<capability>/spec.md`（`lua/nio`、`lua/trouble` 等无对应 capability 的写「无」）
- [x] 2.2 在 `memory/project_overview.md` 的「先读顺序」中把 spec 加为第 5 步，并说明
  「按改动范围读，不遍历 `openspec/specs/`」
- [x] 2.3 在 `tests/AGENTS.md` 的 CHANGE-TO-FILTER MAP 上方加一行交叉指针，指向
  `memory/project_overview.md` 的治理 spec 列，声明两表同源
- [x] 2.4 在 `docs/CONSTRAINTS.md §五` 导航段加入 `openspec/specs/` 与覆盖映射入口，并写明
  「spec 是可观察行为的权威；CONSTRAINTS 与本地规则不得与之冲突」

## 3. 让 spec 对三个 agent 生效（唯一注入点）

- [x] 3.1 在根 `AGENTS.md` 的 SESSION START 增加第 4 步「读改动范围对应的
  `openspec/specs/<capability>/spec.md`」，含「按范围读、不遍历」的边界说明与覆盖映射指针
- [x] 3.2 在根 `AGENTS.md` 的 Definition of Done 增加硬条件「spec 与实现一致」（行为变更同步
  spec 或立 change；spec 落后于正确实现则更正 spec），并把 Validation 要求扩展为同时记录
  spec 一致性处置
- [x] 3.3 在根 `AGENTS.md` 顶部单一内容源说明中补上 pi（当前只写了 Claude 与 Codex），
  明确三 agent 均从 `AGENTS.md` 层级读取，且禁止新增 per-agent 并行入口
- [x] 3.4 在根 `AGENTS.md` 增加「回归红灯优先于新工作」条目（与探针 report-first 并列）
- [x] 3.5 在 `docs/CONSTRAINTS.md §三` 新增一条约束（沿用 C 编号序列）承载「spec 一致性属于
  完成定义」，指回根 `AGENTS.md` DoD 与 `openspec/specs/spec-authority-loop/spec.md`
- [x] 3.6 逐个为 22 份目录级 `AGENTS.md` 的「先读」段落补治理 spec 指针（无对应 capability
  的显式写「无对应 capability」）；`CLAUDE.md` 全部保持 `@AGENTS.md` stub 不改
- [x] 3.7 在 `docs/testing-regression.md` 同步 spec 一致性与红灯优先两条纪律（filter 映射
  权威仍在该文档）

## 4. 新增可执行守护（structure filter）

- [x] 4.1 在 `tests/cases/structure_spec.lua` 新增第 ⑤ 段「spec 引用完整性」：按 D3 的
  反引号 + 顶层目录白名单 + 模板/`§` 剥离策略提取 `openspec/specs/**/spec.md` 与关键规则
  文档的仓内路径引用，逐个校验存在性，FAIL 时打印「引用 → 所在文件」
- [x] 4.2 在 `tests/cases/structure_spec.lua` 新增第 ⑥ 段「capability 覆盖映射」：校验
  `memory/project_overview.md` 治理 spec 列中的每个 capability 存在
  `openspec/specs/<capability>/spec.md`，且 `tests/AGENTS.md` 映射表中的每个 filter 能匹配到
  至少一个 `tests/cases/*_spec.lua`
- [x] 4.3 在 `tests/cases/structure_spec.lua` 新增「目录规则声明治理 spec」断言：每个
  `MAJOR_DIRS` 目录的 `AGENTS.md` 含 `openspec/specs/` 引用或显式「无对应 capability」标记
- [x] 4.4 扩展 `structure_spec.lua` 第 ④ 段：断言根 `AGENTS.md` 的 SESSION START 含
  `openspec/specs`、DoD 含 spec 一致性标记、含「红灯优先」标记
- [x] 4.5 跑 `nvim --headless -l tests/run.lua structure`，要求全绿（此步会暴露 1.x 未修完的
  悬空引用，逐个修到 0）

## 5. 收敛 8 条既有 FAIL（按 D4，均为测试假设错，不改运行时）

- [x] 5.1 `tests/cases/platform_spec.lua`「macOS 只暴露 shell 与 Apple 原生工具」：把
  `ios_deploy_entry`/`idevice_id_entry`/`ideviceinfo_entry` 三处断言改为宿主能力守卫——能
  解析到工具时断言路径含工具名，解析不到时断言返回 fail-closed 错误字符串
- [x] 5.2 `tests/cases/ue_context_spec.lua`「按引擎 state 解析项目」：`install_command[1]`
  断言由 `assert_eq("adb")` 改为 basename 匹配（允许 `exepath` 解析出的绝对路径），
  保留 `-s`/serial/`install`/`-r` 的顺序断言
- [x] 5.3 `tests/cases/ue_context_spec.lua`「Markdown 同时包含键位、命令和解析结果」：把
  `adb -s SERIAL-CONTEXT install -r` 字面断言改为对 `-s SERIAL-CONTEXT install -r` 片段断言
- [x] 5.4 `tests/cases/ue_api_spec.lua`「项目和 SO 发现不固定 Client 项目路径」：断言收紧为
  只扫非注释行（或改断 `PROJECT_INDEX_DIRS` 表内容），使 `lua/ue.lua:2037` 的用法说明注释
  不再误报
- [x] 5.5 `tests/cases/ue_target_integration_spec.lua` 4 条 IOS 用例：注入
  `require("utils.platform.macos")` 作为 host driver（与该文件既有 8 处做法一致），使
  `ios/semantic.lua` 的 `targets.supports("IOS","semantic_cdb")` 分支可在 Windows 宿主上验证
- [x] 5.6 逐条确认每处修改都能指向一条 spec requirement 作为不变量依据；任何无法指向 spec
  的失败改按实现漂移处理（此时才允许改 `lua/**`）

## 6. 验证与收尾

- [x] 6.1 跑分范围回归：`structure`、`platform`、`ue_context`、`ue_api`、
  `ue_target_integration`，各自全绿
- [x] 6.2 跑全量 `nvim --headless -l tests/run.lua`，要求 `1082/1082 passed, 0 failed`、
  退出码 0
- [x] 6.3 跑 `openspec validate --all` 与 `openspec validate enforce-spec-as-source-of-truth
  --strict`，全绿
- [x] 6.4 实测三 agent 注入：确认 pi 启动时加载根 `AGENTS.md`；确认 Codex 读同一文件；
  确认 `CLAUDE.md` 仍为单行 `@AGENTS.md` stub（三端读到同一 SESSION START 与 DoD）
- [x] 6.5 在 `docs/changelog.md` Unreleased 追加一条记录，Validation 字段写明所跑范围
  （分范围 + 全量）与结果，并按新 DoD 记录 spec 一致性处置
- [x] 6.6 评估 semver 触发：本次含新 capability `spec-authority-loop`（引入新能力 → minor）；
  若判定收尾 milestone 则按 `docs/CONSTRAINTS.md §三 C8` 执行四件套（tag 须用户确认）
