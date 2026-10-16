-- ue.dap._android_crash — symbolicate Android native crashes into quickfix.
--
-- Source: the device crash log buffer (`logcat -b crash -d`), which carries the
-- debuggerd tombstone summary without root. Frames of the UE module are
-- resolved with llvm-symbolizer against the symbol library selected by the
-- DAP symbol chain (build-id authority, K64/K65/K66); other frames are kept
-- verbatim so nothing is silently dropped.

local M = {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---Parse tombstone/backtrace frames from crash-log text.
---Recognises lines such as
---  `#05 pc 000000000a1b2c3d  /data/app/~~x/lib/arm64/libUE4.so (FEngineLoop::Tick()+60) (BuildId: ab12)`
---@param text string
---@return {index:integer, pc:string, module:string, basename:string, symbol:string|nil, build_id:string|nil, raw:string}[]
function M.parse_frames(text)
  local frames = {}
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local index, pc, module = line:match("#(%d+)%s+pc%s+(%x+)%s+(%S+)")
    if index then
      frames[#frames + 1] = {
        index = tonumber(index),
        pc = pc:lower(),
        module = module,
        basename = module:match("([^/]+)$") or module,
        symbol = line:match("%((.-%+%d+)%)"),
        build_id = line:match("BuildId:%s*(%x+)"),
        raw = trim(line),
      }
    end
  end
  return frames
end

---Keep only the most recent crash: frames restart at #00 for each new tombstone.
function M.last_crash(frames)
  local start = 1
  for i, frame in ipairs(frames or {}) do
    if frame.index == 0 then start = i end
  end
  local out = {}
  for i = start, #(frames or {}) do out[#out + 1] = frames[i] end
  return out
end

---Parse `llvm-symbolizer --output-style=GNU` output for one address.
---Returns the innermost function and file:line (inlined frames come first).
function M.parse_symbolizer(output)
  local lines = {}
  for line in (tostring(output or "") .. "\n"):gmatch("([^\n]*)\n") do
    line = trim(line:gsub("\r$", ""))
    if line ~= "" then lines[#lines + 1] = line end
  end
  local func, location = lines[1], lines[2]
  if not location then return nil end
  local file, lnum = location:match("^(.+):(%d+)$")
  if not file then file, lnum = location:match("^(.+):(%d+):%d+$") end
  if not file or file == "??" or lnum == "0" then return { func = func } end
  return { func = func, file = file, lnum = tonumber(lnum) }
end

---Build quickfix items. `resolved[i]` is the symbolizer result for frames[i] (or nil).
function M.quickfix_items(frames, resolved)
  local items = {}
  for i, frame in ipairs(frames) do
    local hit = resolved and resolved[i]
    local text = ("#%02d %s %s"):format(frame.index, frame.basename,
      (hit and hit.func) or frame.symbol or ("pc 0x" .. frame.pc))
    if hit and hit.file then
      items[#items + 1] = { filename = hit.file, lnum = hit.lnum, text = text }
    else
      items[#items + 1] = { text = text .. "  [unresolved]" }
    end
  end
  return items
end

-- The symbolizer ships next to the pinned clangd/lldb-dap LLVM install; the
-- host driver owns where that is, so derive it from the resolved clangd.
local function find_symbolizer()
  local plat = require("utils.platform")
  local found = plat.resolve_tool({ name = "llvm-symbolizer", env = { "UE_LLVM_SYMBOLIZER" },
    driver_candidates = function(driver)
      local out = {}
      local clangd = plat.resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
        driver_candidates = function(d) return d.default_clangd_candidates() end })
      if clangd.ok then
        local dir = vim.fs.dirname(clangd.path)
        local ext = tostring(driver.exe_suffix or "")
        out[#out + 1] = vim.fs.joinpath(dir, "llvm-symbolizer" .. ext)
      end
      out[#out + 1] = "llvm-symbolizer"
      return out
    end })
  return found.ok and found.path or nil
end

---Symbolicate frames of `runtime_basename` with one llvm-symbolizer process.
---done(resolved) where resolved[i] matches frames[i].
function M.symbolize(frames, symbol_lib, runtime_basename, done, opts)
  opts = opts or {}
  local symbolizer = opts.symbolizer or find_symbolizer()
  local wanted, input = {}, {}
  for i, frame in ipairs(frames) do
    if frame.basename == runtime_basename then
      wanted[#wanted + 1] = i
      input[#input + 1] = "0x" .. frame.pc
    end
  end
  if not symbolizer then return done({}, "llvm-symbolizer not found (set UE_LLVM_SYMBOLIZER)") end
  if not symbol_lib or #wanted == 0 then return done({}) end
  local system = opts.system or vim.system
  local ok = pcall(system, { symbolizer, "--obj=" .. symbol_lib, "--output-style=GNU",
    "--functions=linkage", "--no-inlines", "--demangle" },
    { text = true, stdin = table.concat(input, "\n") .. "\n" }, function(res)
      vim.schedule(function()
        local resolved = {}
        if res and res.code == 0 then
          -- One two-line record per input address.
          local lines = {}
          for line in ((res.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
            line = line:gsub("\r$", "")
            if line ~= "" then lines[#lines + 1] = line end
          end
          for n, frame_index in ipairs(wanted) do
            resolved[frame_index] = M.parse_symbolizer((lines[2 * n - 1] or "") .. "\n" .. (lines[2 * n] or ""))
          end
        end
        done(resolved, res and res.code ~= 0 and trim(res.stderr) or nil)
      end)
    end)
  if not ok then done({}, "failed to start llvm-symbolizer") end
end

---:UEAndroidCrash — pull the crash buffer, symbolicate, open quickfix.
function M.run(opts)
  opts = opts or {}
  local device = require("utils.android_device")
  device.ensure({ prompt = "Select Android device for crash report:" }, function(serial)
    if not serial then return end
    local adb = device.adb_executable()
    vim.system({ adb, "-s", serial, "logcat", "-b", "crash", "-d" }, { text = true }, function(res)
      vim.schedule(function()
        if not res or res.code ~= 0 then
          return vim.notify("[UEAndroidCrash] adb logcat -b crash failed: " .. trim(res and res.stderr), vim.log.levels.ERROR)
        end
        local frames = M.last_crash(M.parse_frames(res.stdout))
        if #frames == 0 then
          return vim.notify("[UEAndroidCrash] no native crash frames in the device crash buffer", vim.log.levels.INFO)
        end
        local android = require("ue.dap.android")
        local ctx = opts.context or require("ue.dap").resolve_android_dap_context()
        local symbol_lib, runtime_basename = android.symbol_lib(ctx)
        runtime_basename = runtime_basename or "libUE4.so"
        M.symbolize(frames, symbol_lib, runtime_basename, function(resolved, err)
          vim.fn.setqflist({}, " ", { title = "UEAndroidCrash " .. serial, items = M.quickfix_items(frames, resolved) })
          vim.cmd("copen")
          if err then vim.notify("[UEAndroidCrash] " .. err .. " — showing raw frames", vim.log.levels.WARN) end
          if not symbol_lib then
            vim.notify("[UEAndroidCrash] no symbol library matched the current build; frames are unresolved",
              vim.log.levels.WARN)
          end
        end)
      end)
    end)
  end)
end

return M
