-- Android package name discovery shared by install / launch / logcat / DAP.
-- Every Android entry point used to open its own `vim.fn.input("Android
-- package name: ")` with no candidates. This module offers a picker built from
-- the project's own cook output (packageInfo.txt) plus the third-party
-- packages installed on the selected device, and remembers the choice through
-- the caller's existing persistence (state field `android_package`).

local M = {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---Parse `adb shell pm list packages` output into package names.
---@param output string
---@return string[]
function M.parse_pm_list(output)
  local names = {}
  for line in (tostring(output or "") .. "\n"):gmatch("([^\n]*)\n") do
    local name = trim(line:gsub("\r$", "")):match("^package:(%S+)$")
    if name then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

---Order candidates: known project packages first, then device packages; no duplicates.
---@param known string[] packages derived from the project (state, config, cook output)
---@param device string[] packages installed on the device
---@return {name:string, source:string}[]
function M.candidates(known, device)
  local seen, rows = {}, {}
  for _, name in ipairs(known or {}) do
    name = trim(name)
    if name ~= "" and not seen[name] then
      seen[name] = true
      rows[#rows + 1] = { name = name, source = "project" }
    end
  end
  for _, name in ipairs(device or {}) do
    if not seen[name] then
      seen[name] = true
      rows[#rows + 1] = { name = name, source = "device" }
    end
  end
  return rows
end

local MANUAL = { name = "", source = "manual" }

---Pick a package asynchronously. done(name|nil).
---opts.known: string[]; opts.adb/opts.serial: list device packages when present;
---opts.ui_select / opts.input / opts.system: headless test seams.
function M.pick(opts, done)
  opts = opts or {}
  done = done or function() end
  local ui_select = opts.ui_select or vim.ui.select
  local input = opts.input or vim.ui.input
  local function choose(device_packages)
    local rows = M.candidates(opts.known, device_packages)
    rows[#rows + 1] = MANUAL
    ui_select(rows, {
      prompt = opts.prompt or "Android package:",
      format_item = function(row)
        if row.source == "manual" then return "Type a package name…" end
        return ("%s  (%s)"):format(row.name, row.source)
      end,
    }, function(choice)
      if not choice then return done(nil) end
      if choice.source ~= "manual" then return done(choice.name) end
      input({ prompt = "Android package name: " }, function(typed)
        typed = trim(typed)
        done(typed ~= "" and typed or nil)
      end)
    end)
  end
  if not (opts.adb and opts.serial) then return choose({}) end
  local system = opts.system or vim.system
  local ok = pcall(system, { opts.adb, "-s", opts.serial, "shell", "pm", "list", "packages", "-3" },
    { text = true }, function(res)
      vim.schedule(function()
        choose(res and res.code == 0 and M.parse_pm_list(res.stdout) or {})
      end)
    end)
  if not ok then choose({}) end
end

return M
