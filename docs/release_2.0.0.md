# hana-alice/nvim 2.0.0 — 统一完整文件 Git 审阅

> 日期：2026-09-29
> 类型：Major；默认 Git 入口迁移，移除重复配置和依赖。
> 状态：本地配置已交付；功能、修订后的性能门禁及全量回归通过。
> 发布流程：用户已授权 sync、archive、commit、push；tag 仍待明确授权。

### 2026-09-29 — CodeDiff 默认审阅，保留 Diffview

**Task**
- 将完整文件 diff、hunk 操作、搜索与提交管理接成连续工作流，保留用户主动使用 Diffview 的能力。

**Implemented**
- 固定 CodeDiff v4.0.6 和匹配 Windows x64 原生库；双栏保留完整正文、Changes/Staged/Conflicts 和所有 untracked。
- `<leader>gg/gG/vg` 默认审阅；`gn` 同仓 Neogit；`gm/gM/gr/gk` 历史/ref；`gh/gH` 保持 `-G --pickaxe-all` 搜索。
- Diffview `gv/gV`、Visual `gv` 和原生命令保留；修复 Visual 当前选区。Fugitive 的版本 buffer、blame、quickfix 保留。
- Neogit 使用 CodeDiff v4 与 Snacks，真实提交/取消/reflog 返回原审阅；单文件搜索确认保留范围和 rename 两侧。
- 普通编辑由 Gitsigns 管理，审阅内由 CodeDiff 管理；`hs/hu/hr` 区分暂存/取消暂存/丢弃，`hS` 表示整文件，移除旧 hunk 前缀冲突。
- 移除 AGS、无其他消费者的 Telescope 配置/lock，以及编辑器内 Lazygit 默认入口。移除 Trouble Git 查询/缓存，保留其他六类侧栏及公共 helper；宿主程序和用户配置保留。
- 隔离修复脏 buffer/过期 hunk、NUL 路径、二进制提示、刷新轮询、Windows Git 启动阻塞、大树格式化分配与关闭泄漏。
- Windows Git 候选解析归属 Windows driver，复用平台 path_key/工具解析，不增加架构 allowlist 例外。
- 正常打开不自动下载；显式 `:Lazy` build 强制重装对应原生库。没有热替换或重启用户现有 Neovim 会话。

**Pitfalls / Gotchas**
- 选择 CodeDiff 不代表删除 Diffview；初始提案的范围扩张已撤回。
- 上游 hunk discard 可保存其他脏行，零上下文 patch 可接受失效位置；操作前验证显示来源，失败拒绝。
- Neogit 已有 CodeDiff 开关，但调用旧 API；reflog 是原生 log action/view，不存在独立同名 popup。
- 上游深拷贝造成重复建树，窗口回调持有已关闭 explorer，内置标题还复制不使用的完整文件列表；均独立复现、修复并留回归。
- Hunk 的原纯相对性能门禁失败已保留；仅该动作明确增加 2ms 绝对预算，理由和数据见 [交付记录](git-review-delivery.md)。其他阈值保持。

**Validation**
- 真实 LazyVim 启动验证通过，完全由配置建立最终键位；两套审阅可独立打开/关闭，原编辑映射恢复，旧依赖不复活。
- 覆盖真实 index 的 stage/unstage/discard、脏 buffer、外部更新、LF/CRLF、删除、Unicode/rename、worktree、根/merge 提交、跨仓提交/reflog、二进制及冲突。
- 21 次大仓打开均完整覆盖 10571 项，本轮 status/index/目标字节稳定。暖打开 p95 4000.47ms；成对同输入切文件 p95 200.45ms，hunk 1.441ms。
- 心跳额外延迟最大 63.14ms，各阶段 p95 最高 26.77ms；空闲 62 秒无新 Git 查询，关闭后自有状态与任务归零。
- 打开基线存在并发新增 untracked，按可比覆盖披露，未声称严格冻结输入；成对微操作输入严格一致。详细方法、资源读数和限制见 [安全性能数据](git-review-benchmark-2026-09-29.json)。
- 21 个相关 Lua 文件通过 AST lint，change 和三个主规格严格验证通过。
- spec 一致性：同步 `git-review-workspace`、`editor-behavior-regression`、`keymap-command-regression` 及治理导航；平台调整沿用既有宿主归属契约。
- 最终冻结版本 required-native 全量 **2338/2338**，0 failed、0 skipped；`NVIM_TEST_REQUIRE_NATIVE=1 nvim --headless -l tests/run.lua`。

**Follow-ups**
- 未验证 macOS/Linux 原生库、Neovide/GPU 绘制、任意大型文件或用户 Git hook/filter 后代进程清理。
- 无末尾换行、rename、未跟踪、整文件删除及大于 8 MiB 的文件明确拒绝 hunk 写入，可使用整文件动作。前置状态检查不等同跨进程原子事务。
- 后续升级 CodeDiff 时依据各 workaround 的退役条件重验；不默认删除 Diffview。
- Change 已归档至 `openspec/changes/archive/2026-09-29-unify-git-review-with-codediff/`；tag 仍待授权。其他 SuperUnity 工作及既存 C++ 探针问题由各自任务承接。
