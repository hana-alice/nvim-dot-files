## 1. 已交付的 iOS 调试实现

- [x] 1.1 冻结单次 owner 并合并重复 cleanup；旧 callback、EOF 和 Stop 由 iOS lifecycle 回归证明。
- [x] 1.2 修复 CoreDevice 初始 packet timeout；真机生产 launch、独立 CLI/raw-DAP 证明 UUID、断点、frame、求值与清理。
- [x] 1.3 交付独立会话日志与第四页兼容入口；11 条日志回归和 2 条路由回归证明输出、历史、重开与隔离，真机收到同一 PID 的 UE 输出。
- [x] 1.4 合并同机设备 route 并解析新版普通 launch identity；target/workflow 行为回归验证正常解析与拒绝不匹配。
- [x] 1.5 补齐操作手册、运行时速查及符号候选验证说明；cheatsheet 143/143、structure 78/78 通过。

## 2. 同步与发布验证

- [x] 2.1 完整运行生产代码回归；本轮实现验收 2340/2340 passed、0 failed、38 capability skipped，不将缺能力算成真机通过。
- [x] 2.2 同步主 spec 方向并记录有限等待与日志选择的踩坑；delta 与对应主 requirement 完整一致，具体常量由实现/回归维护。
- [x] 2.3 补强 evidence 生成与现有结果脱敏；验证 artifact/source basename 不再输出且真实 proof/digest 不变。
- [x] 2.4 生成里程碑交付记录并核对最终全量、严格 spec 校验和 staged 发布隐私扫描；检查全部待推送 commits 与提交消息。
