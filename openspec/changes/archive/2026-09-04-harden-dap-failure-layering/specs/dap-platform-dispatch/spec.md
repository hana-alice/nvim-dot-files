## ADDED Requirements

### Requirement: dispatch 层失败 SHALL 携带层归属与 owner

DAP dispatch seam（注册过滤、会话归属校验、attach/launch/stop/status/reattach 路由）产生的
用户可见失败 SHALL 携带层归属与 owner，使「宿主/目标组合不兼容」「会话归属缺失」这类
**dispatch 自身的**失败不会被读成设备侧或调试引擎侧问题。

MUST NOT 发出不带层归属的 dispatch 失败。

#### Scenario: 不兼容组合报为 dispatch 归属

- **WHEN** 用户在 matrix 未声明兼容的 host/target 组合上触发 attach 或 launch
- **THEN** 失败 SHALL 标明其归属为 dispatch 兼容性判定，而非设备或调试引擎
- **AND** SHALL 给出 host id、target id 与不兼容原因

#### Scenario: 会话归属缺失报为 dispatch 归属

- **WHEN** session owner 缺失或与 matrix 不一致
- **THEN** 失败 SHALL 标明其归属为 dispatch 会话归属校验
- **AND** MUST NOT 表述为设备或调试引擎故障
