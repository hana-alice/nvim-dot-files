# hana-alice/nvim 2.1.2 — Recover editing after device debug failures

> Date: 2026-10-10
> Type: Patch; restore source views after debug failures.
> Tag: pending explicit authorization.

### 2026-10-10 — Recover the editor after iOS device debug failures

**Task**

设备连接失败后恢复普通代码布局，并让 CoreDevice 失败反馈给出可执行的下一步。

**Implemented**

- `lua/ue/dap.lua`：adapter close 独立恢复 UI；旧会话回调不能关闭新会话，协议结束仍执行一次 frozen-owner cleanup。
- `lua/ue/dap/ios.lua` 的 bootstrap 失败与无活跃会话的 `UEResetLayout` 收起遗留面板；关闭前保存当前源码视图，
  保留光标、日志历史与无关 scratch 窗口，不调用设备进程操作。
- `lua/ue/dap/_ios_coredevice.lua`：明确找不到设备的证据归 L1，其他无法判层的失败归 L?；反馈包含命令、退出码、
  输出与重新选择设备的指引。`docs/ue_lazyvim_cheatsheet.md` 补充自动恢复和手动恢复入口。

**Pitfalls / Gotchas**

- `dapui.close()` 可能回放旧 buffer；只有关闭面板而不保存当前源码视图会丢失编辑锚点。
- UI EOF 回调不能调用可能等待设备的 target cleanup；target owner 独立执行已有 teardown。

**Validation**

- 全量 `nvim --headless -l tests/run.lua`：2349/2349 passed，0 failed，38 skipped；
  包含布局恢复 4/4 与 CoreDevice 24/24 回归。
- 当前 Neovim 已热加载修复；真实调试 UI 打开后执行 `UEResetLayout`，源码、光标和修改状态均保留，
  调试面板全部关闭。bootstrap 恢复与 CoreDevice 反馈也已热加载。
- OpenSpec strict 验证 41/41；改动 Lua 的语法、AST lint、对应 StyLua 检查及 diff whitespace 检查通过。
- 对全部改动文件执行外置隐私规则检查：0 命中。
- 同步 iOS debug spec 的 UI/设备 cleanup 隔离与源码视图保护踩坑。

**Follow-ups**

- 当前 CoreDevice 列出的设备 tunnel 均不可用，连接恢复后的真机 attach/launch 尚未重验。
