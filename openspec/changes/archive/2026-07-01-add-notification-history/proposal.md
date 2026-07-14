## Why

`<leader>ui` / `:UEInstallAndroid` 在 Android 平台安装 APK 时会用短暂的进度提示反馈结果；提示消失后，用户无法直接判断安装是否成功。同类问题也存在于其它用户触发的命令：构建、启动、日志、搜索、DAP、项目切换等提示都可能一闪而过，用户需要一个统一入口回看最近发生了什么。

需要一个统一的可回看历史入口，把用户动作触发的成功、警告、错误和关键进度结论留下来，降低对瞬时 toast 和日志文件的依赖。

## What Changes

- 新增一个通知历史能力，记录本配置发出的用户可见提示、错误和关键信息提示，重点覆盖用户触发命令产生的反馈。
- 提供命令/快捷键入口查看最近历史，支持按级别、时间和来源识别消息。
- Android APK 安装流程作为首个强制覆盖路径，必须在历史中留下开始、成功、失败摘要；失败还应保留 `adb` 输出摘要与可操作 hint。
- 新增或迁移其它用户触发提示时，应优先通过历史感知 helper 记录，避免再出现“只闪一下不可回看”的路径。
- 保留现有 `:NvimLog` 作为详细落盘日志，不把通知历史变成无限增长的替代日志。
- 不引入新依赖，不全局 monkey-patch `vim.notify`。

## Capabilities

### New Capabilities
- `notification-history`: 记录并展示 Neovim 配置层的通知、报错和信息提示历史。

### Modified Capabilities

## Impact

- 预计影响 `lua/utils/log.lua`、`lua/ue.lua` 的 Android 安装流程、命令/快捷键注册和对应 headless 回归测试。
- 可能新增一个小型 `lua/utils/notification_history.lua` 模块，作为内存环形缓冲与展示入口。
- 不改变 Android 安装命令的实际执行参数，不改变 `:NvimLog` 的文件日志语义。
