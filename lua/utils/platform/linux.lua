-- utils.platform.linux — Linux driver.
--
-- Phase A defaults. Distro-aware tweaks (xdg-open variants, snap-paths,
-- flatpak-paths) are intentionally NOT here — keep the driver minimal and
-- override per-host via `ue.config` overrides when needed.

local M = {
  id         = "linux",
  path_sep   = "/",
  list_sep   = ":",
  exe_suffix = "",
}

function M.shell()
  if vim.fn.executable("bash") == 1 then return "/bin/bash" end
  if vim.fn.executable("zsh") == 1 then return "/bin/zsh" end
  return vim.o.shell ~= "" and vim.o.shell or "/bin/sh"
end

function M.cmd_quote(value)
  local s = tostring(value or "")
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

function M.open_path(path)
  if not path or path == "" then return end
  vim.fn.jobstart({ "xdg-open", path }, { detach = true })
end

function M.reveal_file(path)
  -- xdg-open does not support "select file", so open the parent dir.
  if not path or path == "" then return end
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    vim.fn.jobstart({ "xdg-open", dir }, { detach = true })
  end
end

function M.default_clangd_candidates()
  return {
    "/usr/lib/llvm-18/bin/clangd",
    "/usr/lib/llvm-17/bin/clangd",
    "/usr/lib/llvm-16/bin/clangd",
    "/usr/bin/clangd",
    "clangd",
  }
end

function M.default_lldb_dap_paths()
  -- Apt-installed LLVM lays down /usr/bin/lldb-dap-<ver>; LLVM tarballs
  -- land in /usr/lib/llvm-<ver>/bin. Try the most common newer versions
  -- first; PATH fallback handles whatever name `lldb-dap` resolves to.
  return {
    "/usr/lib/llvm-22/bin/lldb-dap",
    "/usr/lib/llvm-21/bin/lldb-dap",
    "/usr/lib/llvm-20/bin/lldb-dap",
    "/usr/lib/llvm-19/bin/lldb-dap",
    "/usr/lib/llvm-18/bin/lldb-dap",
    "/usr/bin/lldb-dap-22",
    "/usr/bin/lldb-dap-21",
    "/usr/bin/lldb-dap-20",
    "/usr/bin/lldb-dap-19",
    "/usr/bin/lldb-dap-18",
    "/usr/bin/lldb-dap",
  }
end

function M.default_lldb_server_paths()
  -- See utils/platform/windows.lua for the NDK r21 ordering rationale.
  local home = (vim.uv or vim.loop).os_homedir() or ""
  if home == "" then return {} end
  return {
    home .. "/Android/Sdk/ndk/21.*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
    home .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
    home .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/aarch64/lldb-server",
  }
end

return M
