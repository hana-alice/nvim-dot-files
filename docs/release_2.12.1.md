# hana-alice/nvim 2.12.1 — clangd 回收遵守真实空闲与 prepare 边界

> 版本：2.12.1
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-27
> 类型：Patch；修复索引后回收的定时器与安全守卫。
> 发布流程：按用户授权同步、脱敏归档、拉取/rebase、提交并推送；tag 待明确请求。

## 1. 本次交付范围

- `ue.clangd_memory_reclaim` 为进度轮次增加身份：新进度使旧回收定时器及忙碌重试失效，只允许最新一轮完成后的回收。
- 独立按键回调记录用户活动，普通模式导航后也须等待完整空闲窗口；测试重置会注销回调。
- `ue.index.prepare_observer.is_running()` 读取真实 prepare owner，覆盖没有 index job 的 bootstrap/CDB 准备阶段。
- 回收探针开启新的修复 revision。开始采集不等于用户真实会话已通过验收。
- 主规格同步记录上述守卫与验收范围，并将 Windows 内存不归还的描述限定于已有实验，避免从缺少 malloc_trim 推导普遍结论。

## 2. 验证与剩余范围

提交前串行全量 `nvim --headless -l tests/run.lua`：**4400/4400 通过、0 失败、2 SKIP**。两项跳过：未提供私有 GTAGS 原生证明输入；当前宿主具备 PCH 能力，不适用不支持场景。

定向回归：新增四个用例在修复前全部失败，修复后 `clangd_memory_reclaim` 12/12；另 11 个相关 filter 合计 451/451，零失败、零跳过。
三个修改的 Lua 文件通过 bare-globals AST lint，独立复审通过。

隔离的真实 Neovide + Neovim LSP + clangd 22.1.5 夹具：40 TU、`-j=2`、默认 60 秒空闲窗口。
41 项索引结束后 60.03 秒才退出旧客户端，约 0.93 秒后两个原 buffer 均附加到新客户端；
重启前后跨 TU definition 查询成功，文本与 changedtick 不变。新客户端加载进度仅 1 项，
继续观察 65.22 秒没有第二次回收。41 个 shard 保留，两个 clangd 正常退出，会话 TEMP 已清理，
宿主 `%TEMP%` 中 `preamble-*.pch` 为 0。

未验收：完整 UE 工程的长期内存与索引性能，以及完整 LazyVim 自动启动链；夹具使用显式 root 和测试启动命令，不能推广为这些范围已通过。
不包含工作区原有的 Snacks 与编辑器窗口测试改动。

## 3. 本次工作归档

### 2026-10-27 — clangd 回收等待完整空闲窗口与 prepare 完成

**Task**
- 继续验证索引后回收，确保用户活动、新一轮索引与 prepare 不会被旧回收定时器打断。

**Implemented**
- `lua/ue/clangd_memory_reclaim.lua`：每次进度更新使旧定时器及重试失效；只允许最新索引结束后的回收。
- 用独立 `vim.on_key` 回调记录活动时间，普通模式导航后也须等待完整空闲窗口；测试重置会注销回调。
- `lua/ue/index/prepare_observer.lua` 的 `is_running()` 复用真实 prepare owner，覆盖尚无 index job 的准备阶段。
- 回收探针开启新的修复 revision；这只表示开始采集，不代表真实环境验收完成。
- 同步 `openspec/specs/cpp-semantic-index-coverage/spec.md`：记录回收守卫与验证边界，将内存保留结论限定于已有实验。

**Pitfalls / Gotchas**
- normal mode 不等于空闲；index job 为空也不等于 UEPrepare 已结束。
- 新一轮索引结束前后，上一轮尚未到期的初始定时器与忙碌重试都必须失效。

**Validation**
- 提交前串行全量 `nvim --headless -l tests/run.lua`：4400/4400，零失败、2 SKIP（私有 GTAGS 原生证明输入未提供；当前宿主具备 PCH 能力，不适用不支持场景）。
- 新增四个回归在修复前全部失败；修复后 `clangd_memory_reclaim` 12/12。
- `clangd_temp`、`index_delivery`、`index_generation`、`index_subset_async`、`cpp_semantic_index`、
  `clangd_commands`、`ue_api`、`ue_platform_boundary`、`smoke`、`stability`、`structure` 合计 451/451，零失败、零跳过。
- 修改的三个 Lua 文件通过 bare-globals AST lint；独立复审通过。
- 同步后的 `cpp-semantic-index-coverage` 通过 OpenSpec strict 校验。
- 隐藏的真实 Neovide + Neovim LSP + clangd 22.1.5 夹具（40 TU、`-j=2`、默认 60 秒等待）通过：
  索引进度 41 项结束后 60.03 秒才退出旧客户端，约 0.93 秒后两个原 buffer 均附加到新客户端；
  重启前后跨 TU definition 查询成功，文本与 changedtick 不变。新客户端加载进度仅 1 项，继续观察 65.22 秒无第二次回收。
- 夹具保留 41 个 shard，两个 clangd 均正常退出；会话 TEMP 已清理，宿主 `%TEMP%` 中 `preamble-*.pch` 为 0。
  夹具通过显式 root 与测试 `LspStart` 命令调用生产 cmd/on_attach/restart，未覆盖完整 LazyVim 自动启动链。

**Follow-ups**
- 完整 UE 工程的长期内存与索引性能尚未重新测量；夹具结果不能推广为全工程验收。
