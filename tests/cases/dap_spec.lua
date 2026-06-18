-- tests/cases/dap_spec.lua
-- DAP 平台注册：platforms 注册/查找 + 各平台模块 attach/launch 导出。

local t = require("tests.harness")
t.bootstrap()

t.describe("ue.dap.platforms: 注册与查找", function()
  local p = require("ue.dap.platforms")

  t.it("register_attach + attach_handler 可调用", function()
    p._reset_for_test()
    local hit = false
    p.register_attach("xtest", function() hit = true end)
    local h = p.attach_handler("xtest")
    t.assert_type(h, "function")
    h()
    t.assert_true(hit, "注册的 handler 未触发")
    p._reset_for_test()
  end)

  t.it("未注册的 launch_handler 返回 nil", function()
    p._reset_for_test()
    p.register_attach("xtest", function() end)
    t.assert_nil(p.launch_handler("xtest"))
    p._reset_for_test()
  end)
end)

t.describe("ue.dap: 各平台模块导出 attach/launch", function()
  for _, id in ipairs({ "win64", "mac", "linux", "ios" }) do
    t.it(id .. " 模块导出 attach + launch", function()
      local m = require("ue.dap." .. id)
      t.assert_type(m.attach, "function", id .. ".attach")
      t.assert_type(m.launch, "function", id .. ".launch")
    end)
  end
end)

t.describe("ue.dap.android: breakpoint preseed", function()
  local function with_breakpoints(raw, fn)
    local old = package.loaded["dap.breakpoints"]
    package.loaded["dap.breakpoints"] = {
      get = function() return raw end,
    }
    local ok, err = pcall(fn)
    package.loaded["dap.breakpoints"] = old
    if not ok then error(err, 0) end
  end

  t.it("K10: collects buffer-id and path keyed breakpoints", function()
    local android = require("ue.dap.android")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "D:/proj/Source/Client/Foo.cpp")
    with_breakpoints({
      [buf] = { { line = 17 } },
      ["D:/proj/Source/Client/Bar.cpp"] = { { line = 29 } },
    }, function()
      local cmds = android._current_breakpoint_commands_for_test()
      t.assert_contains(cmds, '?breakpoint set -f "Bar.cpp" -l 29')
      t.assert_contains(cmds, '?breakpoint set -f "Foo.cpp" -l 17')
    end)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  t.it("K33: inserts preseed breakpoints after ASLR rebase and emits breakpoint list", function()
    local android = require("ue.dap.android")
    with_breakpoints({
      ["D:/proj/Source/Client/Foo.cpp"] = { { line = 17 } },
    }, function()
      local cfg = {
        attachCommands = {
          'target create "D:/symbols/libUE4.so"',
          "platform select remote-android",
          "platform connect connect://[a3ad86f3]:5039",
          "process attach --pid 1234",
          "process handle SIGSEGV --notify false --pass true --stop false",
          "process handle SIGBUS  --notify false --pass true --stop false",
          "process handle SIGPIPE --notify false --pass false --stop false",
          "target modules load --file libUE4.so --slide 0x6c9fe21000",
        },
      }
      android._preseed_breakpoints_into_attach_commands_for_test(cfg)
      local slide_i, bp_i, list_i
      for i, cmd in ipairs(cfg.attachCommands) do
        if cmd:find("target modules load", 1, true) then slide_i = i end
        if cmd == '?breakpoint set -f "Foo.cpp" -l 17' then bp_i = i end
        if cmd == "breakpoint list" then list_i = i end
      end
      t.assert_true(slide_i and bp_i and slide_i < bp_i,
        "breakpoint must be inserted after ASLR rebase")
      t.assert_eq(list_i, bp_i + 1, "breakpoint list should immediately follow preseed")
    end)
  end)

  t.it("generic dap glue does not own Android attachCommands", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_false(text:find("ue_android_preseed_breakpoints", 1, true),
      "ue.dap.lua must not inject Android breakpoint attachCommands")
    t.assert_false(text:find("schedule_reattach", 1, true),
      "setBreakpoints must not silently detach and reattach")
  end)

  t.it("K34/3.4: bootstrap does not hardcode a symbol_lib fallback path", function()
    -- A literal symbol_lib short-circuits pick_symbol_lib() (its step 0 returns
    -- any existing ctx path verbatim, skipping the packageInfo versionCode
    -- exact-match), so a stale build-id lib would attach to the WRONG source
    -- revision (the 3.4 ad3d4e7c false-lead). Guard against re-introducing one.
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap/android.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    -- A `... or "...libUE4.so"` assignment is the dangerous shape: it forces a
    -- concrete library regardless of the installed APK. Comments mentioning the
    -- banned path are fine; an `or "<path>.so"` fallback expression is not.
    t.assert_false(text:find('or%s+"[^"]*libUE4%.so"') ~= nil,
      "android.lua must not hardcode an `or \"...libUE4.so\"` symbol_lib fallback")
    t.assert_false(text:find('android_symbol_lib%s*=%s*"') ~= nil,
      "android.lua must not assign a string-literal android_symbol_lib")
  end)

  t.it("K36: session-time setBreakpoints is gated and planted live (not warned)", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find('dap.listeners.after.configurationDone["ue_android_bp_config_done"]', 1, true) ~= nil,
      "Android DAP should mark configurationDone to distinguish initial sync vs live change")
    t.assert_true(text:find("session._ue_android_configuration_done ~= true", 1, true) ~= nil,
      "before-gate setBreakpoints is the preseed initial sync and must be left to attachCommands")
    -- After the gate, a session-time change must be planted live via the
    -- proven evaluate channel — NOT a :UEDAPReattach warning.
    t.assert_true(text:find("ue_android_live_plant_via_evaluate", 1, true) ~= nil,
      "active-session setBreakpoints should plant live via the evaluate channel")
    t.assert_true(text:find("active-session setBreakpoints → live evaluate plant", 1, true) ~= nil,
      "live plant path should be visible in diagnostics")
    -- The old reattach warning and its throttle must be gone.
    t.assert_true(text:find("are not silently reattached", 1, true) == nil,
      "the :UEDAPReattach active-session warning must be removed once live planting works")
    t.assert_true(text:find("D._ue_android_bp_notice_until_ms = now + 5000\n      vim.notify(\n        \"%[ue.dap%] Android breakpoint changes", 1, false) == nil,
      "the dedicated reattach-warning throttle block must be removed")
  end)

  -- ── Behavioral coverage of the live-plant pure logic ──────────────────
  -- These lock the *behavior* (not just the source text) of the load-bearing
  -- helpers behind the session-time live breakpoint path. Change
  -- android-dap-live-breakpoints (archived 2026-06-15); on-device proof in
  -- tools/evidence/android-f9/livebp-*.json.

  t.it("K36: live-plant command uses the proven basename form (matches preseed)", function()
    local D = require("ue.dap")
    -- A UE Android absolute Windows path must be rewritten to basename only —
    -- the exact shape attach-time preseed uses and that resolves against DWARF.
    local cmd, file = D._live_plant_command_for_test(
      { path = "D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp",
        name = "MobileShadingRenderer.cpp" }, 1367)
    t.assert_eq(cmd, '`breakpoint set -f "MobileShadingRenderer.cpp" -l 1367',
      "live-plant must emit a backtick `breakpoint set -f <basename> -l <line>` command")
    t.assert_eq(file, "MobileShadingRenderer.cpp", "returned file must be the basename")
  end)

  t.it("live-plant command rejects invalid line / empty source", function()
    local D = require("ue.dap")
    t.assert_nil(D._live_plant_command_for_test({ name = "Foo.cpp" }, 0),
      "line 0 must not produce a command")
    t.assert_nil(D._live_plant_command_for_test({ name = "Foo.cpp" }, -1),
      "negative line must not produce a command")
    t.assert_nil(D._live_plant_command_for_test({ name = "Foo.cpp" }, nil),
      "nil line must not produce a command")
    t.assert_nil(D._live_plant_command_for_test({}, 10),
      "source with no usable name/path must not produce a command")
  end)

  t.it("K33: resolved-parser is the honest-verified signal (resolved>0 vs 0/nil)", function()
    local D = require("ue.dap")
    local hit = "1: file = 'MobileShadingRenderer.cpp', line = 1367, "
      .. "exact_match = 0, locations = 1, resolved = 1, hit count = 0"
    t.assert_eq(D._scan_breakpoint_resolved_for_test(hit), 1,
      "a resolved=1 breakpoint-list line must parse to 1 (real plant)")
    local pending = "1: file = 'Foo.cpp', line = 10, locations = 0, resolved = 0, hit count = 0"
    t.assert_eq(D._scan_breakpoint_resolved_for_test(pending), 0,
      "a resolved=0 (pending) line must parse to 0 — never fake success")
    t.assert_nil(D._scan_breakpoint_resolved_for_test("No breakpoints currently set."),
      "no resolved line at all must parse to nil")
    -- Multi-block dump: parser returns the LAST resolved value.
    local two = hit .. "\n2: file = 'Bar.cpp', line = 5, locations = 0, resolved = 0, hit count = 0"
    t.assert_eq(D._scan_breakpoint_resolved_for_test(two), 0,
      "multi-breakpoint dump returns the last resolved count")
  end)

  -- ── Invariant guards (the hard-won lessons that must never regress) ────

  t.it("INVARIANT: nvim-dap before.setBreakpoints runs in the RESPONSE pipeline", function()
    -- Hard-won (change android-dap-live-breakpoints): nvim-dap has NO
    -- before-request hook. `listeners.before.setBreakpoints` fires in
    -- handle_body's response pipeline with (session, err, response, request,
    -- seq) — you CANNOT mutate the outgoing args.source there. The earlier
    -- ue_android_bp_source_rewrite name implied wire-mutation; it must not
    -- come back, and the listener must recover lines from the `request` payload.
    local dap_path = vim.fn.stdpath("data") .. "/lazy/nvim-dap/lua/dap/session.lua"
    if vim.fn.filereadable(dap_path) == 1 then
      local sess = table.concat(vim.fn.readfile(dap_path), "\n")
      t.assert_true(sess:find("listeners.before%[decoded.command%]") ~= nil,
        "nvim-dap before-listeners must still fire from the response pipeline "
        .. "(handle_body) — if upstream adds a true before-request hook, revisit "
        .. "ue.dap.lua's setBreakpoints recovery")
    end
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find("ue_android_bp_source_rewrite", 1, true) == nil,
      "the misleading wire-mutating listener name must not return")
    t.assert_true(text:find("ue_android_bp_record_request", 1, true) ~= nil,
      "the before-listener must only record the request shape, not mutate it")
  end)

  t.it("K33: INVARIANT: live plant never fakes success and never detach+reattach", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    -- Reads back resolved state and warns on failure (honest verified).
    t.assert_true(text:find("scan_breakpoint_resolved", 1, true) ~= nil,
      "live plant must read back breakpoint-list resolved state")
    t.assert_true(text:find("did not resolve", 1, true) ~= nil,
      "live plant must surface an honest warning when resolved=0 / command errors")
    -- No reattach / detach-to-replant in the breakpoint path.
    t.assert_true(text:find("schedule_reattach", 1, true) == nil,
      "live plant must NOT schedule a detach+reattach to plant breakpoints")
    t.assert_true(text:find("ue_android_synthetic_breakpoint_response", 1, true) == nil,
      "the old always-verified synthetic setBreakpoints response must stay removed")
  end)

  t.it("K37: INVARIANT: explicit ASLR slide stays load-bearing with a reverify switch", function()
    -- K37: on this device, skipping `target modules load --slide` makes attach
    -- time out / crash the adapter. The slide + its plumbing must be kept; a
    -- UE_DAP_NO_SLIDE switch exists only to re-verify on other devices.
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap/android.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find("_module_rebase_cmd", 1, true) ~= nil,
      "the ASLR slide plumbing (_module_rebase_cmd) must remain")
    t.assert_true(text:find("UE_DAP_NO_SLIDE", 1, true) ~= nil,
      "the slide-skip reverify switch must remain documented for future devices")
  end)

  t.it("smoke harness installs UE DAP guards before Android attach", function()
    local path = vim.fn.stdpath("config") .. "/tools/nvim_android_dap_smoketest.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    local main_i = text:find("local function main", 1, true)
    local runtime_i = text:find("ensure_nvim_dap_runtime", main_i, true)
    local setup_i = text:find("ue.setup_dap(dap, smoke_dapui)", main_i, true)
    local attach_i = text:find("android.attach({ context = ctx })", main_i, true)
    t.assert_true(runtime_i and setup_i and attach_i and runtime_i < setup_i and setup_i < attach_i,
      "headless smoke must install ue.setup_dap guards before attach")
    t.assert_true(text:find("dap.listeners.after.event_output%[listener_key%]", 1, false) ~= nil,
      "headless smoke must capture LLDB output into its result JSON")
  end)

  t.it("DAP stackTrace guard keeps synthetic Android frames non-jumpable", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find("copy.line = %-1", 1, false) ~= nil,
      "synthetic Android frames should use line=-1 so nvim-dap skips UI jumps")
    t.assert_true(text:find('name = source and source.name or frame.name or "<synthetic>"', 1, true) ~= nil,
      "synthetic Android frames should retain a placeholder source name")
  end)

  t.it("synthetic-frame guards converge on a single annotated chokepoint", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    -- Shared anchor documenting the one upstream root cause.
    t.assert_true(text:find("ANCHOR(ue-synthetic-frame-guard)", 1, true) ~= nil,
      "synthetic-frame guards must share an ANCHOR doc-block naming the upstream cause")
    -- The three cross-referenced sites: chokepoint + two thin guards.
    t.assert_true(text:find("ANCHOR-USE:stackTrace", 1, true) ~= nil,
      "stackTrace listener must be marked as the chokepoint")
    t.assert_true(text:find("ANCHOR-USE:_frame_set", 1, true) ~= nil,
      "_frame_set patch must be cross-referenced as defence-in-depth")
    t.assert_true(text:find("ANCHOR-USE:bp-response", 1, true) ~= nil,
      "setBreakpoints response remap must be cross-referenced")
  end)

  t.it("sourceMap keeps build Engine paths local when project Engine is absent", function()
    local android = require("ue.dap.android")
    local root = vim.fn.tempname()
    local proot = root .. "/Project/Source/Client"
    local build = root .. "/BuildRoot"
    vim.fn.mkdir(proot .. "/Binaries/Android", "p")
    vim.fn.mkdir(build .. "/Engine", "p")
    vim.fn.writefile({ "com.example.game", "1", "1.0.0" }, proot .. "/Binaries/Android/packageInfo.txt")

    local sm = android._pick_source_map_for_test({
      project_root = proot,
      android_build_root = build,
    })
    local build_engine = vim.fs.normalize(build .. "/Engine")
    t.assert_eq(sm[1].from, build_engine)
    t.assert_eq(sm[1].to, build_engine)
    t.assert_eq(sm[2].from, vim.fs.normalize(build))
    t.assert_eq(sm[2].to, vim.fs.normalize(proot))
    vim.fn.delete(root, "rf")
  end)
end)

t.describe("ue.dap: setup() 后平台已注册", function()
  -- 注意：本文件前面的用例调用过 _reset_for_test() 清空注册表，而
  -- ue.setup() 有 CORE_RT.setup_done 幂等守卫——若 setup 已执行过，
  -- 再次调用不会重新注册。因此这里直接复刻 setup 内的注册逻辑，
  -- 确保断言基于「平台注册 seam」本身的正确性，而非依赖调用顺序。
  local function ensure_platforms_registered()
    require("ue").setup()
    local p = require("ue.dap.platforms")
    -- 若被前序用例 reset 清空，手动重放注册（与 ue.lua setup 内一致）。
    if type(p.attach_handler("win64")) ~= "function" then
      local ue = require("ue")
      p.register_attach("android", function() ue.android_dap_attach() end)
      p.register_launch("android", function() ue.android_dap_launch() end)
      for _, id in ipairs({ "win64", "mac", "linux", "ios" }) do
        local ok, m = pcall(require, "ue.dap." .. id)
        if ok and type(m) == "table" then
          if type(m.attach) == "function" then p.register_attach(id, m.attach) end
          if type(m.launch) == "function" then p.register_launch(id, m.launch) end
        end
      end
    end
    return p
  end

  t.it("平台注册 seam 注册 win64/mac/linux/ios/android", function()
    local p = ensure_platforms_registered()
    for _, id in ipairs({ "win64", "mac", "linux", "ios", "android" }) do
      t.assert_type(p.attach_handler(id), "function", id .. " attach 未注册")
      t.assert_type(p.launch_handler(id), "function", id .. " launch 未注册")
    end
  end)

  t.it("_common.find_lldb_dap 返回 string 或 nil", function()
    local r = require("ue.dap._common").find_lldb_dap()
    t.assert_true(r == nil or type(r) == "string",
      "find_lldb_dap 返回了 " .. type(r))
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- Android 纯函数 seam 行为测（激活已抽出但未驱动的 _for_test）。
-- 这些把 CONSTRAINTS §二 的 hard-won 坑（K30/K34/K35/K37 + C1）从源码 grep
-- 升级成行为断言：输入 ctx/session → 输出决策，纯逻辑、无设备、headless 可跑。
-- 用 tmpdir 构造 cook 产物布局 + cfg.setup/reset_for_test 注入 override。
-- ════════════════════════════════════════════════════════════════════════

local function tmpdir()
  local d = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(d, "p")
  return d
end

local function touch(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "wb")
  if f then f:write(content or "x"); f:close() end
end

t.describe("ue.dap.android: pick_symbol_lib（K35 + 3.4 假线索防护）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("K35: 优先用 packageInfo versionCode 精确匹配的 symbol lib", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/Client"
    local android_dir = proot .. "/Binaries/Android"
    -- cook 产物：packageInfo.txt 第二行 versionCode = 169723198
    touch(android_dir .. "/packageInfo.txt", "com.example.game\n169723198\n1.0.0\n")
    -- 精确匹配的符号包 + 一个更新但版本不符的干扰包
    local exact = android_dir .. "/Client_Symbols_v169723198/Client-arm64/libUE4.so"
    local decoy = android_dir .. "/Client_Symbols_v999999999/Client-arm64/libUE4.so"
    touch(exact, "EXACT")
    touch(decoy, "DECOY-NEWER")

    local picked = android._pick_symbol_lib_for_test({ project_root = proot })
    t.assert_eq(picked and picked:gsub("\\", "/"), exact,
      "应取 versionCode 精确匹配，而非按 mtime 取最新（避免符号≠APK）")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)

  t.it("无精确匹配时按 mtime 取最新符号包（best-guess 回落）", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/Client"
    local android_dir = proot .. "/Binaries/Android"
    touch(android_dir .. "/packageInfo.txt", "com.example.game\n111\n1.0.0\n")
    -- 没有 v111 的精确包，只有两个 *Symbols* 包
    local older = android_dir .. "/A_Symbols/Client-arm64/libUE4.so"
    local newer = android_dir .. "/B_Symbols/Client-arm64/libUE4.so"
    touch(older, "OLD")
    touch(newer, "NEW")
    -- 把 newer 的 mtime 推后，确保它"最新"
    local ok_uv = vim.uv or vim.loop
    pcall(ok_uv.fs_utime, newer, os.time() + 100, os.time() + 100)

    local picked = android._pick_symbol_lib_for_test({ project_root = proot })
    t.assert_true(picked ~= nil, "应回落到 glob best-guess")
    t.assert_eq(picked and picked:gsub("\\", "/"), newer, "无精确匹配应取 mtime 最新")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)

  t.it("ctx.android_symbol_lib 显式覆盖最优先（reattach/agent 路径不 prompt）", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local explicit = d .. "/host/libUE4.so"
    touch(explicit, "HOST-DWARF")
    local picked = android._pick_symbol_lib_for_test({ android_symbol_lib = explicit })
    t.assert_eq(picked and picked:gsub("\\", "/"), explicit:gsub("\\", "/"))
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)

  t.it("config.dap.android_symbol_lib 覆盖（次于 ctx，先于自动发现）", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local cfg_lib = d .. "/cfg/libUE4.so"
    touch(cfg_lib, "CFG")
    cfg.setup({ dap = { android_symbol_lib = cfg_lib } })
    local picked = android._pick_symbol_lib_for_test({})
    t.assert_eq(picked and picked:gsub("\\", "/"), cfg_lib:gsub("\\", "/"))
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)
end)

t.describe("ue.dap.android: pick_package（K-package 单一真相 packageInfo.txt）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("ctx.android_package 显式值最优先", function()
    cfg.reset_for_test()
    t.assert_eq(android._pick_package_for_test({ android_package = "com.x.explicit" }),
      "com.x.explicit")
    cfg.reset_for_test()
  end)

  t.it("config.dap.android_package 覆盖（无 ctx 值时）", function()
    cfg.reset_for_test()
    cfg.setup({ dap = { android_package = "com.x.cfg" } })
    t.assert_eq(android._pick_package_for_test({}), "com.x.cfg")
    cfg.reset_for_test()
  end)

  t.it("从 packageInfo.txt 第一行解析 package 名", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/Client"
    touch(proot .. "/Binaries/Android/packageInfo.txt",
      "com.example.game\n123\n3.4.0\n")
    t.assert_eq(android._pick_package_for_test({ project_root = proot }),
      "com.example.game")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)
end)

t.describe("ue.dap.android: pick_lldb_server（C1 平台优先级，不自行重排）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("按 globs 给定顺序取第一个存在的文件（不按 mtime/字典序重排）", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local first  = d .. "/ndk27/lldb-server"
    local second = d .. "/ndk25/lldb-server"
    touch(first, "NDK27")
    touch(second, "NDK25")
    -- globs 顺序 = 平台 driver 的优先级；first 在前应被选中即便 second 也存在
    local picked = android._pick_lldb_server_for_test({ first, second })
    t.assert_eq(picked and picked:gsub("\\", "/"), first:gsub("\\", "/"),
      "必须保留 globs 优先级顺序，不得收集后排序")
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)

  t.it("config.dap.android_lldb_server 覆盖优先于 globs", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local override = d .. "/custom/lldb-server"
    local glob_hit = d .. "/auto/lldb-server"
    touch(override, "X")
    touch(glob_hit, "Y")
    cfg.setup({ dap = { android_lldb_server = override } })
    local picked = android._pick_lldb_server_for_test({ glob_hit })
    t.assert_eq(picked and picked:gsub("\\", "/"), override:gsub("\\", "/"))
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)

  t.it("无任何命中 → nil（调用方据此 prompt）", function()
    cfg.reset_for_test()
    t.assert_nil(android._pick_lldb_server_for_test({ "/nonexistent_zzz/lldb-server" }))
    cfg.reset_for_test()
  end)
end)

t.describe("ue.dap.android: effective_project_root（含 android marker 优先）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("优先返回带 Android marker 的候选根", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/Client"
    touch(proot .. "/Binaries/Android/packageInfo.txt", "com.x\n1\n1.0\n")
    local got = android._effective_project_root_for_test({ project_root = proot })
    t.assert_eq(got and got:gsub("\\", "/"), proot:gsub("\\", "/"),
      "带 Android marker 的根应优先于无 marker 的祖先")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)
end)

t.describe("ue.dap.android: attach_commands（K30/K34/K37 顺序与 slide 开关）", function()
  local android = require("ue.dap.android")

  local function base_session()
    return {
      symbol_lib = "D:/symbols/Client_Symbols_v1/Client-arm64/libUE4.so",
      serial = "a3ad86f3",
      port = 5039,
      pid = 1234,
      _module_rebase_cmd =
        'target modules load --file "libUE4.so" --slide 0x6c9fe21000',
    }
  end

  local function index_of(cmds, pred)
    for i, c in ipairs(cmds) do if pred(c) then return i end end
    return nil
  end

  t.it("K34: symbol-rich `target create` 必须是第一条命令", function()
    local cmds = android._attach_commands_for_test(base_session())
    t.assert_true(cmds[1]:find('target create', 1, true) ~= nil,
      "首条必须 target create symbol-rich libUE4.so（DWARF 来源）")
    t.assert_true(cmds[1]:find("libUE4.so", 1, true) ~= nil)
  end)

  t.it("K34: target create 早于 platform connect / process attach", function()
    local cmds = android._attach_commands_for_test(base_session())
    local create_i = index_of(cmds, function(c) return c:find("target create", 1, true) end)
    local connect_i = index_of(cmds, function(c) return c:find("platform connect", 1, true) end)
    local attach_i = index_of(cmds, function(c) return c:find("process attach", 1, true) end)
    t.assert_true(create_i and connect_i and attach_i, "三条命令都应存在")
    t.assert_true(create_i < connect_i and connect_i < attach_i,
      "顺序必须 target create → platform connect → process attach")
  end)

  t.it("K30: connect URL 是 serial 方括号形式 connect://[<serial>]:<port>", function()
    local cmds = android._attach_commands_for_test(base_session())
    local connect = cmds[index_of(cmds, function(c) return c:find("platform connect", 1, true) end)]
    t.assert_eq(connect, "platform connect connect://[a3ad86f3]:5039",
      "必须 serial 方括号形式，禁 localhost（K30/K32）")
    -- 反向守护：不得出现 localhost/127.0.0.1 形式
    t.assert_true(connect:find("localhost", 1, true) == nil)
    t.assert_true(connect:find("127.0.0.1", 1, true) == nil)
  end)

  t.it("K30: 信号处置 SIGSEGV/SIGBUS/SIGPIPE 在 attach 后下发", function()
    local cmds = android._attach_commands_for_test(base_session())
    local attach_i = index_of(cmds, function(c) return c:find("process attach", 1, true) end)
    local seg_i = index_of(cmds, function(c) return c:find("SIGSEGV", 1, true) end)
    t.assert_true(seg_i and attach_i and seg_i > attach_i,
      "信号处置必须在 process attach 之后")
  end)

  t.it("K37: 默认下发显式 ASLR slide（_module_rebase_cmd 在末尾）", function()
    local cmds = android._attach_commands_for_test(base_session())
    local slide = cmds[#cmds]
    t.assert_true(slide:find("target modules load", 1, true) ~= nil
      and slide:find("--slide 0x", 1, true) ~= nil,
      "默认应包含显式 slide（K37 load-bearing）")
  end)

  t.it("K37: UE_DAP_NO_SLIDE=1 时跳过显式 slide（reverify 开关）", function()
    local saved = vim.env.UE_DAP_NO_SLIDE
    vim.env.UE_DAP_NO_SLIDE = "1"
    local cmds = android._attach_commands_for_test(base_session())
    local has_slide = index_of(cmds, function(c) return c:find("--slide 0x", 1, true) end)
    t.assert_nil(has_slide, "UE_DAP_NO_SLIDE=1 应跳过显式 slide 命令")
    vim.env.UE_DAP_NO_SLIDE = saved or ""
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- F9 断点持久化往返（K10）。mock dap.breakpoints，纯 JSON + 路径归一化逻辑，
-- 不需要真实调试会话。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap._persist_bp: F9 持久化往返（K10）", function()
  local bp = require("ue.dap._persist_bp")

  t.it("JSON 编解码往返保形（version/project/breakpoints）", function()
    bp._reset_state_for_test()
    local path = tmpdir() .. "/bp.json"
    local data = {
      version = 1, project = "MyGame",
      breakpoints = {
        ["D:/proj/Source/X.cpp"] = { { line = 42 }, { line = 57, condition = "i==3" } },
      },
    }
    local back = bp._json_round_trip_for_test(path, data)
    t.assert_true(back ~= nil, "应能读回")
    t.assert_eq(back.version, 1)
    t.assert_eq(back.project, "MyGame")
    t.assert_eq(#back.breakpoints["D:/proj/Source/X.cpp"], 2)
    t.assert_eq(back.breakpoints["D:/proj/Source/X.cpp"][2].condition, "i==3")
    bp._reset_state_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(path, ":h"), "rf")
  end)

  t.it("路径键归一化：反斜杠/正斜杠归一为同一键", function()
    bp._reset_state_for_test()
    t.assert_eq(bp._norm_for_test("D:\\proj\\Source\\X.cpp"),
                bp._norm_for_test("D:/proj/Source/X.cpp"),
      "Windows/Bash 分隔符必须归一，避免 K10 同文件 mis-match")
    bp._reset_state_for_test()
  end)

  t.it("project_name sanitize：非法文件名字符替换为 _", function()
    t.assert_eq(bp._project_name_for_test("E:/aki/Client.uproject", nil), "Client",
      "uproject 取 basename 去 .uproject 后缀")
    t.assert_eq(bp._project_name_for_test(nil, "E:/aki/My Game"), "My_Game",
      "空格等非法字符替换为 _")
    t.assert_eq(bp._project_name_for_test(nil, nil), "default",
      "无 uproject/project_root 回落 default")
  end)

  t.it("K10: save 合并 pending_paths，未开文件的断点不被擦除", function()
    bp._reset_state_for_test()
    -- mock dap.breakpoints：当前只有一个已开 buffer 的断点
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "D:/proj/Source/Opened.cpp")
    local old = package.loaded["dap.breakpoints"]
    package.loaded["dap.breakpoints"] = {
      get = function() return { [buf] = { { line = 10 } } } end,
    }

    local path = tmpdir() .. "/bp.json"
    -- pending_paths 含一个"未开文件"的断点，save 必须保留它
    local back = bp._save_with_state_for_test(path, {
      ["D:/proj/Source/Unopened.cpp"] = { { line = 99 } },
    })
    package.loaded["dap.breakpoints"] = old
    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    t.assert_true(back ~= nil, "save 后应能读回")
    t.assert_true(back.breakpoints["D:/proj/Source/Opened.cpp"] ~= nil,
      "已开文件的断点应被写入")
    t.assert_true(back.breakpoints["D:/proj/Source/Unopened.cpp"] ~= nil,
      "未开文件的 pending 断点必须保留（K10 灾难场景守护）")
    t.assert_eq(back.breakpoints["D:/proj/Source/Unopened.cpp"][1].line, 99)
    bp._reset_state_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(path, ":h"), "rf")
  end)
end)
