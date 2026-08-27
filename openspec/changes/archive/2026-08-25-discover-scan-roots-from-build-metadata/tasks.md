## 1. 推导核心（有界浅扫 + 收敛）

- [x] 1.1 在 `lua/ue.lua` 新增命名常量 `UE_CONST.SCAN_ROOT_DISCOVERY_MAX_DEPTH = 6`
  （不用魔法数字；design D3 已实测 depth 4/5/6 = 4/7/10ms）与模块声明模式集合
  （`*.Build.cs` / `*.uplugin` / `*.uproject`）
- [x] 1.2 实现 `CORE_RT.discover_module_dirs(project_root)`：用 `vim.uv.fs_scandir` 有界递归
  （depth ≤ 常量），复用既有 `UE_CONST.SCAN_EXCLUDES` 跳过排除目录，返回**项目根相对**的
  候选目录列表（含模块声明的目录）
- [x] 1.3 实现前缀收敛 `CORE_RT.converge_scan_roots(candidates)`：按前缀去重（A 是 B 祖先则只留
  A）；**必须剔除根级 `""`**（design D3 已实测：不剔除会把一切吞成「扫全根」，引入
  `Content/` 与 `.git/` 全量遍历，是比原 bug 更严重的回归）
- [x] 1.4 暴露测试缝 `M._discover_module_dirs_for_test` 与 `M._converge_scan_roots_for_test`
  （保持 `M.*` + headless 可测约定）

## 2. 接入 `project_index_dirs`（唯一收口点）

- [x] 2.1 改造 `CORE_RT.project_index_dirs`：`.ueprepare-scan-paths` 非空时**完全等于**它、
  不合并推导结果（design D5：保持「显式声明即最终答案」，不影响已在用白名单的项目）
- [x] 2.2 无白名单时计算 `去重(既有 anchor/默认结果 ∪ 推导收敛结果)`（design D4 并集护栏：
  数学上不可能缩小既有覆盖）
- [x] 2.3 推导收敛结果为空时（仅根含 `.uproject`、无其它模块声明）回落
  `UE_CONST.PROJECT_INDEX_DIRS`——空列表语义是「不扫任何东西」，必须防止
- [x] 2.4 确认返回值仍是**项目根相对目录名列表**，与 `existing_relative_dirs`
  （`lua/ue.lua:1864`）及 10 个调用方的既有契约一致，不改变形态
- [x] 2.5 保持 per-project 结果缓存语义不变（`project_index_dirs_cache`），只在推导路径接入

## 3. 缓存失效（兑现悬空承诺）

- [x] 3.1 注册 `:UEReloadScanPaths`：清空 `CORE_RT.project_index_dirs_cache` 与
  `CORE_RT.project_module_anchor_cache`（后者同样被缓存且是推导输入），并给一次 INFO 反馈
  （不刷屏，遵 P5）
- [x] 3.2 更新 `lua/ue.lua:2050` 注释，使「Use :UEReloadScanPaths to invalidate」不再是悬空承诺
- [x] 3.3 `tests/cases/commands_spec.lua` 的 `UE_COMMANDS` 冻结清单 +1 并把计数
  `81` 改为 `82`（冻结清单同步是既有契约）

## 4. 回归用例

- [x] 4.1 `tests/cases/ue_api_spec.lua` 扩充扫描根用例（已有嵌套/歧义布局用例可复用其 fixture 风格）：
  ① 嵌套布局同层新增 `Source/<Other>/Source/<M>/<M>.Build.cs` → 该目录出现在扫描根
- [x] 4.2 ② 多 `.uproject` 歧义布局 → 扫描根**不是**裸 `Source`，且不含同层无模块声明的
  工具链目录（现行用例断言的是「回退到 Source」，需按新契约更新该断言）
- [x] 4.3 ③ 标准布局（`project_root` 自身含 `.uproject`）→ 扫描根**不含** `""`/项目根，
  不退化为全根遍历
- [x] 4.4 ④ `.ueprepare-scan-paths` 非空 → 扫描根完全等于白名单，不含推导追加项
- [x] 4.5 ⑤ 并集只扩大不缩小：构造推导盲区（仅 `Shaders/` 无 `.Build.cs`）→ 结果仍含 `Shaders`
- [x] 4.6 ⑥ 排除目录不产生扫描根：`Intermediate/` 下放一个生成的 `*.Build.cs` → 不出现在扫描根
- [x] 4.7 ⑦ 推导成本有界：断言遍历深度受限（可用 fixture 造 depth 10 的深树，断言不进入超深层）
- [x] 4.8 `:UEReloadScanPaths` 用例：改白名单 → 调命令 → 同会话内扫描根随之变化（不需重启）

## 5. 文档与知识库同步

- [x] 5.1 `lua/utils/code_search/AGENTS.md`「先读」段补 `project-scan-root-discovery` spec 指针
  （目录规则声明治理 spec 是既有契约，由 `structure` filter 守护）
- [x] 5.2 `memory/project_overview.md` 子系统速查表：给「代码搜索」行的治理 spec 列补
  `project-scan-root-discovery`（覆盖映射回归会校验该 capability 存在）
- [x] 5.3 若扫描根语义写入了架构文档，同步 `docs/architecture/` 相关段落；否则显式记录无需改动

## 6. 验证与收尾

- [x] 6.1 用**真实故障项目**验证：对 `project_root` 为嵌套布局的实际项目跑推导，确认
  同层模块目录进入扫描根（对照本次审计记录的 `Source/<Proj>/{Source,Config,Plugins}` 三前缀）
- [x] 6.2 分范围回归：`ue_api` `csearch_build_guard` `ue_watch_csearch` `utils` `commands` `structure`
- [x] 6.3 **全量回归** `nvim --headless -l tests/run.lua` 全绿、退出码 0
  （当前基线 1113/1113；新增用例后计数应上升）
- [x] 6.4 `openspec validate --all` 与
  `openspec validate discover-scan-roots-from-build-metadata --strict` 全绿
- [x] 6.5 处置本次审计埋下的探针 `scan-root-coverage`：修复落地后记录一条「已修复」证据或
  按 `probe-feedback-loop` 休眠该 topic（不留悬空未处置证据）
- [x] 6.6 `docs/changelog.md` Unreleased 追加一条，Validation 写明所跑范围与结果、
  以及 spec 一致性处置（新增 1 capability + 修改 `ue-code-search`）
- [x] 6.7 评估 semver：引入新 capability → **minor**；若收尾 milestone 按 C8 四件套
  （git tag 须用户确认）
