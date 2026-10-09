## MODIFIED Requirements

### Requirement: 启动必须使用真实 bundle identifier 且不得进入 DAP

MUST：`UELaunch` 必须使用捕获设备和已安装 app 的真实 bundle identifier；CoreDevice 与
pre-iOS17 legacy backend 均不得调用 UE legacy Run 后端或自动进入 DAP。

#### Scenario: 普通启动与真机调试均可用

- **WHEN** 用户执行 `:UELaunch`，且当前宿主同时支持原生 iOS DAP
- **THEN** 系统必须只报告 run 结果，不得自动 start-stopped 或进入 DAP
- **AND** 真机调试必须通过独立 `:UEDAPLaunch ios` / `:UEDAPAttach ios` 入口执行

#### Scenario: 只存在 macOS PID attach 能力

- **WHEN** 当前宿主没有满足条件的原生 iOS 真机调试能力
- **THEN** 普通启动必须只报告 run 结果，不得把 macOS PID attach 伪装成 iOS 真机调试
