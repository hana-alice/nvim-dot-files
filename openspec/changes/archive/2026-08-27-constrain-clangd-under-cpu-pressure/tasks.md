## 1. 固定缺口证据

- [x] 1.1 记录：`throttle-background-work-under-cpu-pressure` 的准入控制只挂在
      `_schedule.lua`，`rg "admit_background_phase|cpu_load" lua/ue.lua lua/plugins/ue.lua`
      零命中 → clangd 从未被节流（用户报告"复发"因此成立）。
- [x] 1.2 记录：全仓 `rg "PriorityClass|ProcessorAffinity"` 零命中 → 从无 OS 级约束。
- [x] 1.3 记录：事发时本机 `-j=20`（24 核的 83%；已先降为 12），`PriorityClass` 可写、
      `ProcessorAffinity` 受支持。
- [x] 1.4 记录：`--background-index-priority` 按 clangd --help 为 OS-specific，
      在 Windows 未经验证，不得当作已有防线。

## 2. 取得 clangd 进程句柄

- [x] 2.1 在 clangd `cmd` 工厂（`lua/plugins/ue.lua`）或 client 附着后取得 pid。
- [x] 2.2 拿不到 pid 时跳过并记录，MUST NOT 报错/阻塞启动。
- [x] 2.3 多 client / 重启 clangd 时句柄需刷新，不得对已死 pid 操作。

## 3. 动态降级（纯判定 + 可注入执行）

- [x] 3.1 复用 `utils.cpu_load` 采样与 `utils.host_admission` 的双水位滞回判据，不另写阈值。
- [x] 3.2 纯函数 `desired_priority(busy, current, opts)` → `low` / `normal`；
      滞回带维持上一状态。
- [x] 3.3 执行层注入化（便于测试）：Windows 用 `PriorityClass`；其他平台留 no-op 并记录。
- [x] 3.4 MUST NOT kill/suspend clangd；仅可逆降级。
- [x] 3.5 优先只做 PriorityClass；`ProcessorAffinity` 作为后续可选项（更激进，可能让 clangd
      在空闲时也用不满机器）。

## 4. 回归

- [x] 4.1 用例：高负载 → low；回落 → normal；滞回不抖动；负载不可测 → normal（不降级）。
- [x] 4.2 用例：无 pid / 平台不支持 → 跳过且不抛错。
- [x] 4.3 用例：实现中不得出现 kill/suspend clangd 的调用。
- [x] 4.4 分范围 `cpu_admission` `ue_api` `index_delivery` `stability`；提交前全量。
- [x] 4.5 **agent MUST NOT 自行启动真实 clangd 验证**（前次致用户机器卡死）。

## 5. 收尾

- [x] 5.1 门禁：`ue.lua` ≤10562；改动/新增文件 ≤800 行。
- [x] 5.2 changelog + spec 一致性处置。
- [x] 5.3 明确记录边界：不动 rustc 等外部进程；不承诺宿主 CPU 上限。
