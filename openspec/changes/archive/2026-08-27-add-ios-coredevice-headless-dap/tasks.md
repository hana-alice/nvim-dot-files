## 1. 锁定 CoreDevice 行为合同

- [x] 1.1 在 `tests/cases/dap_spec.lua` 增加 CoreDevice config 用例，断言
  `target create` → `device select` → `device process attach -p` 顺序、IOS owner/backend/PID metadata、
  无 legacy bridge/`remote-ios` 命令，并重跑 `nvim --headless -l tests/run.lua dap` 看到新用例先红后绿。
- [x] 1.2 为 installed app、launch、process list、UUID 与 terminate/absence 结果增加结构化 JSON parser
  fixtures，覆盖缺字段、非正 PID、device/bundle mismatch、重复匹配与 PID reuse；用 `dap` filter 验证
  所有 fail-closed 分支。
- [x] 1.3 保留现有 legacy config/parser 回归并补 backend 分派断言，验证 legacy 仍要求 DeviceSupport/
  `ios-deploy`、CoreDevice 不要求这些工具且两个 backend 都不 fallback；运行 `dap` 与 `platform` filters。

## 2. 实现 CoreDevice production pipeline

- [x] 2.1 重构 `lua/ue/dap/ios.lua` 的共享 context/adapter/listener 与 backend-specific strategy，冻结
  project tuple、device、backend、bundle、binary/dSYM、PID 和 adapter 到 session metadata；用 `dap`
  回归验证 session 后切 target/device 不改变 owner snapshot。
- [x] 2.2 在 iOS DAP process helper 中实现 async `devicectl --json-output` 执行与临时文件清理，并实现
  exact installed app/process identity query；用 parser fixtures 和 `dap` filter 验证 stdout table 不被当成
  稳定接口、每条失败边都返回可操作错误。
- [x] 2.3 实现 CoreDevice debug-launch：以 `--terminate-existing --start-stopped` 启动、解析并复验
  device/bundle/正 PID 后才启动 adapter；通过 argv/config 测试及显式真机 `devicectl` JSON 观察结果验证。
- [x] 2.4 实现 CoreDevice ordinary attach：只接受当前结构化 process list 中唯一匹配冻结 bundle 的正 PID，
  不消费普通 launch 的历史 PID；用 running/absent/duplicate/mismatch fixtures 和 `dap` filter 验证。
- [x] 2.5 在 adapter 启动前异步比较 local Mach-O/dSYM UUID，并在 attach 完成后的 `postRunCommands`
  输出 loaded-main UUID OK/MISMATCH marker；production/raw listener 必须在首次 continue 前消费 marker，
  用匹配/不匹配 fixtures、raw-DAP attach response 与真机 loaded UUID 证据验证。
- [x] 2.6 将 bootstrap failure、user stop、adapter exit 与 Vim exit 收敛到一次 owner-scoped cleanup：先
  non-terminating disconnect；debug-launch 再按冻结 device/PID terminate + absence probe，ordinary attach
  只复验原进程仍存活；用重复 cleanup、错 PID/device 与 timeout 用例验证无双重副作用、无跨 session 终止。

## 3. 打通 Neovim headless 真机调试

- [x] 3.1 扩展 `tools/nvim_ios_dap_smoketest.lua` 的显式 CoreDevice 输入与 production handler 调用，结果只
  保留 basename/line/boolean/error code/digest；在 `tests/cases/ios_dap_probe_spec.lua` 增加 redaction 与
  “不得选择第一台设备/不得写真实 PID”断言，并运行 `ios_dap_probe` filter。
- [x] 3.2 使用显式 selected Xcode、设备、bundle、running PID、matching binary/dSYM 与 source:line 先运行
  `tools/ios_dap_protocol_probe.py attach`，验证 CLI attach、raw-DAP verified breakpoint、breakpoint stop、
  exact source frame、detach 与 app survival 全部 passed；证据仅写入脱敏 artifact。
- [x] 3.3 使用同一显式 identity 运行 `nvim --headless -l tools/nvim_ios_dap_smoketest.lua` 的 attach 模式，
  验证 production handler 的 verified breakpoint、真实 source frame、expression 与 cleanup 全部 passed。
- [x] 3.4 从已停止应用运行 headless smoke 的 launch 模式，验证 start-stopped PID 在断点下发前不运行、首次
  continue 后命中精确 source:line、expression 成功且 cleanup 后捕获 PID 不存在；若外部 dSYM/source
  artifact 不匹配，诚实记录 blocked 并修复 artifact 流程后重跑，不能以 symbol-only 结果代替。

## 4. 同步契约与用户说明

- [x] 4.1 将完成的 delta 同步到 `openspec/specs/ios-device-debug-workflow/spec.md`，并更新
  `docs/architecture/overview.md`、`docs/TOOLING.md`、README/中文 README 中 CoreDevice 与 legacy 的
  独立路径、前置条件、headless 命令和成功判据；运行 `openspec validate add-ios-coredevice-headless-dap --strict`
  与 `nvim --headless -l tests/run.lua structure`。
- [x] 4.2 在 `docs/CONSTRAINTS.md`/`lessons/README.md` 记录经真机证明的 CoreDevice DAP 命令顺序、JSON-only
  identity 与 cleanup 陷阱，并在 `docs/changelog.md` Unreleased 追加条目及完整 Validation；运行
  `git diff --check` 和敏感信息扫描，确认没有真实 device、bundle、PID、证书或个人 project path。

## 5. 回归与完成门禁

- [x] 5.1 对修改的 Lua 运行项目既有 formatter/static checks，并执行最低范围
  `dap`、`platform`、`ue_platform_boundary`、`ios_dap_probe`；若改到 `targets/**` 再执行
  `ue_target_drivers`，全部 exit 0。
- [x] 5.2 运行完整 `nvim --headless -l tests/run.lua`、
  `openspec validate add-ios-coredevice-headless-dap --strict` 与 `git diff --check`，记录准确 passed 数量、
  真机 CoreDevice attach/launch 证据状态和任何未覆盖边界后才报告完成。
