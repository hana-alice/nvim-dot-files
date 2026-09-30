-- Recover the Android UBT driver layout from explicit response-file options.
-- This is layout evidence, not an action-database compiler identity or a claim
-- that clangd uses the build compiler's parser. Never select an ambient NDKROOT.
local M = {}
local fs = require("ue.core.fs")
local platform = require("utils.platform")

function M.resolve(args, _cwd)
  local options, index = {}, 1
  local names = { ["-target"] = "target", ["--target"] = "target",
    ["--gcc-toolchain"] = "toolchain", ["--sysroot"] = "sysroot" }
  while index <= #args do
    local argument = args[index]
    if argument == "--" then break end
    local option, value = argument:match("^([^=]+)=(.*)$")
    local name = names[option or argument]
    if name then
      if not option then
        value = args[index + 1]
        if value and value:sub(1, 1) ~= "-" then index = index + 1 else value = nil end
      end
      options[name] = value ~= "" and value or nil
    end
    index = index + 1
  end

  local function fallback(reason)
    return "clang++", { source = "fallback", reason = reason }
  end
  if not options.target then return fallback("target-unavailable") end
  local android = options.target:match("%-android%d*$") or options.target:match("%-androideabi%d*$")
  if not android then return fallback("target-not-android") end
  if not options.toolchain then return fallback("toolchain-unavailable") end
  if not options.sysroot then return fallback("sysroot-unavailable") end
  if not fs.is_absolute_path(options.toolchain) then return fallback("toolchain-not-absolute") end
  if not fs.is_absolute_path(options.sysroot) then return fallback("sysroot-not-absolute") end
  local root = vim.fs.normalize(options.toolchain):gsub("/+$", "")
  local sysroot = vim.fs.normalize(options.sysroot):gsub("/+$", "")
  local driver = platform.driver()
  if driver.path_key(sysroot) ~= driver.path_key(root .. "/sysroot") then
    return fallback("toolchain-sysroot-mismatch")
  end
  local compiler = root .. "/bin/clang++" .. driver.exe_suffix
  if not fs.is_file(compiler) or vim.fn.executable(compiler) ~= 1 then return fallback("compiler-unavailable") end
  return compiler, { source = "ubt-android-toolchain-layout", reason = "resolved", toolchain = root }
end

return M
