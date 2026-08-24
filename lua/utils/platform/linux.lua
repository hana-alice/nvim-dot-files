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

local shell = require("utils.platform.shell")

local function join_engine_path(engine_root, suffix)
  local root = tostring(engine_root or "")
  if root:sub(-1) == "/" then
    return root .. suffix
  end
  return root .. "/" .. suffix
end

function M.shell_entry(kind)
  kind = kind or "default"
  if kind ~= "default" and kind ~= "posix" then
    return nil, "unsupported shell on Linux host: " .. tostring(kind)
  end
  if vim.fn.executable("bash") == 1 then return "/bin/bash" end
  if vim.fn.executable("zsh") == 1 then return "/bin/zsh" end
  return vim.o.shell ~= "" and vim.o.shell or "/bin/sh"
end


function M.shell()
  return M.shell_entry("default")
end

function M.allows_osc52()
  return true
end

function M.path_key(path)
  return tostring(path or "")
end

function M.query_driver_globs()
  return { "**/clang*", "**/gcc", "**/g++", "**/cc", "**/c++" }
end

function M.cdb_compiler_candidates()
  return { "clang++", "clang", "gcc", "g++", "cc", "c++" }
end

function M.lldb_python_relative_paths()
  return { "lib/python3/dist-packages/lldb", "lib/site-packages/lldb" }
end

function M.restart_fallback_candidates(cwd, env)
  local candidates = {}
  if env and env.TERMINAL and env.TERMINAL ~= "" then
    candidates[#candidates + 1] = {
      client = "linux",
      bin = env.TERMINAL,
      args = { "-e", "nvim" },
      cwd = cwd,
      reason = "$TERMINAL=" .. env.TERMINAL,
    }
  end
  vim.list_extend(candidates, {
    { client = "linux", bin = "kitty", args = { "--directory", cwd, "nvim" }, cwd = cwd, reason = "kitty fallback" },
    { client = "linux", bin = "alacritty", args = { "--working-directory", cwd, "-e", "nvim" }, cwd = cwd, reason = "alacritty fallback" },
    { client = "linux", bin = "wezterm", args = { "start", "--cwd", cwd, "--", "nvim" }, cwd = cwd, reason = "wezterm fallback" },
    { client = "linux", bin = "foot", args = { "--working-directory=" .. cwd, "nvim" }, cwd = cwd, reason = "foot fallback" },
    { client = "linux", bin = "xterm", args = { "-e", "sh", "-c", "cd " .. vim.fn.shellescape(cwd) .. " && nvim" }, cwd = cwd, reason = "xterm fallback" },
  })
  return candidates
end

function M.restart_shutdown_delay_ms()
  return 400
end

function M.code_search_install_hint(config_root)
  local script = tostring(config_root or "") .. "/scripts/install_csearch.sh"
  return "sh " .. shell.quote("posix", script)
end

function M.cmd_quote(value)
  return shell.quote("posix", value)
end

function M.host_path(path)
  return tostring(path or ""):gsub("\\", "/")
end

function M.default_target()
  return "Linux"
end

function M.launch_process_plan(spec)
  spec = spec or {}
  return {
    executable = M.host_path(spec.executable or spec.exe),
    args = vim.deepcopy(spec.args or {}),
    cwd = M.host_path(spec.cwd or ""),
    metadata = { launch_mode = "detach" },
  }
end

function M.follow_file_plan(path)
  path = M.host_path(path)
  return shell.follow_file("posix", M.shell_entry("posix"), path, vim.fs.dirname(path))
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

function M.python_candidates()
  return { "python3", "python" }
end

function M.clangd_indexer_candidates()
  return {
    "/mnt/c/Program Files/LLVM/bin/clangd-indexer.exe",
    "clangd-indexer",
    "clangd-indexer.exe",
    "C:/Program Files/LLVM/bin/clangd-indexer.exe",
  }
end

function M.shared_library_extension()
  return ".so"
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
    "lldb-dap",
  }
end

function M.default_lldb_server_paths()
  -- Android DAP is not declared for Linux in the host-target matrix.
  return {}
end

function M.ue_build_entry(engine_root)
  return join_engine_path(engine_root, "Engine/Build/BatchFiles/Linux/Build.sh"), nil
end

function M.ue_uat_entry(engine_root)
  return join_engine_path(engine_root, "Engine/Build/BatchFiles/RunUAT.sh"), nil
end

return M
