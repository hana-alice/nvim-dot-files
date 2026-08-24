-- utils.platform.macos — macOS driver.
--
-- Owns only native macOS host behavior; foreign host capabilities are absent
-- rather than represented by fake stubs.

local M = {
  id         = "macos",
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

local function applescript_string(value)
  value = tostring(value or "")
  value = value:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. value .. '"'
end

function M.shell_entry(kind)
  kind = kind or "default"
  if kind ~= "default" and kind ~= "posix" then
    return nil, "unsupported shell on macOS host: " .. tostring(kind)
  end
  return "/bin/zsh"
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
  return { "clang++", "clang", "cc", "c++" }
end

function M.lldb_python_relative_paths()
  return { "lib/site-packages/lldb", "lib/python3/dist-packages/lldb" }
end

function M.restart_fallback_candidates(cwd, env)
  local candidates = {}
  if env and env.TERMINAL and env.TERMINAL ~= "" then
    candidates[#candidates + 1] = {
      client = "mac",
      bin = env.TERMINAL,
      args = { "-e", "nvim" },
      cwd = cwd,
      reason = "$TERMINAL=" .. env.TERMINAL,
    }
  end
  candidates[#candidates + 1] = {
    client = "mac",
    bin = "kitty",
    args = { "--directory", cwd, "nvim" },
    cwd = cwd,
    reason = "kitty fallback",
  }
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
  return "Mac"
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
  vim.fn.jobstart({ "open", path }, { detach = true })
end

function M.reveal_file(path)
  if not path or path == "" then return end
  vim.fn.jobstart({ "open", "-R", path }, { detach = true })
end

function M.folder_picker_plan(prompt)
  local script = "POSIX path of (choose folder with prompt "
      .. applescript_string(prompt or "Open Folder") .. ")"
  return {
    executable = "/usr/bin/osascript",
    args = { "-e", script },
    metadata = { operation = "choose-folder" },
  }
end

function M.build_process_snapshot_plan()
  return {
    executable = "/bin/ps",
    args = { "-ww", "-Ao", "pid=,ppid=,state=,etime=,%cpu=,%mem=,command=" },
    metadata = { operation = "build-process-snapshot" },
  }
end

function M.default_clangd_candidates()
  -- Prefer versioned LLVM 22 installs, including the user-local fallback used
  -- when Homebrew's bottle registry is unavailable. Keep the unversioned
  -- formula as a compatible fallback when it is also on LLVM 22.1.x; the
  -- UECompileForNvim preflight remains the final version gate.
  return {
    vim.fn.expand("~/.local/opt/llvm@22/bin/clangd"),
    "/opt/homebrew/opt/llvm@22/bin/clangd",
    "/usr/local/opt/llvm@22/bin/clangd",
    "/opt/homebrew/opt/llvm/bin/clangd",
    "/usr/local/opt/llvm/bin/clangd",
    "/Library/Developer/CommandLineTools/usr/bin/clangd",
    "clangd",
  }
end

function M.python_candidates()
  return { "python3", "python" }
end

function M.clangd_indexer_candidates()
  return { "clangd-indexer" }
end

function M.shared_library_extension()
  return ".dylib"
end

function M.default_lldb_dap_paths()
  -- Homebrew LLVM (Apple Silicon then Intel), then Xcode CLT lldb-dap
  -- (Xcode 15+ ships it). PATH fallback caught upstream.
  return {
    "/opt/homebrew/opt/llvm/bin/lldb-dap",
    "/usr/local/opt/llvm/bin/lldb-dap",
    "/Library/Developer/CommandLineTools/usr/bin/lldb-dap",
    "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-dap",
    "lldb-dap",
  }
end

function M.default_lldb_server_paths()
  -- This repository intentionally does not support macOS-hosted Android DAP.
  return {}
end

function M.ue_build_entry(engine_root)
  return join_engine_path(engine_root, "Engine/Build/BatchFiles/Mac/Build.sh"), nil
end

function M.ue_uat_entry(engine_root)
  return join_engine_path(engine_root, "Engine/Build/BatchFiles/RunUAT.sh"), nil
end

function M.xcrun_entry()
  return "/usr/bin/xcrun", nil
end

function M.security_entry()
  return "/usr/bin/security", nil
end

function M.plutil_entry()
  return "/usr/bin/plutil", nil
end

function M.ios_deploy_entry()
  local path = vim.fn.exepath("ios-deploy")
  if path == "" then
    return nil, "ios-deploy is not installed or not executable"
  end
  return path, nil
end

function M.idevice_id_entry()
  local path = vim.fn.exepath("idevice_id")
  if path == "" then
    return nil, "idevice_id is not installed or not executable"
  end
  return path, nil
end

function M.ideviceinfo_entry()
  local path = vim.fn.exepath("ideviceinfo")
  if path == "" then
    return nil, "ideviceinfo is not installed or not executable"
  end
  return path, nil
end

return M
