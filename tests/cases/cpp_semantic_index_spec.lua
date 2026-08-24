local t = require("tests.harness")
t.bootstrap()

local cfg = vim.fn.stdpath("config")
local fixture_root = vim.fs.normalize(cfg .. "/tests/fixtures/cpp_semantic_index_bg")
local runner = vim.fs.normalize(fixture_root .. "/run_clangd_background_lsp.py")

local function normalize(path)
  return vim.fs.normalize(path):gsub("\\", "/")
end

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function read_all(path)
  local fd = assert(io.open(path, "rb"))
  local data = fd:read("*a")
  fd:close()
  return data
end

local function write_all(path, data)
  local fd = assert(io.open(path, "wb"))
  fd:write(data)
  fd:close()
end

local function tool_path(candidates)
  for _, candidate in ipairs(candidates) do
    if candidate and candidate ~= "" then
      local path = normalize(candidate)
      if (vim.uv or vim.loop).fs_stat(path) then
        return path
      end
    end
  end
  return nil
end

local function compact(...)
  local out = {}
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value and value ~= "" then
      out[#out + 1] = value
    end
  end
  return out
end

local function python_cmd()
  local python = vim.fn.exepath("python")
  if python ~= "" then
    return { normalize(python), runner }
  end
  local python3 = vim.fn.exepath("python3")
  if python3 ~= "" then
    return { normalize(python3), runner }
  end
  local py = vim.fn.exepath("py")
  if py ~= "" then
    return { normalize(py), "-3", runner }
  end
  return nil
end

local function copy_fixture_tree(dst)
  for _, name in ipairs({ "api.hpp", "impl.cpp", "calls.cpp", "delta.cpp", "all.cpp" }) do
    write_all(dst .. "/" .. name, read_all(fixture_root .. "/" .. name))
  end
end

local function write_cdb(dst, entries)
  write_all(dst .. "/compile_commands.json", vim.json.encode(entries))
end

local function new_workspace(label, mode)
  local root = normalize(vim.fn.tempname() .. "-" .. label)
  assert(vim.fn.mkdir(root, "p") == 1)
  copy_fixture_tree(root)
  if mode == "full" then
    write_cdb(root, {
      {
        directory = root,
        file = root .. "/all.cpp",
        arguments = { "clang++", "-std=c++20", "-c", root .. "/all.cpp" },
      },
    })
  elseif mode == "partial" then
    write_cdb(root, {})
  else
    error("unknown workspace mode: " .. tostring(mode))
  end
  return root
end

local function exact_command(path)
  return {
    workingDirectory = vim.fs.dirname(path),
    compilationCommand = { "clang++", "-std=c++20", "-c", path },
  }
end

local function full_init_options(root, open_path)
  local synthetic = exact_command(root .. "/all.cpp")
  return {
    compilationDatabasePath = root,
    compilationDatabaseChanges = {
      [root .. "/all.cpp"] = synthetic,
      [open_path] = synthetic,
      [root .. "/api.hpp"] = synthetic,
    },
  }
end

local function partial_init_options(root, open_path)
  return {
    compilationDatabasePath = root,
    compilationDatabaseChanges = {
      [open_path] = exact_command(open_path),
      [root .. "/api.hpp"] = exact_command(root .. "/api.hpp"),
    },
  }
end

local function run_cases(cmd, cases)
  local env = vim.fn.environ()
  env.CLANGD_BG_CASES = vim.json.encode(cases)
  local result = vim.system(cmd, {
    cwd = cfg,
    env = env,
    text = true,
  }):wait()
  t.assert_eq(result.code, 0, result.stderr or result.stdout or "python runner failed")
  return vim.json.decode(vim.trim(result.stdout or ""))
end

t.describe("real clangd controlled background index", function()
  local clangd = tool_path(compact(
    vim.env.UE_CLANGD,
    "C:/Program Files/LLVM/bin/clangd.exe",
    vim.fn.exepath("clangd")
  ))

  if not clangd then
    t.it("SKIP when clangd is unavailable", function()
      io.write("SKIP cpp_semantic_index: clangd unavailable\n")
      t.assert_true(true)
    end)
    return
  end

  local py_cmd = python_cmd()
  t.assert_true(py_cmd ~= nil, "python or py launcher is required for real clangd E2E")

  t.it("uses exact-command transport with config disabled so synthetic all.cpp controls body reachability", function()
    local full_calls = new_workspace("cpp-bg-full-calls", "full")
    local full_delta = new_workspace("cpp-bg-full-delta", "full")
    local partial_calls = new_workspace("cpp-bg-partial-calls", "partial")
    local return_full = new_workspace("cpp-bg-return-full", "full")
    local ok, err = xpcall(function()
      local cases = {
        {
          name = "full_calls",
          workspace = full_calls,
          open_path = full_calls .. "/calls.cpp",
          header_path = full_calls .. "/api.hpp",
          call_marker = "QUERY:call_helper",
          call_token = "helper_ping",
          decl_marker = "DECL:helper_ping",
          decl_token = "helper_ping",
          cmd = {
            clangd,
            "--background-index",
            "--enable-config=false",
            "--compile-commands-dir=" .. full_calls,
            "-j=1",
            "--log=verbose",
            "--pch-storage=memory",
          },
          settle_s = 4.0,
          initialization_options = full_init_options(full_calls, full_calls .. "/calls.cpp"),
          settings = { compilationDatabaseChanges = full_init_options(full_calls, full_calls .. "/calls.cpp").compilationDatabaseChanges },
        },
        {
          name = "full_delta",
          workspace = full_delta,
          open_path = full_delta .. "/delta.cpp",
          header_path = full_delta .. "/api.hpp",
          call_marker = "QUERY:delta_helper",
          call_token = "helper_ping",
          decl_marker = "DECL:helper_ping",
          decl_token = "helper_ping",
          cmd = {
            clangd,
            "--background-index",
            "--enable-config=false",
            "--compile-commands-dir=" .. full_delta,
            "-j=1",
            "--log=verbose",
            "--pch-storage=memory",
          },
          settle_s = 4.0,
          initialization_options = full_init_options(full_delta, full_delta .. "/delta.cpp"),
          settings = { compilationDatabaseChanges = full_init_options(full_delta, full_delta .. "/delta.cpp").compilationDatabaseChanges },
        },
        {
          name = "partial_calls",
          workspace = partial_calls,
          open_path = partial_calls .. "/calls.cpp",
          header_path = partial_calls .. "/api.hpp",
          call_marker = "QUERY:call_helper",
          call_token = "helper_ping",
          decl_marker = "DECL:helper_ping",
          decl_token = "helper_ping",
          cmd = {
            clangd,
            "--background-index",
            "--enable-config=false",
            "--compile-commands-dir=" .. partial_calls,
            "-j=1",
            "--log=verbose",
            "--pch-storage=memory",
          },
          settle_s = 2.0,
          initialization_options = partial_init_options(partial_calls, partial_calls .. "/calls.cpp"),
          settings = { compilationDatabaseChanges = partial_init_options(partial_calls, partial_calls .. "/calls.cpp").compilationDatabaseChanges },
        },
        {
          name = "return_full_calls",
          workspace = return_full,
          open_path = return_full .. "/calls.cpp",
          header_path = return_full .. "/api.hpp",
          call_marker = "QUERY:call_helper",
          call_token = "helper_ping",
          decl_marker = "DECL:helper_ping",
          decl_token = "helper_ping",
          cmd = {
            clangd,
            "--background-index",
            "--enable-config=false",
            "--compile-commands-dir=" .. return_full,
            "-j=1",
            "--log=verbose",
            "--pch-storage=memory",
          },
          settle_s = 4.0,
          initialization_options = full_init_options(return_full, return_full .. "/calls.cpp"),
          settings = { compilationDatabaseChanges = full_init_options(return_full, return_full .. "/calls.cpp").compilationDatabaseChanges },
        },
      }

      local results = run_cases(py_cmd, cases)
      local by_name = {}
      for _, item in ipairs(results) do
        by_name[item.name] = item
      end

      for _, name in ipairs({ "full_calls", "full_delta", "return_full_calls" }) do
        local item = by_name[name]
        t.assert_eq(basename(item.call_definition.path), "impl.cpp",
          name .. " call definition should resolve to the out-of-line body")
        t.assert_eq(basename(item.decl_definition.path), "impl.cpp",
          name .. " declaration should resolve to the out-of-line body")
        t.assert_true(item.indexed_targets["all.cpp"],
          name .. " stderr should show the synthetic all.cpp background index activity")
        t.assert_true(item.indexed_log_lines >= 1,
          name .. " should emit background indexing log lines")
      end

      local partial = by_name.partial_calls
      t.assert_eq(basename(partial.call_definition.path), "api.hpp",
        "partial-only workspace should lose the full-only body and stop at the declaration")
      t.assert_eq(basename(partial.decl_definition.path), "api.hpp",
        "partial-only declaration should stop at the header declaration")
      t.assert_false(partial.indexed_targets["all.cpp"],
        "partial-only workspace must not index synthetic all.cpp")
    end, debug.traceback)

    for _, dir in ipairs({ full_calls, full_delta, partial_calls, return_full }) do
      pcall(vim.fn.delete, dir, "rf")
    end
    if not ok then error(err) end
  end)
end)
