# hana-alice/nvim 1.6.0 — Minor Release

> Version: 1.6.0
> Repo:    https://github.com/hana-alice/nvim-dot-files
> Platform: Windows 11 + Neovide GUI (primary)
> Date:    2026-08-18
> Type:    Minor release (multi-instance state isolation, build ⇄ prepare mutual exclusion, target platform dual-axis, pipeline observability)

---

## One-line summary

UE workspace state is now safe across parallel Neovim instances and across checkouts: project data lives in canonical per-project buckets with atomic per-field publication and cross-process writer leases; the UBT build and the CDB/prepare family are mutually exclusive (the build wins — no more torn CDBs or CPU contention); the CDB python pipeline streams its log live with per-step banners and is cancellable from `:Tasks`; and target platform becomes a dual-axis model — per-project authority plus an engine-level *suggestion* — so a fresh checkout prompts an explicit one-keypress choice instead of silently building a guessed (previously Linux) platform.

## Release gate

- Full regression: `nvim --headless -l tests/run.lua` → **817/817 passed**.
- OpenSpec `multi-instance-state-isolation` extended with "engine-level target preference SHALL suggest, never inherit" (structure filter 38/38).
- New pitfall K51 (cdb pipeline × UE build WAW hazard) recorded in `docs/CONSTRAINTS.md` with lessons index synced.
- Rebased onto main (post-1.4.0/1.5.0 macOS-iOS target/host split): pipeline steps became per-step argv jobs; the `-u` unbuffered flag, per-step failure attribution, M.cancel build-mutex and :Tasks registration were re-applied on the new step runner. Post-rebase full regression: **941/947** — the 6 failures are byte-identical to the pristine-main baseline on this Windows host (pwsh/powershell.exe host-tool naming, macOS default-shell expectations, one path-separator compare) and predate this work.
- Git tag `v1.6.0` is intentionally pending explicit user confirmation.

---

## Working log (sliced from docs/changelog.md Unreleased, newest first)

### 2026-08-18 — UEBuild 新项目未设 platform 先弹 picker + engine 级 target 建议轴

**Task**

用户切换 checkout 后（per-project bucket 隔离设计）platform 需重设，但旧行为是**静默用
target_platform() 的默认值直接开建**——今天以 Linux 兜底把编译打飞。裁定：① 未显式设置时
UEBuild 先弹 picker；② picker 把「本 engine 上次用的 pair」置顶为建议；③ platform 增加
engine 级正交偏好轴，但**不做全局**、不自动继承。

**Implemented**

- `lua/ue/project_state.lua`：
  - 新增 engine 级偏好文件 `.cache/nvim-ue/target-default.json`（每次显式 `update_target`
    last-writer-wins 原子镜像；读接口 `M.engine_target_default(engine_root)`）。
    **建议非权威**：`read_state()`/构建路径不读它，仅 picker 排序用。
  - 新增 `M.target_is_set(engine_root)`：区分「用户显式选过」与「代码兜底默认」——直接查
    当前 bucket 的 `target-selection.json` 是否存在有效 platform。
- `lua/ue.lua`：
  - `build_android` 入口加 fresh-bucket 闸：`target_is_set` 为 false（且非 headless）时
    不构建，先 `set_platform(nil, {on_done=...})` 弹 picker，确认后以 `_platform_prompted`
    重入继续原构建；取消则不建。
  - `set_platform` 交互路径：platform/config 两级 picker 都把 engine 建议项**置顶**并标注
    `(last used on this engine)`；新增 `opts.on_done(ok)` 回调供构建闸续跑；测试缝
    `M._set_platform_for_test`。
- `openspec/specs/multi-instance-state-isolation/spec.md`：新增 Requirement
  「engine-level target preference SHALL suggest, never inherit」+ 两个 Scenario
  （新 bucket 不自动继承 / 未设置时构建先提示）。

**Pitfalls / Gotchas**

- 建议轴刻意不进 `read_state()`：一旦进了，它就变成事实上的继承（K43 串扰面重开）。
  权威仍只有 per-bucket `target-selection.json`。
- `update_target` 镜像偏好文件用 `pcall` 包裹——镜像失败不能拖垮权威写入。

**Validation**

- `multi_instance_state` 12/12（新增「engine target default 是建议不是权威：新 bucket
  不自动继承」并发/切换往返用例）。
- `ue_context` 6/6（新增 UEBuild fresh-bucket 闸 + picker 建议置顶源断言）。
- 全量 `nvim --headless -l tests/run.lua` **817/817 全绿**。

**Follow-ups**

- `UEPrepare` 未设 platform 时目前仍走默认值（只影响索引维度，不产生错误构建）；如需同样
  的闸可复用 `target_is_set`。

### 2026-08-18 — target_platform 无状态默认值修正：Windows host 不再回落 Linux

**Task**

`<Space>ub` 在新 checkout（无任何 `.cache/nvim-ue` 持久状态的全新项目路径）上产出
`<Target> Linux Development` → UBT `Unable to find valid SDK(s) for Linux` → exit 6。

**Implemented**

- `lua/ue.lua` `target_platform()`：底部无状态 fallback 原为 `return "Linux"`（WSL host 路线
  遗留，`a7a4db5` 引入；WSL host 已退役）。新增 Windows host（`has("win32/64")`）或盘符
  engine root（`^[A-Za-z]:[\\/]`）→ 默认 `Win64`。env override / 持久 state 优先级不变，
  只改「完全无状态」的默认值。盘符匹配内联（`is_windows_path` 声明在其后，引用会是 nil）。
- 新增测试缝 `M._target_platform_for_test`。

**Pitfalls / Gotchas**

- 报错方向盘在 platform 解析，不在 build 命令拼装：UBT 参数完全按 `target_platform()` 输出
  组装，`Linux` 是本配置自己选的，不是引擎/环境错。
- 单文件巨模块的 forward-declare 顺序坑：`target_platform`（:3288）早于 `is_windows_path`
  （:3373）定义，直接调用得 nil——需要内联模式匹配。

**Validation**

- `nvim --headless -l tests/run.lua ue_context` 5/5（新增 2 用例：Windows host 无状态默认
  Win64、env override 最高优先）。
- 全量 `nvim --headless -l tests/run.lua` **815/815 全绿**。

**Follow-ups**

- 用户在该 checkout 仍需 `:UESetProject` + `:UESetPlatform` 显式选平台（Win64 只是无状态
  兜底默认，不能替代显式选择）。

### 2026-08-18 — build ⇄ prepare WAW 互斥 + prune 降载 + pipeline 实时日志

**Task**

`<Space>ub` 编译期间后台 cdb python pipeline（prune 步骤 20 线程 include 扫描）吃满 CPU 导致编译卡顿；
UBT 报错后 pipeline 独立继续跑，日志只在进程退出时一次性落盘——手动 kill 后才弹
`ue-pipeline failed (exit 1)`。用户裁定：**编译优先不能动**；prepare 家族读取编译产物
（Module.*.rsp / receipts），与编译并跑是 WAW 冒险，必须互斥而非仅提示。

**Implemented**

- **互斥（build 赢）**：
  - `lua/ue.lua` 新增 `CORE_RT.ue_build_running()`（探测 build 终端 job 存活）；
    `prepare_async` 入口在 build 运行时**拒绝启动**（不排队，同 csearch_build_begin 政策），
    提示编译结束后再跑 `:UEPrepare`。
  - `lua/ue/cdb/pipeline.lua` 新增 `M.cancel(reason)`：`build_android`（UEBuild/UEBuildAndroidSO）
    启动时若 pipeline 在飞则 **jobstop 掉它**（经正常 on_fail→finish 路径释放 writer 槽与跨进程
    lease），并提示编译后重跑 `:UEPrepare`。理由：pipeline 的输入正被编译重写，跑完也是
    半新半旧的脏 CDB。
- **prune 降载**（只影响 :UEPrepare 链，不碰编译）：`--sample 20 → 4`（脚本自带默认 2，
  注释"2 is enough"；20 是 module 分组之前的旧参数），`--workers` 显式 4（原
  `min(20, cpu_count)`）。
- **实时日志**：
  - `lua/ue.lua` `M._logged_jobstart` 从「exit 一次性写日志」改为**边跑边落盘**
    （header 先写，逐批 append+flush，exit code 写 footer），返回值新增 `log_path`；
    并修复 jobstart 数据块**非行对齐**问题（data[1] 续接上一块未完行，尾元素可能是半行）——
    按流各留 pending buffer 拼接，避免长行被截断成多行（行为测实测踩到）。
  - `lua/ue/cdb/pipeline.lua`：python 步骤全部加 `-u`（管道下 stdout 全缓冲 → 长步骤零输出，
    与挂死不可分）；步骤间插 `echo "=== ue-pipeline step i/N: <script> ==="` banner；启动时
    notify 实时日志路径；注册进 task_registry（`:Tasks` / `<leader>X` 可列出/取消）。

**Pitfalls / Gotchas**

- jobstart 的 on_stdout data 列表**不是完整行的列表**：首元素续接前块、尾元素可能是未完行。
  直接逐元素写文件会把一行拆成几行；必须 pending-buffer 拼接（`:h channel-lines`）。
- headless 测试里 `vim.o.shell`（bash）与 shellcmdflag 可能错配，`_logged_jobstart` 行为测
  改用 argv-list（`nvim --clean -l` 子进程）绕开 shell 差异。
- `multi_instance_state`「definition cache merges distinct keys」此前在干净树上偶发失败
  （3 跑 2 挂），本轮全量通过——确认为预先存在的并发 flaky，与本改动无关，仍留观察。

**Validation**

- `nvim --headless -l tests/run.lua ue_cdb`：**22/22 全绿**（新增 5 个行为测：`-u`+banner
  命令形状、task_registry 注册、cancel→on_fail 释放 writer、build⇄prepare 互斥入口源断言、
  `_logged_jobstart` 流式落盘+行拼接往返）。
- 全量 `nvim --headless -l tests/run.lua`：**813/813 全绿**。

**Follow-ups**

- `multi_instance_state` 并发 flaky 留观察（本轮通过，历史偶发）。
- fast_swap（UESetPlatform）路径读的是已存在的 shards 而非 rsp，暂未加 build 互斥；如实测
  与编译撞车再补。
