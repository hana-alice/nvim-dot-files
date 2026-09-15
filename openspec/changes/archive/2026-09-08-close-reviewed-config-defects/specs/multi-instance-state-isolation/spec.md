## ADDED Requirements

### Requirement: owner 交接与过期锁回收不得破坏新 owner

锁发布 SHALL 以已写完整且带唯一 token 的非空 owner 目录为单位；过期回收者 SHALL 只删除它观察到的 owner 文件，MUST NOT 递归删除可能已被新 owner 替换的目录。探测权限不足、损坏或不可读的 owner 记录 SHALL fail closed 并给出诊断，不能当作进程已死亡。

#### Scenario: 两个回收者交错执行
- **WHEN** A 已观察旧 owner，而 B 先回收并发布新 owner
- **THEN** A MUST NOT 删除 B 的 owner 或同时获得有效 lease
- **AND** owner 异常退出后仍可通过可验证的死亡证据恢复锁

#### Scenario: watcher 切换项目且旧保存尚未完成
- **WHEN** watcher 从 A 切到 B，A 尚有排队事件、锁忙或瞬时 I/O 失败后的保存重试
- **THEN** 旧事件 SHALL 失效，保存重试 SHALL 继续只写 A
- **AND** B 的内存与磁盘 dirty 集合 MUST NOT 包含 A 的路径

#### Scenario: 持久化持续失败
- **WHEN** 原 owner 的保存持续遇到锁竞争或 I/O 失败
- **THEN** 重试 SHALL 有界退避，耗尽后只给出一次含路径与原因的告警
- **AND** MUST NOT 忙轮询或宣称已落盘；主动成功保存 SHALL 使旧重试失效

#### Scenario: 断点在两个项目之间往返
- **WHEN** 没有活跃 DAP 会话时从 A 切到 B 再切回 A
- **THEN** 旧 bucket 的断点 SHALL 先保存并从其管理的 live store 移除，再恢复新 bucket
- **AND** 共用 engine 源文件的断点 SHALL 仍按项目隔离

#### Scenario: 活跃调试会话期间切换项目
- **WHEN** DAP 会话仍属于 A 而用户选择 B
- **THEN** 断点 bucket 交接 SHALL 延迟至会话结束，不清除或重绑 A 的会话断点

#### Scenario: iOS 安装或启动完成时已选择其他项目
- **WHEN** A 的 iOS 操作开始后用户选择同 engine 下的 B，随后 A 完成
- **THEN** bundle、PID、安装及运行状态 SHALL 写回捕获的 A bucket
- **AND** 当前 live selection SHALL 保持 B
