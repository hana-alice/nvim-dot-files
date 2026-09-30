# dap-platform-dispatch Specification

## Purpose

DAP adapter 的平台注册与会话分发契约：adapter 注册只按可验证的兼容 matrix 过滤，
真正执行 attach/launch/stop/status/reattach 的 handler 按「会话创建时冻结的
session owner」路由，不读取运行中途切换的 current platform 来猜。目的是避免一个
会话在生命周期中途被错误地切到另一个平台实现，也避免 attach 成功后 stop/status
被当前平台带偏。

## Requirements

### Requirement: adapter 注册必须按 matrix 过滤，不得按当前 UI 选择猜测

系统 SHALL 仅为兼容矩阵中声明为兼容的 host/target pair 注册 DAP adapter；未声明的
组合 MUST NOT 出现在候选注册表中，也 MUST NOT 因当前平台处于别的 target 就被放入候选。

#### Scenario: 不兼容组合不得注册

- **WHEN** 某个 host/target pair 未被 matrix 声明为兼容
- **THEN** 系统 SHALL NOT 注册该 adapter

### Requirement: 会话必须冻结 session owner，生命周期内不得改投

系统 SHALL 在 DAP session 创建时冻结 session owner（含 adapter 与 matrix 来源）；
后续 attach、launch、stop、status、reattach SHALL 只按该 owner 分发。当前平台、
当前 target 或 live selection 在会话建立后变化 MUST NOT 改写 session owner 或让
系统重新挑选另一个 adapter 处理已存在的会话。

#### Scenario: 平台切换后旧会话仍用原 owner

- **WHEN** 一个 DAP session 已创建，随后用户切换到另一个平台或 target
- **THEN** 该 session 的 stop/status/reattach SHALL 继续路由到最初冻结的 owner
- **AND** MUST NOT 读取新的 current platform 来改投别的 adapter

### Requirement: 会话归属缺失或与 matrix 不一致时必须显式失败

系统 SHALL 在 session metadata 缺失、owner 已失效或与当前 matrix 归属不一致时明确
失败并给出可诊断原因，MUST NOT 用当前平台、最近一次选择或别的活跃会话来补齐归属，
也 MUST NOT 静默切换到一个新 adapter 继续执行。

#### Scenario: 归属缺失不能靠当前平台补救

- **WHEN** 一个 session 缺少 owner 记录或该记录无法被验证
- **THEN** 系统 SHALL 失败并报告缺失的归属信息
- **AND** MUST NOT 使用当前平台或当前 target 作为补齐依据

### Requirement: dispatch 层失败 SHALL 携带层归属与 owner

DAP dispatch seam（注册过滤、会话归属校验、attach/launch/stop/status/reattach 路由）
产生的用户可见失败 SHALL 标明其归属为 dispatch 自身（兼容性判定或会话归属校验），
MUST NOT 被表述为设备侧或调试引擎侧问题。

#### Scenario: 不兼容组合报为 dispatch 归属

- **WHEN** 用户在 matrix 未声明兼容的 host/target 组合上触发 attach 或 launch
- **THEN** 失败 SHALL 标明其归属为 dispatch 兼容性判定
- **AND** SHALL 给出 host id、target id 与不兼容原因

## 选型与踩坑

- **选型**：session owner 在创建时一次性冻结，而不是每次 lifecycle 操作时重新解析
  current platform —— 理由：current platform/target 可在会话运行期间被用户改变，
  若每次都重新解析会让同一会话中途被错误路由到另一个平台的 handler，
  且 attach 成功后的 stop/status 可能被带偏到错的 adapter。
- **重要事项**：dispatch 层失败必须与设备侧（L2）/调试引擎侧（L3）失败区分开，
  避免「宿主/目标组合不兼容」「会话归属缺失」这类 dispatch 自身问题被误诊为设备或
  引擎故障，浪费排查时间（呼应 `dap-failure-layering` 的分层归属纪律）。
