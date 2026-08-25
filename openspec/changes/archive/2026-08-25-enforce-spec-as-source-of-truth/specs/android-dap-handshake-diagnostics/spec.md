## MODIFIED Requirements

### Requirement: 诊断报告与可复现 probe

诊断结论 SHALL 以可发现的形式存在于仓库，把 gdb 握手零响应与 source-file 断点
`3221226505` 两个 root cause 查实。原始诊断报告已随公开镜像的历史脱敏被移除，因此本
capability 的产出物要求 SHALL 表述为：诊断结论与判据必须在 `docs/CONSTRAINTS.md` 的
踩坑条目与本 spec 中保留，而 MUST NOT 继续要求一个已不存在于工作树的报告文件。任何
声称已产出的诊断文件 MUST 真实存在于仓库，否则该引用 MUST 被移除或改指现存出处。

（注：本 requirement 正文故意**不**写出已移除报告的字面路径——写出它会被本 change 新增的
`spec 引用完整性回归` 当作悬空引用抦下，形成自我矛盾。已实测确认：写回该路径会使
`structure` filter FAIL。）

#### Scenario: 结论出处真实存在

- **WHEN** AI agent 或贡献者查阅 Android DAP 握手 root cause 结论
- **THEN** 结论可从本 spec 的 requirement 与 `docs/CONSTRAINTS.md` 的踩坑条目读到
- **AND** 本 spec 不引用任何已从工作树移除的报告文件路径

#### Scenario: 纯诊断、不改运行时

- **WHEN** 一次新的握手层诊断被执行
- **THEN** 它仅新增诊断记录与 `tools/` 下的 probe 脚本
- **AND** 不修改任何 `lua/ue/dap/*.lua` 运行时文件
