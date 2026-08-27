# lua/ue/index/ — clangd 受控 BackgroundIndex 子系统（前 ue.lua INDEX_FN/INDEX_RT）

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。
> 来历：F1 split phase-1（health-check 2026-07）——从 10k 行 ue.lua 机械切出的
> 2005–3302 index 块。**行为零变化**是本次切分的硬约束。

## 用途

current / hot / full 三相受控 BackgroundIndex：模块记录/持久化（`_state`），generation
manifest 与 coverage selector（`_generation`），交付就绪判定与 prepare 汇报口径（`_delivery`），
compiler-authored UBT unity / exact fallback CDB 生成（`_build`），
phase 调度与交付 deadline（`_schedule`），通用宿主策略薄委派（`_admission` → `utils.host_admission`），
readiness 磁盘自愈（`_recover`），以及只跟随 chosen manifest fingerprint 的 clangd 重启（`_clangd`）。

## 结构契约

- `init.lua` 是唯一 require 入口；子模块是 loader 风格
  `return function(M, core)`——共享 `core.h`（helpers）/ `core.RT`（运行时）/
  `core.deps`（ue.lua 注入的闭包），不引全局。
- **`M.setup(deps)` 必须先于任何索引操作**（ue.lua 在原块位置调用）。deps 是
  对 ue.lua chunk-local 的 late-bound 闭包（scope resolvers / status_root_key /
  *_index_dirty / statusline 刷新 / read_all / write_all / core_rt）。新增依赖走 deps，
  不得反向 `require("ue")`（会循环）。
- `M._rt` 与 ue.lua 的 `INDEX_RT` 是**同一张表**（活引用）；:UESetProject
  清理、status cache 直接改它。别做防御性拷贝。
- 加载顺序 `_state → _generation → _recover → _delivery → _clangd → _build → _admission → _schedule`：基础 helper 在 `_state` 定义，
  generation/selector helper 在 `_generation` 定义，`_delivery` 消费 `_generation` 的
  `index_status_summary`，`_schedule` 消费 `_build` 的 `build_phase_async`；兄弟模块顶部 alias；
  不得反向依赖后加载模块。
- **后台重活必须让路**：受控索引在**启动前** MUST 经 `_admission` 薄委派到
  `utils.host_admission`；阈值只能在通用模块/`ue.config.resources` 存一份，index 不得复制。
  高于高水位推迟启动（双水位滞回 + 推迟上限防饿死）。负载采样 MUST NOT spawn 子进程（K40），
  MUST NOT 用 `uv.loadavg`（Windows 恒 0）。已在跑的构建 MUST NOT 被杀。
  我们只抑制**自己**的工作，MUST NOT 操作 rustc 等外部进程。
- **readiness MUST NOT 只信进程内账本**：账本丢失时经 `_recover` 从磁盘 manifest
  （generation/build_key/CDB 签名校验，fail closed）重建；MUST NOT 因账本丢失要求重跑 prepare。
  报 `ready` MUST 自证（非空 index_path/fingerprint/coverage 且文件存在）。
- **交付调度不得被普通编辑饿死**：prepare 的完成路径 MUST 走 `schedule_prepare_delivery`
  （秒级 deadline + `protect`），MUST NOT 用 `full=true` 的 opportunistic refresh——后者落到
  `idle_cold_ms`(120s) 且会被任何后续 refresh 重排，实测导致 `full` 永不触发。
- **交付可观测是硬约束**：index 构建失败/中断 MUST notify + 落 `utils.log`；`running` 必须携带
  `owner_pid` 使其跨进程可 falsify；prepare 的完成汇报 MUST 经 `_delivery` 陈述 index 真实状态，
  MUST NOT 在构建中/失败时暗示语义层已就绪（用户不应被要求记住平台专属索引命令）。

## 宪法级坑（权威在 ../../../docs/CONSTRAINTS.md）

- clangd 固定 `--enable-config=false`；不得恢复 `.clangd` `External.File`、`--index-file`
  或把 monolithic binary index 当作 definition authority（K41）。
- current/hot/full 只允许同 generation 覆盖超集晋升；较窄 phase 完成不得替换已有 full。
- controlled CDB 必须保留 active build 的 exact argv/cwd，并携带 portable
  `nvim_ue_members` / `nvim_ue_module_root`；不得靠目录或文件名猜 unity membership。
- partition 与 pipeline 串行（2026-06-25 撕裂）；build_phase 单 job（RT.job）。

## 改动 → 必跑回归

改 `index/**` → `index_generation` `cpp_semantic_index` `clangd_commands` `ue_api`；
跨 ue.lua 接缝（setup deps / re-export）→ 提交前全量。

## 先读

`../../../docs/health-check-2026-07.md`（F1 切分大纲）、
`../../../docs/architecture/overview.md`。

**治理 spec**（可观察行为的权威；与本文冲突时以 spec 为准）：
`../../../openspec/specs/cpp-semantic-index-coverage/spec.md`。
