local t = require("tests.harness")
t.bootstrap()

local stores = require("utils.ue_goto.semantic_sidecar_tu")

t.describe("semantic TU cache resource bounds", function()
  local function store()
    local disposed = {}
    local instance = stores.new({ ok = false, lib = {
      clang_disposeTranslationUnit = function(tu) disposed[#disposed + 1] = tu end,
    } }, { max_tus = 4, idle_evict_ms = 300000, max_rss_bytes = 100 })
    for i = 1, 4 do
      instance.tus[tostring(i)] = { tu = i, last_used_ms = i }
    end
    return instance, disposed
  end

  t.it("retains four warm donors when RSS fits and evicts oldest on pressure", function()
    local instance, disposed = store()
    instance._rss_bytes = function(self) return self:_tu_count() * 20 end
    instance:_prune_lru()
    t.assert_eq(instance:_tu_count(), 4)
    instance.max_rss_bytes = 45
    instance:_prune_lru()
    t.assert_eq(instance:_tu_count(), 2)
    t.assert_true(vim.deep_equal(disposed, { 1, 2 }))
    t.assert_true(instance.tus["4"] ~= nil)
  end)

  t.it("keeps the currently used TU even when one parse exceeds the RSS budget", function()
    local instance, disposed = store()
    instance._rss_bytes = function() return 200 end
    instance:_prune_lru()
    t.assert_eq(instance:_tu_count(), 1)
    t.assert_true(vim.deep_equal(disposed, { 1, 2, 3 }))
    t.assert_true(instance.tus["4"] ~= nil)
  end)

  t.it("releases extra donors when the host free-memory reserve cannot be met", function()
    local instance = store()
    instance._rss_bytes = function() return 0 end
    instance.free_memory_reserve = math.huge
    instance:_prune_lru()
    t.assert_eq(instance:_tu_count(), 1)
    t.assert_true(instance.tus["4"] ~= nil)
  end)

  t.it("never disposes the acquired TU when LRU timestamps tie", function()
    local instance = store()
    for _, entry in pairs(instance.tus) do entry.last_used_ms = 1 end
    instance._rss_bytes = function() return 200 end
    instance:_prune_lru("1")
    t.assert_eq(instance:_tu_count(), 1)
    t.assert_true(instance.tus["1"] ~= nil)
  end)
end)
