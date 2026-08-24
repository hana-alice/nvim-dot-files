## 1. 代码行为审计与设计清理

- [x] 1.1 画出当前 F9 实际代码路径：`lua/config/keymaps.lua` → `UEDAPToggleBreakpoint` → `D.dap_toggle_breakpoint()` → `_persist_bp.toggle()` → `dap.toggle_breakpoint()` → DAP listener / attach config。
- [x] 1.2 画出当前 attach 前断点路径：`dap.breakpoints.get()`、`current_breakpoint_commands()`、`preseed_breakpoints_into_attach_commands(cfg)`、最终 attachCommands 顺序。
- [x] 1.3 画出当前 attach 后断点路径：`_persist_bp.restore_for_buf()` / `setBreakpoints` listener / `schedule_reattach()`，确认它不是即时 LLDB 下发。
- [x] 1.4 审计并处理重复 preseed owner：删除或停用 `lua/ue/dap.lua` 的 Android attachCommands 注入，保留 `lua/ue/dap/android.lua` 为唯一 owner。
- [x] 1.5 审计 `ue_android_synthetic_breakpoint_response()` 是否无调用点；若是死代码则删除，若仍被调用则改成真实状态响应。
- [x] 1.6 修正运行时代码中过时或误导性的 gdb-remote / workaround 注释，确保主路注释只描述当前 K30 platform route。

## 2. 复现与证据链

- [x] 2.1 记录当前失败基线：在授权真机 `ANDROID-SERIAL-B` 上复现 attach 前 F9 未 stop，保存 fresh pid、port、DAP log、LLDB console output、adapter exit code / timeout 状态。
- [x] 2.2 增加或扩展诊断 probe，输出 nvim 断点表、最终 attachCommands、`setBreakpoints` 响应、`breakpoint list`、stop event 与 selected frame。
- [x] 2.3 用 probe 区分失败层级：断点命令未发出、LLDB pending、resolved 但未命中、已命中但 UI 未跳转。
- [x] 2.4 确认用户失败场景属于 attach 前已有断点、attach 后新增断点，或两者都失败，并分别记录。

## 3. attach 前断点 preseed 修复

- [x] 3.1 复核 `lua/ue/dap/android.lua` 的 preseed 收集逻辑，确保 buffer-id keyed 与 path keyed 断点都能转成目标 file:line。
- [x] 3.2 确保 preseed `breakpoint set` 插入在 `target create`、platform connect、`process attach`、signal disposition、ASLR rebase 之后，且早于 `configurationDone`。
- [x] 3.3 在 attachCommands 中追加诊断用 `breakpoint list`，并将输出落到可检查日志。
- [x] 3.4 确认 K30 platform route 下 source-file `breakpoint set -f/-l` 在匹配符号时 resolved 并命中；address fallback 条件未触发，保持未实现。

## 4. attach 后 F9 行为

- [x] 4.1 审计 `lua/ue/dap.lua` 的 Android `setBreakpoints` 处理，区分已 preseed 断点与会话中新增断点。
- [x] 4.2 删除静默自动 detach+reattach 的假即时语义；改为即时安全下发或明确提示用户手动 reattach。
- [x] 4.3 对 attach 后新增断点实现诚实反馈：未能安全即时下发时提示需要 reattach，不能返回假成功。
- [x] 4.4 未实现 attach 后即时 LLDB command path：当前 probe 只证明显式 reattach/preseed 路径稳定，未证明 session-time command path 稳定；保留明确 warning 与 `:UEDAPReattach`。

## 5. 路径、符号与 ASLR 校验

- [x] 5.1 验证 `target create <symbol-rich libUE4.so>` 实际发生在 attach 前，并记录 module UUID / symbol status。
- [x] 5.2 验证 `target modules load --file libUE4.so --slide 0x<base>` 的 base 来自当前 pid maps，且未用 `string.format("%x")` 截断。
- [x] 5.3 对重复 basename 场景记录 LLDB resolved compile-unit 路径；若匹配错误，改用更精确路径或 address 断点。
- [x] 5.4 确认 sourceMap / local path resolver 能把 stop frame 映射回本地源码行：`MobileShadingRenderer.cpp:1367` breakpoint stop 栈顶映射到 `D:/UE/EngineWorktree/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp:1367`。

## 6. spec 与文档同步

- [x] 6.1 更新主 spec `android-dap-attach`：以 K30 serial-form platform route 为准，移除过时的“禁止所有 platform connect 字符串”表述。
- [x] 6.2 更新 `docs/CONSTRAINTS.md` / `docs/TOOLING.md` 中 F9 断点判据：UI 标记不算成功，必须有 `breakpoint list resolved>0` 与 stop event。
- [x] 6.3 在 `docs/changelog.md` 追加本 change 的实现与验证记录。

## 7. 验证

- [x] 7.1 运行相关 headless 回归：至少 `dap`、`platform`，若影响面不确定则运行 `nvim --headless -l tests/run.lua`。
- [x] 7.2 真机验证 attach 前 F9：匹配 3.5 symbol-rich `libUE4.so` 后，`breakpoint list resolved=1`，继续运行后收到 `reason="breakpoint"`，栈顶停在本地 `MobileShadingRenderer.cpp:1367`。
- [x] 7.3 真机验证 attach 后 F9：即时生效或明确提示 reattach；不得假成功。
- [x] 7.4 验证无 `Source missing, cannot jump to ...`，adapter 存活，无 `3221226505`。
- [x] 7.5 收尾清理：host lldb-dap、device lldb-server、adb forward、目标 `TracerPid=0`。
- [x] 7.6 运行 `openspec validate fix-android-f9-breakpoint-hit` 并确认通过。
