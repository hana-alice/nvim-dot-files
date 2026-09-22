local t = require("tests.harness")
t.bootstrap()

local function write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function python_command(script, ...)
  for _, executable in ipairs({ "python", "python3", "py" }) do
    local python = vim.fn.exepath(executable)
    if python ~= "" then
      local command = { python }
      if executable == "py" then command[#command + 1] = "-3" end
      vim.list_extend(command, { "-I", script, ... })
      return command
    end
  end
  error("python, python3, or py launcher is required")
end

local function fixture(producer)
  local root = vim.fn.tempname():gsub("\\", "/") .. "_index_outputs"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  local unity_root = root .. "/Build/Intermediate/Build/Android/Target/Development"
  local ctx = {
    root = root,
    unity_root = unity_root,
    unity = unity_root .. "/Sample/Module.Sample.1_of_1.cpp",
    input = root .. "/input.json",
    output = root .. "/out/compile_commands.json",
    active = root .. "/out/active.json",
    marker = root .. "/out/full.idx",
    producer = producer,
    entries = {},
  }
  write_file(unity_root .. "/Sample/Definitions.Sample.h", "// fixture\n")
  for _, name in ipairs({ "A", "B", "C" }) do
    local source = root .. "/Engine/Source/Runtime/Sample/Private/" .. name .. ".cpp"
    write_file(source, "// fixture\n")
    ctx.entries[#ctx.entries + 1] = {
      directory = root .. "/Engine/Source",
      file = source,
      arguments = {
        "clang++", "--target=aarch64-linux-android", "-std=c++20", "-DCHOICE=1",
        "-include", unity_root .. "/Sample/Definitions.Sample.h", "-c", source,
      },
    }
  end
  return ctx
end

local function write_inputs(ctx, members, choice)
  local lines = {}
  for _, name in ipairs(members) do
    lines[#lines + 1] = '#include "Runtime/Sample/Private/' .. name .. '.cpp"'
  end
  write_file(ctx.unity, table.concat(lines, "\n") .. "\n")
  write_file(ctx.unity .. ".o.rsp", table.concat({
    "--target=aarch64-linux-android", "-std=c++20", "-DCHOICE=" .. choice,
    '-include "' .. ctx.unity_root .. '/Sample/Definitions.Sample.h"',
    '-c "' .. ctx.unity .. '"', '-o "' .. ctx.unity .. '.o"',
  }, " "))
  for _, entry in ipairs(ctx.entries) do entry.arguments[4] = "-DCHOICE=" .. choice end
  write_file(ctx.input, vim.json.encode(ctx.entries))
end

local function generate(ctx)
  local tools = vim.fn.stdpath("config") .. "/tools/"
  local command
  if ctx.producer == "full" then
    command = python_command(tools .. "build_full_cdb.py", ctx.input, ctx.active,
      "--background-output", ctx.output, "--idx-output", ctx.marker)
  elseif ctx.producer == "hot" then
    command = python_command(tools .. "build_clangd_index.py", ctx.input,
      "--background-output", ctx.output, "--output", ctx.marker)
  else
    command = python_command(tools .. "build_hot_super_unity_cdb.py", ctx.input, ctx.output)
  end
  if ctx.super_dir then vim.list_extend(command, { "--super-dir", ctx.super_dir }) end
  local result = vim.system(command, { text = true }):wait()
  t.assert_eq(result.code, 0, result.stderr or result.stdout)
  return vim.json.decode(read_file(ctx.output))
end

local function retained_snapshot(path)
  -- Pin an older mtime so rewrite detection never depends on clock resolution or sleeps.
  assert(vim.uv.fs_utime(path, 1700000000, 1700000000))
  return { content = read_file(path), mtime = assert(vim.uv.fs_stat(path)).mtime }
end

local function assert_retained(path, snapshot)
  t.assert_eq(read_file(path), snapshot.content, "existing output bytes must remain unchanged")
  t.assert_true(vim.deep_equal(assert(vim.uv.fs_stat(path)).mtime, snapshot.mtime),
    "unchanged output mtime must survive generation")
end

for _, producer in ipairs({ "unity", "full", "hot" }) do
  t.describe("controlled index output stability (" .. producer .. ")", function()
    t.it("reuses identical wrappers and CDB bytes without changing mtimes", function()
      local ctx = fixture(producer)
      write_inputs(ctx, { "A", "B" }, 1)
      local first = generate(ctx)
      t.assert_eq(#first, 2, "fixture must produce one unity wrapper and one exact fallback")
      t.assert_eq(#first[1].nvim_ue_members, 2)
      local wrapper, cdb = retained_snapshot(first[1].file), retained_snapshot(ctx.output)
      local artifacts = {}
      if producer == "full" then
        for _, path in ipairs({ ctx.active, ctx.active .. ".indexer", ctx.marker }) do
          artifacts[path] = retained_snapshot(path)
        end
      elseif producer == "hot" then
        artifacts[ctx.marker] = retained_snapshot(ctx.marker)
      end
      local second = generate(ctx)
      t.assert_true(vim.deep_equal(second, first), "identical input must retain the same controlled commands")
      assert_retained(first[1].file, wrapper)
      assert_retained(ctx.output, cdb)
      for path, snapshot in pairs(artifacts) do assert_retained(path, snapshot) end
      t.assert_eq(#vim.fn.glob(ctx.root .. "/out/*.bak.*", false, true), 0,
        "unchanged generation must not create backups")
      vim.fn.delete(ctx.root, "rf")
    end)

    t.it("publishes changed membership while retaining the previous wrapper", function()
      local ctx = fixture(producer)
      write_inputs(ctx, { "A", "B" }, 1)
      local first = generate(ctx)
      local old = retained_snapshot(first[1].file)
      write_inputs(ctx, { "A", "B", "C" }, 1)
      local second = generate(ctx)
      t.assert_eq(#second, 1)
      t.assert_eq(#second[1].nvim_ue_members, 3)
      t.assert_true(second[1].file ~= first[1].file, "new membership must produce a different wrapper path")
      t.assert_contains(read_file(second[1].file), ctx.entries[3].file)
      assert_retained(first[1].file, old)
      vim.fn.delete(ctx.root, "rf")
    end)

    t.it("publishes changed argv while retaining the previous wrapper", function()
      local ctx = fixture(producer)
      write_inputs(ctx, { "A", "B" }, 1)
      local first = generate(ctx)
      local old = retained_snapshot(first[1].file)
      write_inputs(ctx, { "A", "B" }, 2)
      local second = generate(ctx)
      t.assert_eq(#second, 2)
      t.assert_true(second[1].file ~= first[1].file, "new compiler context must produce a different wrapper path")
      t.assert_contains(second[1].arguments, "-DCHOICE=2")
      assert_retained(first[1].file, old)
      vim.fn.delete(ctx.root, "rf")
    end)
  end)
end

t.describe("controlled index shared wrapper directory", function()
  t.it("full and hot phases reuse the same wrapper paths and bytes", function()
    local ctx = fixture("full")
    ctx.super_dir = ctx.root .. "/shared/super_unity_cpps"
    write_inputs(ctx, { "A", "B" }, 1)
    local full = generate(ctx)
    local snapshot = retained_snapshot(full[1].file)
    t.assert_contains(full[1].file:gsub("\\", "/"), ctx.super_dir)
    ctx.producer = "hot"
    ctx.output = ctx.root .. "/hot/compile_commands.json"
    ctx.marker = ctx.root .. "/hot/index.idx"
    local hot = generate(ctx)
    t.assert_eq(hot[1].file, full[1].file, "the same group must retain its source path across phases")
    t.assert_true(vim.deep_equal(hot, full), "the same source set must produce identical controlled commands")
    assert_retained(full[1].file, snapshot)
    vim.fn.delete(ctx.root, "rf")
  end)
end)

t.describe("controlled CDB and marker transaction", function()
  for _, producer in ipairs({ "full", "hot" }) do
    for _, failure in ipairs({ "marker-write", "marker-rename", "new-marker-rename" }) do
      t.it(producer .. " preserves the previous pair on " .. failure .. " failure", function()
        local ctx = fixture(producer)
        write_inputs(ctx, { "A", "B" }, 1)
        generate(ctx)
        local old_cdb, old_marker = retained_snapshot(ctx.output), retained_snapshot(ctx.marker)
        if failure == "new-marker-rename" then
          assert(os.remove(ctx.output))
          assert(os.remove(ctx.marker))
        end
        -- Change both CDB bytes and marker entry_count, so the failure must
        -- occur on the second output of the real producer's publication.
        write_inputs(ctx, { "A", "B", "C" }, 1)
        local driver = ctx.root .. "/fail_publication.py"
        write_file(driver, [=[
import builtins, importlib.util, os, sys
script, source, active, output, marker, failure = sys.argv[1:]
spec = importlib.util.spec_from_file_location('producer', script)
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)
sys.argv = [script, source]
if os.path.basename(script) == 'build_full_cdb.py':
    sys.argv += [active, '--background-output', output, '--idx-output', marker]
else:
    sys.argv += ['--background-output', output, '--output', marker]
original_open, original_replace = builtins.open, os.replace
normalize = lambda value: os.path.normcase(os.path.abspath(value))
marker_key = normalize(marker)
fired = False
def failing_open(path, mode='r', *args, **kwargs):
    global fired
    key = normalize(path)
    if failure == 'marker-write' and not fired and 'w' in mode and key.startswith(marker_key + '.') and '.pending.' in key:
        fired = True
        raise OSError('injected marker temporary write failure')
    return original_open(path, mode, *args, **kwargs)
def failing_replace(source, destination):
    global fired
    if failure.endswith('marker-rename') and not fired and normalize(destination) == marker_key and str(source).endswith('.pending'):
        fired = True
        raise OSError('injected marker rename failure')
    return original_replace(source, destination)
builtins.open, os.replace = failing_open, failing_replace
try:
    producer.main()
except OSError:
    if not fired:
        raise
else:
    raise AssertionError('publication must propagate the injected failure')
finally:
    builtins.open, os.replace = original_open, original_replace
assert fired, 'test must reach the actual second artifact publication'
print('injected publication failure propagated')
]=])
        local script = vim.fn.stdpath("config") .. "/tools/"
          .. (producer == "full" and "build_full_cdb.py" or "build_clangd_index.py")
        local result = vim.system(python_command(driver, script, ctx.input, ctx.active,
          ctx.output, ctx.marker, failure), { text = true }):wait()
        t.assert_eq(result.code, 0, result.stderr or result.stdout)
        if failure == "new-marker-rename" then
          t.assert_eq(vim.fn.filereadable(ctx.output), 0, "failed new publication must remove its CDB")
          t.assert_eq(vim.fn.filereadable(ctx.marker), 0, "failed new publication must not leave a marker")
        else
          assert_retained(ctx.output, old_cdb)
          assert_retained(ctx.marker, old_marker)
        end
        t.assert_eq(#vim.fn.glob(ctx.root .. "/out/*.pending*", false, true), 0)
        t.assert_eq(#vim.fn.glob(ctx.root .. "/out/*.rollback", false, true), 0)
        vim.fn.delete(ctx.root, "rf")
      end)
    end
  end
end)
