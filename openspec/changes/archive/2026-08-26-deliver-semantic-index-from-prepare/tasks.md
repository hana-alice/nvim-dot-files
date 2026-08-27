## 1. 证据固定（先复现，避免凭推测改）

- [x] 1.1 用探针与磁盘状态固定当前失效证据：`generation_class=missing`、
      `stats={current_runs:0,hot_runs:0,full_runs:0}`、`build.status="running"` 永久卡住、
      零 index 构建日志。记录到 change 的 evidence 说明中。
- [x] 1.2 确认 `ambiguous-context` 误分类的确切代码路径：
      `semantic_sidecar.lua` 聚合出 `ambiguous-context` → `semantic_navigation.semantic_failure`
      直接采信 `response.state` → 渲染候选。补一条失败用例锁住当前错误行为。

## 2. C++ `gd` 诚实失败（P12，用户可感知的直接修复）

- [x] 2.1 在语义终态归类处加 readiness 判据：`generation_class == "missing"` 或无 proven TU
      context 时，强制终态为 `unavailable` + readiness reason，不得为 `ambiguous-context`。
- [x] 2.2 `ambiguous-context` 仅当候选全部来自已证明 TU context 时才成立；否则降级为
      `unavailable`。
- [x] 2.3 失败提示 SHALL 说明补救动作（index 构建中 / 构建失败 / 需重跑 prepare），
      MUST NOT 只说"unavailable"。
- [x] 2.4 用例：唯一定义 + index 未就绪 → `unavailable`，且**无候选列表**。

## 3. index 构建可观测（含用户要求的进度条）

- [x] 3.1 `build_phase_async` 接入进度指示：复用 `utils.async_launcher` / fidget 通道，
      显示 phase + 进展；遵守 P5（start + 中段更新，成功自然消退，不周期刷屏）。
- [x] 3.2 子进程 stdout/stderr 增量解析出可用进展信息（参考 K51 的做法：`-u` + 分步 banner +
      流式落盘；注意 jobstart data 块非行对齐，须 pending-buffer 拼行）。
- [x] 3.3 构建失败 → notify + `utils.log` 结构化落盘（phase、exit code、stderr 尾部）。
      当前失败分支完全静默，这是本次故障不可诊断的直接原因。
- [x] 3.4 交付不完整（`full.json` 在但 manifest/selection/promotion 缺失）视为 error 并可见。
- [x] 3.5 用例：注入失败的构建 → 断言 notify 发生、日志含 phase/exit code、
      `state.build.status == "error"` 且 `finished_at ~= 0`、成功计数未增加。

## 4. 中断自愈

- [x] 4.1 启动或首次索引操作时检测孤儿 `running`（owner PID 已死）→ 复位并重新调度或明确告知。
- [x] 4.2 owner 进程仍存活时 MUST NOT 抢占（保护另一个 Neovim 的在飞构建）。
- [x] 4.3 `file_lock` 孤儿 lease 回收在本路径上验证可用（已知 `process_alive` 支持，需在
      index build lock 上确证）。
- [x] 4.4 用例：伪造 `status="running"` + 不存在的 PID → 复位；伪造存活 PID → 不抢占。

## 5. prepare 交付语义与产物清理

- [x] 5.1 prepare 完成语义覆盖 index readiness：CDB 完成但 index 未就绪时，状态与提示
      SHALL 表明 index 构建中，MUST NOT 让用户认为已整体完成。
- [x] 5.2 成功后清理 `.pre-pch.bak` / `.pre-unify.bak` 中间备份（本机现存 492MB）。
- [x] 5.3 陈旧 controlled CDB（generation 不匹配且无有效 manifest）失效或清除，且可观测；
      MUST NOT 跨 project bucket / platform 分片误删（K27/C5b）。
- [x] 5.4 用例：中间备份被清理且当前产物保留；generation 不匹配的陈旧 CDB 不计入 readiness。

## 6. 按用户习惯路径验收（硬约束）

- [x] 6.1 **全部验收沿 `set platform → set project → build → :UEPrepare`**。
      MUST NOT 依赖手动 `:UEIndexFull` 或其他平台专属命令 —— 那正是本次要消除的心智负担。
- [x] 6.2 真实验收：该路径走完后，`VulkanResources.h:1167` 的 `WrapAroundAllocateMemory`
      `gd` SHALL 直接到达 `VulkanRHI.cpp:3594`，无候选列表。
- [x] 6.3 若 index 构建期间用户触发 `gd`：SHALL 得到"构建中"的诚实反馈，而非候选列表。

## 7. 回归与收尾

- [x] 7.1 分范围：`index_generation` `cpp_semantic_index` `clangd_commands` `ue_api`
      `cpp_semantic_context` `ue_goto_behavior`。
- [x] 7.2 提交前全量 `nvim --headless -l tests/run.lua`（跨 ue.lua 接缝）。
- [x] 7.3 `ue.lua` 行数不得超过 ratchet（当前 10562）——新增逻辑落在 `lua/ue/index/` 或新模块。
- [ ] 7.4 changelog 记一条，Validation 写明所跑范围与 spec 一致性处置。
- [x] 7.5 sync specs → archive change。
