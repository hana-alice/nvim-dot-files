## Why

本轮已完成的真机排查发现：启动停止点的远端查询超时、adapter 无协议事件退出和旧会话清理会
妨碍 iOS 调试，第四页也只提供 Android 日志。补录此次已实现、已验证的交付，以便同步契约并归档。

## What Changes

- 保留严格符号/loaded-image 身份验证，修复启动 attach 的有限远端等待与会话归属清理。
- 用独立 iOS 日志 reader 读取冻结设备/PID 的日志，统一第四页入口并兼容旧命令。
- 保持普通 launch 与 debug launch 分离，补齐实际操作手册与脱敏真机证据。
- 一并交付当前 iOS 设备发现与新版 launch 结果解析修复，不改变其他 target 的流程。

## Capabilities

### New Capabilities

无新增顶层 capability。

### Modified Capabilities

- `ios-device-debug-workflow`：日志归属、异常退出与晚到清理必须属于原冻结会话。
- `ios-build-run-workflow`：更正原生 iOS DAP 已实现后的普通 launch 分离说明。

## Impact

涉及 `lua/ue/dap/`、DAP 第四页和命令、iOS target/workflow、操作手册、回归与脱敏 evidence。
使用宿主已有工具，不安装依赖。原始设备、项目、签名与调试记录保留本地，不进入发布内容。
此 change 是完成记录，不声称重新执行此前已完成的实现或真机验证。
