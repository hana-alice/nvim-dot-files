## Context

本文件记录已完成实现的决策。动机见 proposal.md；适用单一 macOS 宿主、已有 Xcode 与真机。
签名、artifact 和设备身份必须以本次实际证据证明；公开交付只保留脱敏摘要。

## Goals / Non-Goals

**Goals:** 让本次启动 attach、异常退出、日志与手册形成可复验的调试工作流。

**Non-Goals:** 不提供远程主机执行，不改变普通 launch 语义，不安装工具，不重建其他平台策略。

## Decisions

- CoreDevice 初始 process/image 查询各曾需约 20 秒。DAP request timeout 不控制 LLDB 内部
  gdb-remote packet timeout，因此连接前设置有限的 60 秒 packet timeout；拒绝提前 resume 或绕过 UUID。
- 同 UUID 且 DWARF verify 通过的大型 Apple parallel dSYM 仍曾引发 C++ evaluate 类型递归。
  宿主已有 LLVM 23.1.3 产物通过相同构建的真实断点与求值；默认 helper 仍使用 selected Xcode，
  手册记录候选 bundle 生成、验证和备份替换步骤，不自动升级工具。
- 单次 owner token 隔离旧 callback；session close 补足没有 terminated/exited 的 EOF 清理。
  launch 清理自建进程，attach 保留并复验原进程，重复 Stop 合并为一次 teardown。
- iOS 独立日志模块拥有 buffer、设备映射查询与低流量 reader。第四页由 frozen owner 提供，
  而不是读取当前 UI target 或借用 runInTerminal Console。日志按 PID 过滤，保留 12,000 行，
  正确拼接分块并保留滚动；wipe 后可重开且旧 callback 不能污染新 buffer。
- 现有宿主日志工具缺失时明确报错；拒绝把安装新依赖当成日志页的隐式动作。
- 同机 CoreDevice/MobileDevice 设备候选通过 hardware UDID 合并；新版普通 launch JSON
  必须以结构化 command arguments 精确复验 bundle，不能选择其他设备或猜身份。

## Risks / Trade-offs

- 不同工具版本、设备与优化构建 → 每次验证真实 UUID、resolved breakpoint、源码 frame 与求值。
- 日志 relay 为可选能力 → 显示分层错误，取消 reader 不取消 DAP 或设备进程。
- 大型符号验证较慢 → 保持异步和严格门禁，不以 UI 出现宣称成功。
- 原始真机日志与项目身份敏感 → 原始记录留在 Git directory；提交 evidence 只保留已验证摘要，
  identity 的 artifact basename 也替换为通用名。发布前扫描 staged tree、message 和实际推送范围。

## Migration Plan

旧 `UEDAPTab logcat` 保留为第四页别名。配置变更可通过 Git 恢复；本轮未改变钥匙串 ACL、
设备安全设置或默认符号生成器。主 spec 只记录方向与踩坑，固定超时与 buffer 细节留在代码/测试/手册。
