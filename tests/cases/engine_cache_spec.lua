-- tests/cases/engine_cache_spec.lua
-- Non-config artifacts follow the engine (<engine>/.cache/nvim-ue); stdpath is
-- only the no-engine fallback.

local t = require("tests.harness")
t.bootstrap()

local cache = require("ue.engine_cache")

local function fake_engine()
  local root = vim.fn.tempname():gsub("\\", "/")
  for _, dir in ipairs({ "Binaries", "Build", "Config", "Plugins", "Shaders", "Source" }) do
    vim.fn.mkdir(root .. "/Engine/" .. dir, "p")
  end
  return root
end

t.describe("engine_cache placement", function()
  t.it("places sub dirs under <engine>/.cache/nvim-ue", function()
    local engine = fake_engine()
    t.assert_eq(cache.dir("logs", { engine_root = engine }), engine .. "/.cache/nvim-ue/logs")
    t.assert_eq(cache.dir(nil, { engine_root = engine }), engine .. "/.cache/nvim-ue")
  end)

  t.it("derives the engine from a path inside it", function()
    local engine = fake_engine()
    local file = engine .. "/Engine/Source/Foo.cpp"
    t.assert_eq(cache.dir("logs", { path = file, current = false }), engine .. "/.cache/nvim-ue/logs")
  end)

  t.it("falls back only when no engine is known or the recorded one is gone", function()
    local outside = vim.fn.tempname()
    t.assert_eq(cache.dir_or("logs", "FALLBACK", { path = outside, current = false }), "FALLBACK")
    t.assert_eq(cache.dir_or("logs", function() return "THUNK" end,
      { engine_root = outside .. "/missing", current = false }), "THUNK")
  end)

  t.it("file() creates the parent directory", function()
    local engine = fake_engine()
    local path = cache.file("logs", "x.log", "UNUSED", { engine_root = engine })
    t.assert_eq(path, engine .. "/.cache/nvim-ue/logs/x.log")
    t.assert_eq(vim.fn.isdirectory(engine .. "/.cache/nvim-ue/logs"), 1)
  end)
end)

t.describe("engine_cache stores", function()
  t.it("search history follows the project engine and imports the stdpath bucket", function()
    local store = require("utils.search_history_store")
    local engine = fake_engine()
    local project = { root = engine .. "/Proj", identity = engine .. "/Proj/P" .. vim.uv.hrtime() .. ".uproject", engine = engine }
    local key = store.key(project)
    t.assert_eq(vim.fs.dirname(store.path(key)), engine .. "/.cache/nvim-ue/search-history")
    local legacy = vim.fs.joinpath(vim.fn.stdpath("state"), "ue_search_history", key .. ".json")
    vim.fn.mkdir(vim.fs.dirname(legacy), "p")
    vim.fn.writefile({ '[{"query":"Old","kind":"grep","count":3,"last":1}]' }, legacy)
    local entries = store.load(key)
    os.remove(legacy)
    t.assert_eq(#entries, 1)
    t.assert_eq(entries[1].query, "Old")
  end)

  t.it("work contexts follow the project engine; no engine keeps stdpath", function()
    local store = require("utils.work_context_store")
    local engine = fake_engine()
    local with = { root = engine .. "/Proj", identity = engine .. "/Proj/P.uproject", engine = engine }
    local without = { root = engine .. "/Proj", identity = engine .. "/Proj/P.uproject", engine = "" }
    t.assert_contains((store.path(with):gsub("\\", "/")), "/.cache/nvim-ue/work-contexts/")
    t.assert_contains((store.path(without):gsub("\\", "/")), "/ue_work_contexts/")
  end)

  t.it("cursor shim cache follows the controlled CDB engine cache", function()
    local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
    t.assert_eq(libclang.engine_cache_of("D:\\E\\.cache\\nvim-ue\\projects\\k\\cdb\\compile_commands.json"),
      "D:/E/.cache/nvim-ue")
    t.assert_nil(libclang.engine_cache_of("C:/tmp/compile_commands.json"))
  end)
end)
