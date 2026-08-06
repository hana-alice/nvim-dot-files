## Context

Android 设备选择逻辑当前分散在三处：`ue.dap.android` 与 `utils.ue_launch` 各自解析 `adb devices -l` 并在多设备时选择，`utils.ue_logs` 直接取第一个 serial，`UEInstallAndroid` 则完全不带 `-s`。这些路径没有共享状态，所以同一 Neovim 会话内 install、launch、logcat、DAP 可能命中不同设备。

本仓要求 async 优先，但现有设备枚举本身已是用户触发的短命同步调用；本 change 不扩大为后台轮询，也不引入新依赖。K30 还要求 DAP 的 `platform connect connect://[<serial>]:<port>` 与设备端 ADB serial 一致。

## Goals / Non-Goals

**Goals:**

- 用一个公共模块承载设备枚举、展示、选择、全局 serial 与 ADB argv 构造。
- `:UESetAndroidDevice` 的每个候选项同时展示可读 device 名称和 serial。
- 所有设备定向 ADB 操作显式形成 `adb -s <selected-serial> ...`。
- DAP 的 K30 serial-form URL 与其 bootstrap/cleanup 使用同一 session serial。
- 公共纯函数 seam 可在 headless 下测试，不连接真机。

**Non-Goals:**

- 不跨 Neovim 重启持久化设备选择，不写 UE 项目 `state.json`。
- 不管理 TCP/IP pairing、无线 ADB、授权或 offline 状态修复。
- 不给 `adb devices -l` 发现命令添加 `-s`（发现阶段尚无目标）。
- 不在全局 serial 改变时迁移正在运行的 DAP/logcat 会话；已启动会话继续使用其捕获的 serial，下一次操作使用新值。

## Decisions

### D1：单一公共模块与显式全局变量

新增 `lua/utils/android_device.lua`，公共 API 包括：

- `parse_devices(output_or_lines)`：解析 `adb devices -l`；
- `format_item(device)`：输出 `<device-name>  [<serial>]`；
- `get()` / `set(serial)`：读写 `vim.g.ue_android_device_serial`；
- `select(opts, done)`：枚举 ready devices 并用 `vim.ui.select` 选择；
- `ensure(opts, done)`：已有全局 serial 时直接回调，否则进入同一选择器；
- `adb_args(adb, serial, args)`：构造 `{ adb, "-s", serial, ... }`，serial 缺失时返回错误。

选择 `vim.g.ue_android_device_serial` 而不是模块局部变量，是因为用户明确要求全局变量，也便于命令行、status/debug 与其他 Lua 模块读取。只保存 serial，不保存 device row 副本，避免名称或连接状态过期。

### D2：名称取自 `adb devices -l`，不额外逐设备探测

显示名优先级为 `model:` → `device:` → `product:` → `Android device`，并始终附 serial。这样一次 `adb devices -l` 即可完成 picker，不为每台设备同步执行额外 `getprop` USB 往返。`model:` 中的下划线仅用于 ADB 编码，展示时替换为空格。

替代方案是每个 serial 执行 `adb -s ... shell getprop ro.product.model`；它能拿到更完整名称，但会造成 N 次串行 ADB 往返并拖慢 UI，因此拒绝。

### D3：显式参数优先，全局选择次之，普通 attach 不猜历史

程序化 DAP smoke/tool 传入的 `context.android_serial` / `opts.serial` 仍拥有最高优先级，保证 headless 自动化可复现；普通交互 attach/launch 其次使用 `vim.g.ue_android_device_serial`，两者都没有时进入 picker，MUST NOT 用 last-session serial 静默猜测。只有语义明确为“重放上一会话”的 `UEDAPReattach` 可在全局值为空时使用 last-session serial；若已有全局选择则优先全局值，因此用户切换设备后下一次 reattach 不会继续操作旧设备。

运行中的 DAP cleanup 必须继续使用 `M._session.serial`，不能在 cleanup 时重新读取全局值，否则切换全局变量后会把旧设备资源遗留、却误清理新设备。

### D4：发现命令例外，设备命令统一 `-s`

`adb devices -l` 是唯一无 serial 的发现命令。安装、launch、package/uid 查询、logcat、pidof、push、shell、forward、DAP bootstrap/cleanup 都必须使用捕获的 selected serial。每个长任务在启动时捕获 serial，后续回调不重新读取全局值，避免任务进行中切换设备导致一次流程跨设备。

`UEInstallAndroid` 的 argv 从 `{ "adb", "install", ... }` 改为 `{ "adb", "-s", serial, "install", ... }`；AI context 在没有全局选择时不再生成危险的裸 install argv，而是给出运行 `:UESetAndroidDevice` 的 action。

### D5：交互式无选择回退与 stale serial 行为

`:UESetAndroidDevice` 总是打开 picker，即使当前只有一台 ready device，以满足“设置时从 adb devices 选择”。install/launch/logcat/DAP 在全局值为空时调用同一 picker；取消则中止操作，不猜默认设备。

已设置的 serial 不在每次操作前重新枚举验证：如果设备 offline/disconnected，命令仍带 `-s <selected>`，由 ADB 返回真实错误；系统 MUST NOT 静默改投另一台设备。这样“用户选择”始终是权威，而不是启发式默认。

### D6：命令与键位归属

`:UESetAndroidDevice` 在 `ue.setup()` 注册，`<Space>uA` 映射到该命令；`<Space>ui` 保持安装语义但内部使用 selected serial。命令加入 `commands_spec` 冻结清单，键位和 cheatsheet 同步。

## Risks / Trade-offs

- [全局 serial 指向已断开的设备] → 保留选择并显式失败，不自动切换；用户用 `<Space>uA` 重选。
- [`model:` 缺失导致名称不够友好] → 回退 `device:`/`product:`，始终显示 serial，保证可辨识。
- [设备选择期间同步 `adb devices -l` 有短暂停顿] → 只在用户主动选择或首次 Android 操作时执行一次，不新增 timer；后续操作直接读全局变量。
- [用户在 DAP 会话中切换全局设备] → 活跃 session 捕获旧 serial 并用它清理；新 serial 仅影响后续新操作。
- [第三方代码直接执行裸 adb] → 本 change 覆盖仓内所有设备定向 ADB 发起点，并以源码/行为回归守护；外部 shell 不在范围。

## Migration Plan

1. 新增 `utils.android_device` 与纯函数测试。
2. 注册 `:UESetAndroidDevice` 和 `<Space>uA`。
3. 按 install → launch → logs → DAP 顺序接入共享 serial 与 `adb_args`。
4. 更新 AI context、cheatsheet、命令冻结清单与回归映射。
5. 跑 `android_device`、`commands`、`keymaps`、`dap`、`utils`、`ue_context`、`structure`，最后跑全量回归。

回滚时删除命令/键位和公共模块，并恢复各调用点原设备策略；不涉及磁盘状态迁移。

## Open Questions

无。全局变量命名、会话级生命周期与 stale serial 行为均在本 change 内确定。
