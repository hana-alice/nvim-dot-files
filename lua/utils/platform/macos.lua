-- utils.platform.macos — macOS driver.
--
-- Phase A: bare-but-correct defaults. Subsequent phases will exercise
-- these once a real Mac host is available; for now this keeps headless
-- tests on Mac green.

local M = {
  id         = "macos",
  path_sep   = "/",
  list_sep   = ":",
  exe_suffix = "",
}

function M.shell()
  if vim.fn.executable("zsh") == 1 then return "/bin/zsh" end
  if vim.fn.executable("bash") == 1 then return "/bin/bash" end
  return vim.o.shell ~= "" and vim.o.shell or "/bin/sh"
end

function M.cmd_quote(value)
  -- POSIX single-quote: wrap and escape any embedded single quote.
  local s = tostring(value or "")
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

function M.open_path(path)
  if not path or path == "" then return end
  vim.fn.jobstart({ "open", path }, { detach = true })
end

function M.reveal_file(path)
  if not path or path == "" then return end
  vim.fn.jobstart({ "open", "-R", path }, { detach = true })
end

function M.default_clangd_candidates()
  -- Order: Homebrew LLVM (Apple Silicon), Homebrew LLVM (Intel),
  -- Xcode toolchain, system PATH.
  return {
    "/opt/homebrew/opt/llvm/bin/clangd",
    "/usr/local/opt/llvm/bin/clangd",
    "/Library/Developer/CommandLineTools/usr/bin/clangd",
    "clangd",
  }
end

function M.default_lldb_dap_paths()
  -- Homebrew LLVM (Apple Silicon then Intel), then Xcode CLT lldb-dap
  -- (Xcode 15+ ships it). PATH fallback caught upstream.
  return {
    "/opt/homebrew/opt/llvm/bin/lldb-dap",
    "/usr/local/opt/llvm/bin/lldb-dap",
    "/Library/Developer/CommandLineTools/usr/bin/lldb-dap",
    "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap",
  }
end

function M.default_lldb_server_paths()
  -- macOS native debugging uses `lldb-dap` directly. For
  -- Android targets users typically install NDK side-by-side under
  -- ~/Library/Android/sdk/ndk/*. Globs resolved by callers.
  -- See utils/platform/windows.lua for the NDK r21 ordering rationale.
  local home = (vim.uv or vim.loop).os_homedir() or ""
  if home == "" then return {} end
  return {
    home .. "/Library/Android/sdk/ndk/21.*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
    home .. "/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
    home .. "/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/aarch64/lldb-server",
  }
end

return M
