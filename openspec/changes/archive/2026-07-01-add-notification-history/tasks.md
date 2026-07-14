## 1. 核心历史模块

- [x] 1.1 新增 `lua/utils/notification_history.lua`，实现固定上限内存历史、`record`、`list`、`clear` 和测试 seam。
- [x] 1.2 实现只读 scratch buffer 展示入口，按最近优先渲染时间、等级、来源和消息正文。
- [x] 1.3 为历史模块补 headless 单元测试，覆盖追加、倒序列表、容量淘汰、清空和空状态展示。

## 2. 通知入口集成

- [x] 2.1 在 `utils.log.notify` 和 `utils.log.notify_error` 中记录通知历史，不改变现有落盘和 `vim.notify` 行为。
- [x] 2.2 安装 `:NotificationHistory` 与 `:NotificationHistoryClear` 命令，并确认启动顺序不重复注册。
- [x] 2.3 检查现有 keymap 后添加一个无冲突快捷键入口，并同步命令/快捷键冻结测试。
- [x] 2.4 梳理当前用户触发命令的高价值提示，优先把成功/失败/错误/下一步行动类提示迁移到历史感知 helper。

## 3. Android 安装路径

- [x] 3.1 在 `install_android()` 启动 `adb install` 时记录安装开始摘要。
- [x] 3.2 在 `adb install` 成功回调中记录安装成功摘要，明确 APK 已安装成功。
- [x] 3.3 在 `adb install` 失败回调中记录安装失败摘要，包含 exit code、精选错误行、hint 和 `:NvimLog` 指引。
- [x] 3.4 保持完整 stdout/stderr 继续写入 `:NvimLog`，不改变 `adb install -r` 参数和 task registry 语义。

## 4. 回归与文档

- [x] 4.1 增加或更新测试，覆盖通知历史模块、命令注册、helper 集成、Android 安装源码级记录契约。
- [x] 4.2 按 `tests/AGENTS.md` 运行最小回归：`utils`、`commands`、`keymaps`，若影响面扩大则跑全量。
- [x] 4.3 在 `docs/changelog.md` Unreleased 增加条目，Validation 写明实际回归范围和结果。
- [x] 4.4 运行 `openspec status --change "add-notification-history"`，确认实施前工件状态正常。
