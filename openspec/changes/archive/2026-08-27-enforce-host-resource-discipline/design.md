## Context

见 `proposal.md` 的 Why。`add-lightweight-cpu-awareness` 已交付常驻缓存读数；当前缺口是所有工作负载
如何共用同一决策，以及前台任务如何抑制后续后台启动。

代码审计补充了两条 proposal 未写全的事实：

- `ue_watch` 的 shader GTAGS rebuild 从 debounce timer 调入同步 `vim.system():wait()`，约 1.1s，
  同时违反既有主循环 P6 与新增宿主纪律。
- spawn API 不只 `vim.system|jobstart`：UEBuild 用 `termopen`，cindex 用 `vim.loop.spawn`，clangd 用
  `vim.lsp.rpc.start`。只扫描前两种会得到危险的假绿灯。

## Goals / Non-Goals

**Goals:**

- 建立唯一通用决策模块 `utils.host_admission`，持有水位、滞回、CPU 推迟上限和前台活动注册表。
- 提供通用的「允许即执行、否则计时重试」控制句柄，供 CDB/csearch/GTAGS/ccjson 复用。
- 用户显式前台任务正常启动，但在其生命周期内阻止新的后台批任务启动。
- watcher shader GTAGS rebuild 改为 async、可推迟、串行。
- 用覆盖全部 spawn API 的清单回归防止新增重活绕过分类。

**Non-Goals:**

- 不终止已运行的 controlled index/cindex，仅阻止新的 batch start；已有 CDB 的 build-WAW cancel 保留。
- 不操作 rustc 等外部进程。
- clangd 的 Windows PriorityClass 动态降级由 `constrain-clangd-under-cpu-pressure` 实现；本 change
  只提供它消费的通用判据与生命周期纪律。
- 不把短查询、版本探针、detached opener、DAP 协议进程误当后台 batch。

## Decisions

### 1. `utils.host_admission` 是唯一策略所有者

模块暴露：

- 纯函数 `admit(load, deferrals, opts)`；
- `options()`：读取通用 `ue.config.resources` + 环境覆盖；
- `run_when_allowed(spec)`：缓存读数允许时同步调用 `spec.start`，否则用 5s one-shot timer 重试；
- `foreground_begin/done/active`：引用计数式前台生命周期。

`ue.index._admission` 只做函数别名/薄委派，不保留阈值。旧 `UE_INDEX_CPU_*` 环境变量作为兼容
fallback；通用新入口为 `NVIM_HOST_CPU_*`。配置迁到 `resources`，不复制在 `index` 下。

替代方案：让每个子系统继续复制 `_admission`。拒绝，因为这正是 K54 的漂移根因。

### 2. 前台状态优先于 CPU 推迟上限

前台任务活动时，新的 batch 始终返回 `foreground-work-active`；CPU 的 `max_deferrals` 只防长期
CPU 高负载饿死，不得在用户仍在构建时反向启动后台索引。

`open_terminal_command` 在成功 spawn 前登记 foreground token，并在 exit/启动失败时释放；
workflow runtime 对 install/deploy 生命周期做同样登记。两者不降低自身优先级，也不等待 CPU。

### 3. 通用 queue 只负责「尚未启动」

`run_when_allowed` 的 control 可取消 pending timer，并在 start 后把取消转发给 start 返回的 cancel
function/handle。它不终止已运行工作，不写 task registry，不弹周期通知；调用方保留自己的 ownership、
完成 callback 与日志语义。

- CDB pipeline：在 writer lease 与第一步之前 gate；queued 也计入 `is_running`，build 可取消 pending。
- cindex：在 `vim.loop.spawn` 之前 gate；既有 csearch writer slot 可覆盖整个 queued+running 生命周期。
- ccjson headless subprocess：在 temp JSON 与 `vim.system` 之前 gate。
- cold GTAGS job：在 `jobstart` 前 gate，保持 prepare continuation 不重跑 scan。

### 4. shader GTAGS 提取为独立 async 模块

新增 `ue.gtags`，统一构造 GTAGS plan。同步 `UEPrepareSync` 继续调用 `build_sync`（命令名已明确说明会
阻塞）；watcher 调用 `rebuild_async`，后者经 admission 后使用 `vim.system` callback，内部串行且不在
uv timer callback 中 wait。

替代方案：只在同步函数前加 gate。拒绝，因为放行后仍会冻结主循环 1.1s。

### 5. spawn 审计采用「API 全覆盖 + 显式分类清单」

扫描 `vim.system`、`vim.fn.jobstart`/`jobstart`、`termopen`、`vim.loop.spawn`/`uv.spawn`、
`vim.lsp.rpc.start`。清单按精确 `path + symbol/anchor + 期望数量 + 分类 + 理由` 管理：

- `deferrable` 必须在同一 seam 有 `host_admission`；
- `foreground` 必须有 foreground lifecycle；
- `long-lived` 必须指向可逆 controller；
- `short/interactive/detached/dap` 可豁免，但必须写理由。

数量变化即失败，防止同一文件新增 spawn 被宽泛 file-level whitelist 吞掉。

## Risks / Trade-offs

- [queued CDB/csearch 持有逻辑 ownership 较久] → gate 放在文件 writer lease 之前；csearch 现有 begin
  已先取 lease，保持其 callback 完成模型并允许同类请求去重，后续可再下移 ownership。
- [foreground token 泄漏会永久压住后台] → 所有入口在 spawn 失败与 terminal/workflow finish 都释放；
  registry 提供 reset test seam，回归覆盖 success/fail/cancel。
- [CPU 长期高时 batch 最终仍会启动] → 保留 CPU defer cap，诚实边界是不保证宿主上限；前台活动不受 cap。
- [GTAGS async 改变 watcher API 时序] → public call 仍立即返回 `(true, "queued")`，完成/失败走结构化日志；
  watcher 本来不消费 rebuild 结果，只记录立即失败。
- [scanner 清单维护成本] → 这是有意成本：新增 spawn 必须显式声明资源类别，不能再默默裸奔。

## Migration Plan

1. 引入通用模块与配置，index 薄委派，保持已有 index 行为与环境变量兼容。
2. 接入 foreground lifecycle，使现有 background gates 立即受用户任务抑制。
3. 依次接入 CDB/cindex/ccjson/GTAGS；每个 seam 单独回归。
4. 扩展 spawn scanner，再应用 clangd controller change 完成长驻类别。
5. 任一阶段可回滚对应接入；通用模块在无读数时 fail-open，不会令功能永久停摆。
