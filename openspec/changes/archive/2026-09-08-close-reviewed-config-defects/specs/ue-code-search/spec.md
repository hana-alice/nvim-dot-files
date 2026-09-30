## ADDED Requirements

### Requirement: 索引读取只读且发布保留上一份完整索引

索引可用性检查 SHALL 仅检查正式发布路径，并验证有界的格式头、尾与区段 offset；MUST NOT 基于文件大小把暂存文件提升为正式索引。reset 和 add SHALL 先完成暂存产物，再原子替换正式路径；写入、merge 或发布失败 MUST NOT 提前删除或截断原有正式索引。

#### Scenario: 读取遇到仍在构建的暂存索引
- **WHEN** writer 持有 lease 且存在暂存文件，正式索引缺失或不可用
- **THEN** 读取 SHALL 返回不可用，并保留正式及暂存文件原状
- **AND** MUST NOT 偷走 writer 暂存路径或把其视为已提交数据

#### Scenario: reset 失败或尚未读完文件清单
- **WHEN** 正式索引原本完整，而新 reset 尚未完成或输入清单读取失败
- **THEN** 旧索引 SHALL 仍可按原字节读取
- **AND** 只有新产物完整完成后才允许替换

#### Scenario: 体积足够但不是索引
- **WHEN** 正式路径含大于 1 KiB 的随机、截断或无完整格式头尾数据
- **THEN** 可用性检查 SHALL 拒绝，不以体积作为完整性证明
