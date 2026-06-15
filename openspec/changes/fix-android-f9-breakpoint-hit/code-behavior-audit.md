## F9 当前代码行为审计

### 1. F9 用户入口

```text
lua/config/keymaps.lua
  <F9> / <leader>db
    -> :UEDAPToggleBreakpoint
      -> lua/ue.lua user command
        -> M.dap_toggle_breakpoint()
          -> lua/ue/dap.lua D.dap_toggle_breakpoint()
            -> lua/ue/dap/_persist_bp.lua M.toggle()
              -> require("dap").toggle_breakpoint()
              -> M.save_debounced()
```

行为含义：

- F9 本身只修改 nvim-dap 的本地 breakpoint store，并持久化到
  `<engine_root>/.cache/nvim-ue/breakpoints/<project>.json`。
- F9 不直接调用 Android LLDB 命令。
- 是否下发到 LLDB，取决于后续 attach config preseed 或 active session 的
  `setBreakpoints` 流。

### 2. attach 前已有断点

```text
lua/ue/dap/android.lua _finalize_session()
  -> lldb_dap_attach_config(sess, source_map)
       attachCommands =
         target create <symbol-rich libUE4.so>
         platform select remote-android
         platform connect connect://[serial]:port
         process attach --pid <pid>
         process handle SIG*
         target modules load --file libUE4.so --slide 0x<base>
  -> current_breakpoint_commands()
       require("dap.breakpoints").get()
       buffer-id key -> nvim_buf_get_name()
       path key -> path
       path -> basename
       line -> breakpoint set -f "<basename>" -l <line>
  -> preseed_breakpoints_into_attach_commands(cfg)
       insert after signal disposition, then after target modules load if present
  -> C.run(cfg)
```

行为含义：

- attach 前断点的唯一正确 owner 应是 `lua/ue/dap/android.lua`，因为它知道完整
  attachCommands 顺序和 ASLR rebase 是否存在。
- 现有代码曾在 `lua/ue/dap.lua` 也注入一套 preseed。该路径会在 `process handle
  SIGPIPE` 后插入，不理解后续 `target modules load --slide`，因此职责重复且顺序风险更高。

### 3. attach 后新增/恢复断点

```text
lua/ue/dap/_persist_bp.lua restore_for_buf()
  if dap.session() then
    dap.session():set_breakpoints(...)

lua/ue/dap.lua listeners
  before.setBreakpoints["ue_android_bp_source_rewrite"]
    Windows absolute source path -> basename-only source path

  after.setBreakpoints["ue_android_bp_local_response"]
    remap adapter response source path back to local path
    previously: schedule_reattach()
```

行为含义：

- 会话中的 F9 或 buffer restore 会走 DAP `setBreakpoints`。
- DAP `setBreakpoints` 是否会安全、真实地写进 Android 远端进程，当前没有证明。
- 静默 detach + reattach 不是即时断点下发；它只能作为用户显式选择的 re-preseed 行为。

### 4. source navigation

```text
after.event_stopped["ue-dap-source-nav"]
  -> maybe_jump_to_local_source_frame()
    -> stackTrace
    -> pick first frame with local source file
    -> session:_frame_set(frame) or edit local path + set cursor

before.stackTrace["ue_source_path_rewrite"]
  -> resolve_source_path()
  -> rewrite synthetic/invalid Android frames to line=-1 placeholder source
```

行为含义：

- 真正命中断点后，UI 是否跳到源码由 stackTrace source path 和 local resolver 决定。
- `Source missing` / `E474` 入口噪音由 synthetic frame 的 line=-1 placeholder 处理；
  真实断点 frame 不能被误判为 synthetic。

### 5. 设计结论

- Android breakpoint preseed 的运行时 owner 必须收敛到 `lua/ue/dap/android.lua`。
- `lua/ue/dap.lua` 只负责 DAP listener、source rewrite、response remap、用户反馈，不再修改
  Android attachCommands。
- `verified=true` 不能由本地合成；它必须来自 adapter/LLDB 状态或被明确标注为未验证。
- 会话中 F9 如果不能即时安全下发，必须明确告知用户需要 reattach，不能静默重连。

### 6. 2026-06-15 最新 LLDB 证据

- `MobileShadingRenderer.cpp:1367` 和 `:1369` 在
  `Client_Symbols_v170300916/Client-arm64/libUE4.so` 的 DWARF line table 中都会解析到
  `FMobileSceneRenderer::Render + 672/+676/+712/+720 at MobileShadingRenderer.cpp:1369:8`。
- 本地 `D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp`
  当前第 1367 行是 `Scene->UpdateMobileShadowSpotlight(nullptr);`，但 `lldb disassemble`
  显示 `+672` 附近是 `ShouldRenderSkyAtmosphere` 后的 sky-atmosphere 代码块。
- 因此当前 1367/1369 smoke 的“resolved but not hit”不能证明这条本地源码语句未执行；
  它证明的是当前 symbol lib 与本地源码行号不匹配。闭环 7.2/5.4 前必须换成与该
  `libUE4.so` 匹配的源码/符号，或选用 line table 能准确对应本地源码的目标行。

### 7. 2026-06-15 matching-symbol 闭环证据

- 设备进程使用的 `/data/app/.../lib/arm64/libUE4.so` build-id 是
  `648da3d17f2ac45ad0a6c5c1166cb248ae0baa1c`；旧 3.4 symbol lib 的 build-id 是
  `ad3d4e7c5f83823edbea33d7a9d5b13cb9153afc`，不能作为 F9 命中证明的符号源。
- 匹配的 symbol-rich lib 是
  `E:/aki/zeqiang_aki_3.5/Source/Client/Binaries/Android/Client_Symbols_v171457238/Client-arm64/libUE4.so`，
  build-id 同为 `648da3d17f2ac45ad0a6c5c1166cb248ae0baa1c`。
- 使用匹配 3.5 symbols 后，`image lookup --file MobileShadingRenderer.cpp --line 1367`
  只有一个语义匹配：
  `FMobileSceneRenderer::Render(FRHICommandListImmediate&, bool) + 616 at MobileShadingRenderer.cpp:1367:2`。
- 最新 smoke 结果 `tools/evidence/android-f9/nvim_android_dap_smoketest.1367.matching-symbol.result.json`
  证明 attach 前 F9/preseed 路径闭环：`breakpoint list` 为 `locations=1, resolved=1`，
  继续运行后收到 `reason="breakpoint"` / `description="breakpoint 1.1 2.1"`，
  `hitBreakpointIds=[1,2]`。
- 同一 stop 的 stackTrace 栈顶为
  `D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp:1367`，
  函数 `FMobileSceneRenderer::Render(...)`，证明 local source mapping 可用；该结论不依赖
  app business output。
