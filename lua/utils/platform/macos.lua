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

function M.default_codelldb_paths()
  local data = vim.fn.stdpath("data")
  return {
    data .. "/mason/packages/codelldb/extension/adapter/codelldb",
    "codelldb",
  }
end

function M.default_lldb_server_paths()
  -- macOS native debugging uses `lldb` directly via codelldb; for
  -- Android targets users typically install NDK side-by-side under
  -- ~/Library/Android/sdk/ndk/*. Globs resolved by callers.
  local home = (vim.uv or vim.loop).os_homedir() or ""
  if home == "" then return {} end
  return {
    home .. "/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
  }
end

return M
