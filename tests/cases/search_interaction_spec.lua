local t = require("tests.harness")
t.bootstrap()

t.describe("search_interaction: copied file input", function()
  t.it("normalizes copied paths and converts external byte columns once", function()
    local query = require("utils.file_query")
    local parsed = query.parse('"C:\\Fixture Space\\Source\\Alpha.cpp":4:8')
    t.assert_eq(parsed.pattern, "C:/Fixture Space/Source/Alpha.cpp")
    t.assert_eq(parsed.pos[1], 4)
    t.assert_eq(parsed.pos[2], 7)
    t.assert_eq(query.parse("Source\\Game\\Alpha.cpp").pattern, "Source/Game/Alpha.cpp")
    t.assert_eq(query.parse("Space Name.cpp:2:4").pos[2], 3)
    t.assert_eq(query.parse("Alpha.cpp:4").pos[2], 0)
  end)

  t.it("leaves the input text intact and limits normalization to file sources", function()
    local query = require("utils.file_query")
    local filter = { pattern = '"Source\\Game\\Alpha.cpp":4:8' }
    local picker = { matcher = {} }
    query.filter(picker, filter)
    t.assert_eq(filter.pattern, "Source/Game/Alpha.cpp")
    local item = { file = "Source\\Game\\Alpha.cpp", text = "Source\\Game\\Alpha.cpp" }
    local normalized = query.transform(item)
    t.assert_eq(normalized.file, "Source/Game/Alpha.cpp")
    t.assert_eq(item.file, "Source\\Game\\Alpha.cpp", "caller item is unchanged")
    query.on_match(picker.matcher, normalized)
    t.assert_eq(normalized.pos[2], 7)
  end)

  t.it("position text round trips a UTF-8 byte column", function()
    local query = require("utils.file_query")
    local item = { file = "C:/Fixture Space/Alpha.cpp", pos = { 2, #"中文" } }
    local text = query.position_text(item.file, item.pos)
    local parsed = query.parse(text)
    t.assert_eq(parsed.pos[2], #"中文")
    t.assert_eq(parsed.pattern, item.file)
  end)

  t.it("converts compiler UTF-16 positions from actual target text and refuses an unknown column", function()
    local query = require("utils.file_query")
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "中文😀Alpha" })
    local item = { buf = buffer, loc = { range = { start = { line = 0, character = 4 } }, encoding = "utf-16" } }
    local pos, precision = query.byte_position({}, item)
    t.assert_eq(pos[2], #"中文😀")
    t.assert_eq(precision, "exact")
    item.buf, item.file = nil, "C:/Fixture/Unavailable.cpp"
    pos, precision = query.byte_position({}, item)
    t.assert_eq(pos[1], 1)
    t.assert_eq(precision, "line")
    t.assert_eq(query.position_text("C:/Fixture/Unavailable.cpp", pos, true), "C:/Fixture/Unavailable.cpp:1")
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
end)

t.describe("search_interaction: native Snacks task replay", function()
  local python = vim.fn.exepath("python")
  if python == "" then
    python = vim.fn.exepath("python3")
  end
  local plugins = vim.fn.stdpath("data"):gsub("\\", "/") .. "/lazy"
  if
    python == ""
    or not vim.uv.fs_stat(plugins .. "/snacks.nvim/lua/snacks/init.lua")
    or not vim.uv.fs_stat(plugins .. "/trouble.nvim/lua/trouble/init.lua")
  then
    t.skip(
      "replays real file input, resume, recipes and passive pin",
      "installed Snacks/Trouble and Python are required",
      { native = true }
    )
    return
  end
  t.it("replays real file input, resume, recipes and passive pin", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local out = vim.fn.tempname():gsub("\\", "/")
    local result = vim
      .system(
        { python, root .. "/tests/fixtures/search_interaction_native.py", root, out, plugins, vim.v.progpath },
        { text = true }
      )
      :wait(80000)
    t.assert_eq(result.code, 0, result.stderr)
    local evidence = vim.json.decode(table.concat(vim.fn.readfile(out .. "/evidence.json"), "\n"))
    t.assert_eq(evidence.copied_paths.matched, 6)
    t.assert_eq(evidence.byte_location_roundtrip.inputs, 3)
    t.assert_eq(evidence.newest_native_search_resume.source, "grep")
    t.assert_eq(evidence.recipe_rg_roundtrip.before, evidence.recipe_rg_roundtrip.after)
    t.assert_true(evidence.passive_pin.sidebar)
    t.assert_true(evidence.passive_pin.source)
    t.assert_true(evidence.grid.flushes > 0)
  end)
end)

t.describe("search_interaction: recent search route", function()
  t.it("chooses the newest actual native source instead of preferring csearch", function()
    local history = require("utils.history_hub")
    local old = package.loaded["snacks.picker.resume"]
    local seen
    package.loaded["snacks.picker.resume"] = {
      state = { ue_grep_csearch = { added = 100 }, grep = { added = 200 } },
      resume = function(opts)
        seen = opts
        return "resumed"
      end,
    }
    local ok, err = pcall(function()
      t.assert_eq(history.resume_search(), "resumed")
      t.assert_eq(seen.include[2], "grep")
      t.assert_nil(seen.source)
    end)
    package.loaded["snacks.picker.resume"] = old
    if not ok then
      error(err)
    end
  end)
end)

t.describe("search_interaction: durable search intent", function()
  local function recipe(query)
    return {
      version = 1,
      source = "ue_grep_csearch",
      query = query or "Alpha",
      project = {
        root = "C:/Fixture/Project",
        identity = "C:/Fixture/Project/Fixture.uproject",
        engine = "C:/Fixture/Engine",
      },
      scope = { kind = "workspace", roots = { "C:/Fixture/Engine", "C:/Fixture/Project" }, code_only = true },
      mode = { regex = false, case = "sensitive", word = true },
      filters = {
        include = { "*.cpp" },
        exclude = { "*/Generated/*" },
        pattern = "Alpha.cpp",
        hidden = false,
        ignored = false,
        follow = false,
      },
    }
  end

  t.it("keeps strict-case and matching modes as distinct identities", function()
    local recipes = require("utils.search_recipe")
    local history = require("utils.history_hub")
    local upper, lower = recipe("Alpha"), recipe("alpha")
    local entries = history.record_recipe_into({}, upper, 100)
    entries = history.record_recipe_into(entries, lower, 101)
    t.assert_eq(#entries, 2)
    lower.mode.case, upper.mode.case = "ignore", "ignore"
    t.assert_eq(recipes.identity(upper), recipes.identity(lower))
    lower.mode.regex = true
    t.assert_true(recipes.identity(upper) ~= recipes.identity(lower))
  end)

  t.it("rejects unsupported versions, unknown fields and executable sources", function()
    local recipes = require("utils.search_recipe")
    for _, change in ipairs({ { "version", 99 }, { "source", "vim.cmd" }, { "token", "sensitive" } }) do
      local value = recipe()
      value[change[1]] = change[2]
      local validated, reason = recipes.validate(value)
      t.assert_nil(validated)
      t.assert_type(reason, "string")
      local result, run_err = recipes.run(value)
      t.assert_nil(result)
      t.assert_type(run_err, "string")
    end
    local oversized = recipe(string.rep("x", recipes.limits.query + 1))
    t.assert_nil(recipes.validate(oversized))
  end)

  t.it("refuses raw executable flags in a serialized rg query without launching anything", function()
    local recipes = require("utils.search_recipe")
    local value = recipe("Alpha -- --pre forbidden-program")
    value.source = "grep"
    local validated, err = recipes.validate(value)
    t.assert_nil(validated)
    t.assert_contains(err, "inline")
    value.source = "ue_grep_csearch"
    t.assert_true(recipes.validate(value) ~= nil, "indexed literal -- remains content")
    local from_picker, reason = recipes.from_picker({
      opts = { source = "grep", regex = true, ue_search_recipe = recipe() },
      input = { filter = { search = "Alpha -- --pre forbidden-program", pattern = "" } },
    })
    t.assert_nil(from_picker)
    t.assert_contains(reason, "argument")
    local malformed = recipe()
    malformed.source, malformed.filters.extra_globs = "grep", { "--pre=forbidden-program" }
    t.assert_nil(recipes.validate(malformed))
    malformed.filters.extra_globs, malformed.filters.extensions = {}, { "--pre" }
    t.assert_nil(recipes.validate(malformed))
  end)

  t.it("captures rg flags into allowlisted modes and refuses process-changing arguments", function()
    local recipes = require("utils.search_recipe")
    local ctx = {
      project_root = "C:/Fixture/Project",
      uproject = "C:/Fixture/Project/Fixture.uproject",
      engine_root = "C:/Fixture/Engine",
    }
    local value = assert(recipes.capture("grep", { dirs = { ctx.project_root }, regex = true }, {
      search = "Alpha -- -w -s -g *.h",
      pattern = "Alpha.h",
    }, ctx))
    t.assert_eq(value.query, "Alpha")
    t.assert_eq(value.mode.case, "sensitive")
    t.assert_true(value.mode.word)
    t.assert_eq(value.filters.include[1], "*.h")
    local quoted = assert(recipes.capture("grep", {}, { search = 'Alpha -- -g "Space Name.cpp" -w' }, ctx))
    t.assert_eq(quoted.filters.include[1], '"Space Name.cpp"', "native argv retains quotes")
    t.assert_true(quoted.mode.word)
    local unsafe, reason = recipes.capture("grep", {}, { search = "Alpha -- --pre program.exe" }, ctx)
    t.assert_nil(unsafe)
    t.assert_contains(reason, "argument")
  end)

  t.it("preserves ordered rg overrides and compacts the existing code union within mask budgets", function()
    local recipes = require("utils.search_recipe")
    local ctx = { project_root = "C:/Fixture/Project", engine_root = "C:/Fixture/Engine" }
    local value = assert(recipes.capture("grep", { glob = require("ue").GLOBS_CODE }, {
      search = "Alpha -- -g !*.h -g *.h",
    }, ctx))
    t.assert_eq(#value.filters.include, 1)
    t.assert_contains(value.filters.include[1], "*.{")
    t.assert_eq(value.filters.extra_globs[1], "!*.h")
    t.assert_eq(value.filters.extra_globs[2], "*.h")
  end)

  t.it("preserves legacy query entries with a visible intent gap", function()
    local history = require("utils.history_hub")
    local old = { query = "Alpha", kind = "grep", count = 2, last = 50 }
    local entries = history.record_recipe_into({ old }, recipe(), 100)
    t.assert_eq(#entries, 2)
    t.assert_contains(history.format_entry(old, 100), "legacy")
  end)

  t.it("keeps regex escape classes distinct under ignore-case", function()
    local recipes = require("utils.search_recipe")
    local upper, lower = recipe("\\S"), recipe("\\s")
    upper.mode.case, lower.mode.case = "ignore", "ignore"
    upper.mode.regex, lower.mode.regex = true, true
    t.assert_true(recipes.identity(upper) ~= recipes.identity(lower))
  end)

  t.it("isolates canonical project identities including two uprojects in one directory", function()
    local store = require("utils.search_history_store")
    local first = { root = "C:/Fixture/Project", identity = "C:/Fixture/Project/First.uproject" }
    local alias = { root = "C:\\Fixture\\Project", identity = "C:\\Fixture\\Project\\First.uproject" }
    local second = { root = first.root, identity = "C:/Fixture/Project/Second.uproject" }
    t.assert_eq(store.key(first), store.key(alias))
    t.assert_true(store.key(first) ~= store.key(second))
  end)

  t.it("obeys the case-sensitive path-key capability without claiming a POSIX host run", function()
    local platform = require("utils.platform")
    local previous = platform.driver
    local key = require("utils.platform.linux").path_key
    platform.driver = function()
      return { path_key = key }
    end
    local ok, err = pcall(function()
      local store = require("utils.search_history_store")
      t.assert_true(store.key({ root = "C:/Fixture/Foo" }) ~= store.key({ root = "C:/Fixture/foo" }))
      local value = recipe()
      value.project.root, value.project.identity = "C:/Fixture/Foo", "C:/Fixture/Foo/Fixture.uproject"
      value.project.engine = ""
      value.scope.roots = { "C:/Fixture/foo" }
      t.assert_nil(require("utils.search_recipe").validate(value))
    end)
    platform.driver = previous
    if not ok then
      error(err)
    end
  end)

  t.it("merges two real Neovim writers without losing uses", function()
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local script = dir .. "/writer.lua"
    vim.fn.writefile(
      vim.split(
        [[
local root, out, name = unpack(arg)
vim.opt.rtp:prepend(root)
vim.env.XDG_STATE_HOME = out .. '/state'
vim.env.NVIM_UE_PROBE_PATH = out .. '/probe-' .. vim.fn.getpid() .. '.json'
vim.env.NVIM_UE_LOG_DIR = out .. '/logs'
local history = require('utils.history_hub')
local store = require('utils.search_history_store')
vim.fn.writefile({store.path('native-two-writers')}, out .. '/history-path-' .. name)
vim.fn.writefile({tostring(vim.fn.getpid())}, out .. '/ready-' .. name)
assert(vim.wait(4000, function() return vim.uv.fs_stat(out .. '/release') ~= nil end, 10))
for _ = 1, 120 do history.record('Shared', 'grep', 'native-two-writers') end
history.record(name, 'grep', 'native-two-writers')
assert(vim.wait(4000, function() return store.pending_count() == 0 end, 10), 'pending history never saved')
print(vim.json.encode({pid=vim.fn.getpid(),name=name}))
]],
        "\n",
        { plain = true }
      ),
      script
    )
    local config = vim.fn.stdpath("config"):gsub("\\", "/")
    local first = vim.system({ vim.v.progpath, "--headless", "-l", script, config, dir, "WriterA" }, { text = true })
    local second = vim.system({ vim.v.progpath, "--headless", "-l", script, config, dir, "WriterB" }, { text = true })
    t.assert_true(
      vim.wait(4000, function()
        return vim.uv.fs_stat(dir .. "/ready-WriterA") and vim.uv.fs_stat(dir .. "/ready-WriterB")
      end, 10),
      "both real PIDs must reach the barrier"
    )
    vim.fn.writefile({ "go" }, dir .. "/release")
    local first_result, second_result = first:wait(6000), second:wait(6000)
    t.assert_eq(first_result.code, 0, first_result.stderr)
    t.assert_eq(second_result.code, 0, second_result.stderr)
    local first_pid = vim.fn.readfile(dir .. "/ready-WriterA")[1]
    local second_pid = vim.fn.readfile(dir .. "/ready-WriterB")[1]
    t.assert_true(first_pid ~= second_pid, "two independent processes")
    local path = vim.fn.readfile(dir .. "/history-path-WriterA")[1]
    t.assert_eq(path, vim.fn.readfile(dir .. "/history-path-WriterB")[1])
    local entries = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    local counts = {}
    for _, entry in ipairs(entries) do
      counts[entry.query] = entry.count
    end
    t.assert_eq(counts.Shared, 240)
    t.assert_eq(counts.WriterA, 1)
    t.assert_eq(counts.WriterB, 1)
  end)
end)
