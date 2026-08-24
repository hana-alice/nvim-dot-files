## MODIFIED Requirements

### Requirement: 设备验证范围限定

每次诊断 SHALL 显式接收并捕获一个 probe serial，并在报告中记录该 serial 的取证范围；所有设备命令、forward 与收尾清理 MUST 使用同一个捕获值。规范与脚本 MUST NOT 固定某台历史设备，也不得在 probe 运行中重读 live selection 后改投其他设备。

#### Scenario: 单机取证

- **WHEN** 以 `SERIAL-PROBE` 执行任何设备侧 probe
- **THEN** 所有设备命令 SHALL 指定 `-s SERIAL-PROBE`
- **AND** 报告 SHALL 标明结论仅覆盖 `SERIAL-PROBE`，其他设备需各自取证
- **AND** 收尾清理 SHALL 对同一 `SERIAL-PROBE` 执行 lldb-server 清理、移除本次 adb forward，并确认目标 `TracerPid=0`
