# Tasks — macOS/iOS 编译语义准备

## 1. 锁定现有行为

- [ ] 1.1 为当前 `UEPrepare` 的 prepare-only、RSP-first、失败保留旧 CDB 行为补回归测试。
- [x] 1.2 为 Windows/Linux/Android 现有构建命令规划补契约测试，防止平台扩展改变 argv、cwd 或路径语义。
- [ ] 1.3 建立 Apple response file fixtures，覆盖 `Mac`、`IOS`、不同 configuration 与 foreign-target 拒绝场景。

## 2. 独立 target-driver 架构

- [x] 2.1 新增 `lua/ue/targets/` registry、contract 与 policy-free `_common`，明确 host OS 与 Unreal target 为正交维度。
- [x] 2.2 分别建立 Android、IOS、Mac、Win64、Linux target driver；每个模块独立声明 capabilities、build plan 与 RSP 分类。
- [x] 2.3 先以回归测试锁定现有 Android 行为，再把 Android build/PowerShell/SO 策略等价迁出 `lua/ue.lua`，不改算法或 UX。
- [x] 2.4 禁止 IOS driver 调用 Mac/Android driver，禁止 Mac driver 调用 IOS/Android driver；共享 helper 只能包含无状态、无平台策略的校验与归一化。
- [ ] 2.5 让 `lua/ue.lua` 只保留命令注册、上下文解析、任务编排与 target-driver dispatch，不保留 target-specific 脚本名称或条件分支。
- [x] 2.6 为 registry、contract、unsupported capability、跨 driver 隔离和核心层无平台策略补结构/契约测试。

## 3. 宿主原生编译规划

- [x] 3.1 在 host driver 中增加统一的 UE executable/path/cwd 返回契约；target argv 仍由各 target driver 负责。
- [x] 3.2 为 macOS host 实现 `Engine/Build/BatchFiles/Mac/Build.sh` 入口，不经过 Windows 路径转换或 `.exe`。
- [x] 3.3 在 IOS 与 Mac driver 中分别构造 target/platform/configuration/project 参数，并覆盖空格路径、缺失脚本和 unsupported host-target 测试。
- [x] 3.4 保持所有长命令使用 argv 数组和异步执行器。

## 4. 编译与准备编排

- [x] 4.1 新增 `:UECompileForNvim`，按 preflight → target-driver build → prepare → refresh 顺序执行。
- [x] 4.2 确保编译失败或取消时不进入 prepare，不发布部分 CDB，不替换最后成功状态。
- [x] 4.3 保持 `:UEPrepare` 不触发编译；缺少 RSP 时给出明确下一步。
- [x] 4.4 明确排除 Cook、Stage、Package、Archive、Deploy、Install 和 Run 参数。

## 5. Apple RSP 与上下文隔离

- [x] 5.1 在 IOS driver 中支持并分类 IOS `.cpp.o.rsp`、`.rsp`、`.response`，保留真实 cwd/argv。
- [x] 5.2 在 Mac driver 中独立支持并分类 Mac response files，不调用 IOS classifier。
- [x] 5.3 各 driver 按 project/target/platform/configuration 证明候选来源并拒绝 foreign context。
- [x] 5.4 保持头文件只使用编译器依赖证据，不生成伪 standalone command。
- [x] 5.5 为生成结果记录 response file provenance 与输入/输出指纹。

## 6. 工具链与增量状态

- [x] 6.1 按仓库约束检查 clangd 路径和版本，区分缺失、不兼容、不可解析与可用。
- [x] 6.2 实现 CDB 内容未变化时 no-op，避免无效写入、shard 切换和 clangd 重启。
- [ ] 6.3 扩展 `UECDBStatus` 或等价 surface，显示当前 tuple、来源数量、指纹、clangd 版本和最近结果。
- [ ] 6.4 对日志、错误和状态中的用户路径及环境值执行脱敏。

## 7. 文档与验证

- [x] 7.1 更新 README、UE IDE bootstrap、architecture overview、命令帮助和 cheatsheet，说明 host/target 双层架构，准确区分 Tree-sitter 与 clangd，并声明 Android SO/iOS DAP 非目标。
- [x] 7.2 运行受影响的 target-driver、CDB、semantic context、host platform、commands、UE API 与 keymap 测试。
- [ ] 7.3 在 macOS headless 环境分别验证 IOS 与 Mac 命令规划、取消、失败保留与 no-op；不得要求真实 iOS 设备或证书。
- [x] 7.4 运行 lint、静态检查与完整测试套件，修复本变更暴露或造成的跨平台失败。
- [x] 7.5 在实现完成后更新 changelog/milestone，并记录未覆盖的真实大型工程性能风险。
