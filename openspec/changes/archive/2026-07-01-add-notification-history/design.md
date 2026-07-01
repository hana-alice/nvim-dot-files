## Context

当前配置里已经有两类用户反馈：

- `vim.notify` / `utils.log.notify*`：右下角短暂提示；`utils.log.notify_error` 会把错误落盘到 `:NvimLog`。
- fidget progress handle：例如 `:UEInstallAndroid` 显示安装进度，成功后很快结束，失败时会延迟约 8 秒并把完整 `adb` 输出写入 `:NvimLog`。

这解决了“有提示”和“错误可查日志”的问题，但没有解决“用户刚错过提示后，直接在编辑器里看最近发生了什么”的问题。尤其 Android 安装成功时目前只表现为短暂的 fidget completion，不一定留下用户级历史；其它用户触发命令也有类似问题，只是 Android 安装最容易暴露。

本仓约束要求不做周期性 ticker，不全局 monkey-patch `vim.notify`，也不引入新的 UI 依赖。因此通知历史应作为一个轻量、本配置显式写入的内存历史，而不是替换 snacks/noice/fidget 或文件日志。

## Goals / Non-Goals

**Goals:**

- 记录最近的用户可见提示：INFO、WARN、ERROR、DEBUG 等级、来源 scope、消息正文和时间。
- 覆盖本配置中用户触发命令产生的通知、错误和关键结果，不把能力限定为 Android 安装。
- 提供一个直接入口查看历史，至少支持命令打开；快捷键作为可发现性补充。
- Android APK 安装必须记录开始、成功、失败摘要，确保用户能回看“是否安装成功”。
- 失败详情继续写入 `:NvimLog`，历史只保留适合 UI 展示的摘要和指向日志的提示。
- 实现保持 headless-testable，核心逻辑不依赖真实 UI。

**Non-Goals:**

- 不捕获所有第三方插件内部通知；只保证本配置通过受控 helper 或显式调用写入的消息。
- 不要求一次性迁移所有历史直接 `vim.notify` 调用；本 change 需要提供统一机制并覆盖高价值路径，后续改动应沿用该机制。
- 不替代 `:NvimLog`，不持久化无限历史，不提供跨 Neovim 重启的完整审计日志。
- 不改变 `adb install -r` 的执行参数和 Android 安装流程的成功/失败判定。
- 不引入 noice、telescope、数据库或外部依赖。

## Decisions

### D1 — 新增 `utils.notification_history` 环形缓冲

新增模块管理内存历史，公开：

- `record({ level, scope, message, title, timestamp, detail })`
- `list(opts)` 返回按时间倒序的记录
- `open(opts)` 打开只读 scratch buffer 展示历史
- `_reset_for_test()` / `_records_for_test()` 用于 headless 回归

记录上限使用固定环形缓冲，例如 200 条。理由：用户诉求是查看近期提示，不是长期日志；固定上限满足 P5 “不做 ticker”和磁盘约束。

替代方案：直接读取 `:messages`。拒绝原因：`:messages` 混合来源不可结构化过滤，也不可靠包含 fidget progress 结论。

替代方案：把所有历史写入 `utils.log` 文件后再解析。拒绝原因：`utils.log` 默认 WARN 级别会丢 INFO，且文件日志适合详细 post-mortem，不适合轻量 UI 历史。

### D2 — 只在受控入口记录，不 monkey-patch `vim.notify`

`utils.log.notify` / `notify_error` 在调用 `vim.notify` 前记录一条历史；普通模块若直接使用 fidget 或 `vim.notify` 且属于用户触发的关键工作流，应显式调用 `notification_history.record`。后续新增用户命令反馈时，默认走历史感知 helper。

理由：`utils.log.lua` 已声明不 monkey-patch `vim.notify`，避免与 noice/snacks/fidget 冲突。显式记录也让测试可以验证关键路径。

替代方案：包裹全局 `vim.notify`。拒绝原因：违反现有设计注释，容易触发插件覆盖冲突和重复提示。

### D3 — Android 安装路径显式记录生命周期结论

`install_android()` 在以下时点记录：

- 找到 APK 并启动 `adb install`：INFO，包含 APK 文件名和构建年龄。
- `adb install` exit code 0：INFO，明确“Installed successfully”。
- `adb install` 非 0：ERROR，包含 exit code、精选 `adb` summary、hint，以及“see :NvimLog”。

fidget 仍负责即时进度，`utils.log` 仍负责失败详情。历史记录只保留适合回看的摘要。

### D3b — 用户触发命令使用统一记录策略

对构建、启动、日志、DAP、搜索/索引等用户触发路径，凡是“用户需要回看是否成功/失败/为什么失败”的提示，都应通过 `utils.log.notify`、`utils.log.notify_error` 或显式 `notification_history.record` 进入历史。实现首轮不必机械替换所有低价值提示，但必须让新机制成为后续提示的默认路径。

替代方案：只给 `UEInstallAndroid` 增加专用历史。拒绝原因：用户问题不是安装专有问题，而是所有短暂提示不可回看的通用 UX 缺口。

### D4 — 用命令 + 可选快捷键展示

新增命令建议：

- `:NotificationHistory` 打开最近通知历史。
- `:NotificationHistoryClear` 清空内存历史。

快捷键建议使用未占用的 UI/UE 邻近入口，例如 `<leader>uN` 或 `<leader>nH`，最终实现前需检查现有映射避免冲突。

展示实现优先使用 scratch buffer（`nofile`、只读、`buflisted=false`），不依赖 picker。格式包含时间、级别、scope/title、单行消息；多行消息缩进展示。

## Risks / Trade-offs

- [Risk] 直接调用 `vim.notify` 的旧代码不会自动进入历史。→ Mitigation：先覆盖 `utils.log.notify*`、Android 安装关键路径和本次触及的高价值用户命令；后续新增/迁移提示默认走历史感知 helper。
- [Risk] 历史和 `:NvimLog` 信息量不一致。→ Mitigation：历史只承诺 UI 摘要，详细错误仍以 `:NvimLog` 为准，并在失败摘要中提示。
- [Risk] 快捷键命名与现有 `<leader>u*` 发生冲突。→ Mitigation：实现前检查 `lua/config/keymaps.lua`，并补 `keymaps` / `commands` 回归。
- [Risk] 记录过多造成内存增长。→ Mitigation：固定上限环形缓冲，默认 200 条，不落盘。

## Migration Plan

1. 新增 `lua/utils/notification_history.lua`，实现纯 Lua 记录、列表、清空和展示。
2. 在启动路径安装命令，优先放在现有全局 command 初始化附近，保持 LazyVim 自动加载约束不变。
3. 修改 `utils.log.notify` / `notify_error` 写入历史。
4. 修改 `install_android()` 在开始、成功、失败时显式写入历史。
5. 审视当前用户触发命令中的高价值提示，优先迁移错误/成功结果类提示到历史感知 helper。
6. 增加 headless 回归覆盖记录顺序、上限、命令注册、Android 安装源码级契约和 helper 集成。
7. 在 `docs/changelog.md` Unreleased 记录变更与验证。

Rollback：删除新模块、命令/快捷键注册和调用点即可，`adb install` 行为不变。

## Open Questions

- 快捷键最终使用 `<leader>uN` 还是更通用的 `<leader>nH`，需要以现有映射冲突检查为准。
- 第一轮需要迁移哪些直接 `vim.notify` 路径作为“高价值用户触发提示”，实现时应以风险和测试成本排序；Android 安装、`utils.log.notify*` 集成是最低要求。
