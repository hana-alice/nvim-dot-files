-- tests/cases/clangd_memory_reclaim_spec.lua
-- Restart clangd once after a real background-index run so Windows returns the heap.

local t = require("tests.harness")
t.bootstrap()

local reclaim = require("ue.clangd_memory_reclaim")

local function harness(over)
  reclaim._reset_for_test()
  local h = { deferred = {}, restarts = 0, probes = {}, now = 0, mode = "n", modified = {}, job = nil }
  h.client = { id = 7, name = "clangd", config = {}, progress = { pending = {} }, attached_buffers = { [1] = true } }
  local deps = {
    defer_fn = function(fn, ms) h.deferred[#h.deferred + 1] = { fn = fn, ms = ms } end,
    get_client_by_id = function(id) return id == 7 and h.client or nil end,
    mode = function() return { mode = h.mode } end,
    modified = function(buf) return h.modified[buf] == true end,
    buffer_valid = function() return true end,
    index_job = function() return h.job end,
    now = function() return h.now end,
    restart = function() h.restarts = h.restarts + 1; return true end,
    probe = function(_, key) h.probes[#h.probes + 1] = key end,
  }
  for k, v in pairs(over or {}) do deps[k] = v end
  reclaim.setup(deps)
  function h.run(tasks)
    reclaim.on_progress(7, "clangd", { token = "backgroundIndexProgress", value = { kind = "begin" } })
    reclaim.on_progress(7, "clangd", { token = "backgroundIndexProgress", value = { kind = "report", message = "3/" .. tasks } })
    reclaim.on_progress(7, "clangd", { token = "backgroundIndexProgress", value = { kind = "end" } })
  end
  function h.flush()
    local queue = h.deferred
    h.deferred = {}
    for _, item in ipairs(queue) do item.fn() end
  end
  return h
end

t.describe("clangd memory reclaim", function()
  t.it("parses clangd's done/total queue message", function()
    t.assert_eq(reclaim.queue_total("15/17"), 17)
    t.assert_eq(reclaim.queue_total(" 0 / 1"), 1)
    t.assert_eq(reclaim.queue_total(nil), 0)
  end)

  t.it("restarts once after a large index run, only after the quiet delay", function()
    local h = harness()
    h.run(400)
    t.assert_eq(h.restarts, 0)
    t.assert_eq(h.deferred[1].ms, reclaim.defaults.quiet_ms)
    h.flush()
    t.assert_eq(h.restarts, 1)
    h.run(400)
    h.flush()
    t.assert_eq(h.restarts, 1)
  end)

  t.it("a shard reload (tiny queue) never triggers a restart, so no restart loop", function()
    local h = harness()
    h.run(1)
    t.assert_eq(#h.deferred, 0)
    t.assert_eq(h.restarts, 0)
  end)

  t.it("waits while editing, unsaved, re-indexing or prepare is running", function()
    local h = harness()
    h.run(400)
    h.mode = "i"; h.flush(); t.assert_eq(h.restarts, 0); t.assert_eq(#h.deferred, 1)
    h.mode = "n"; h.modified[1] = true; h.flush(); t.assert_eq(h.restarts, 0)
    h.modified[1] = nil; h.job = {}; h.flush(); t.assert_eq(h.restarts, 0)
    h.job = nil; h.flush(); t.assert_eq(h.restarts, 1)
  end)

  t.it("drops the attempt when indexing restarts; the next end re-arms it", function()
    local h = harness()
    h.run(400)
    h.client.progress.pending.backgroundIndexProgress = true
    h.flush()
    t.assert_eq(#h.deferred, 0)
    h.client.progress.pending.backgroundIndexProgress = nil
    h.run(400)
    h.flush()
    t.assert_eq(h.restarts, 1)
  end)

  t.it("waits from the latest index end instead of a superseded timer", function()
    local h = harness()
    h.run(400)
    local old = table.remove(h.deferred, 1)
    h.run(40)
    old.fn()
    t.assert_eq(h.restarts, 0)
    h.flush()
    t.assert_eq(h.restarts, 1)
  end)

  t.it("invalidates a busy retry when another index run completes", function()
    local h = harness()
    h.run(400)
    h.mode = "i"; h.flush()
    local old = table.remove(h.deferred, 1)
    h.mode = "n"; h.run(40)
    old.fn()
    t.assert_eq(h.restarts, 0)
    h.flush()
    t.assert_eq(h.restarts, 1)
  end)

  t.it("waits for the prepare owner even without an index job", function()
    local h = harness()
    local name = "ue.index.prepare_observer"
    local previous = package.loaded[name]
    local observer = assert(loadfile(vim.fn.stdpath("config") .. "/lua/ue/index/prepare_observer.lua"))()
    local preparing = true
    observer.configure(function() end, function() return preparing end)
    package.loaded[name] = observer
    h.run(400)
    local ok, err = pcall(function()
      h.flush()
      t.assert_eq(h.restarts, 0)
      preparing = false
      h.flush()
      t.assert_eq(h.restarts, 1)
    end)
    package.loaded[name] = previous
    if not ok then error(err) end
  end)

  t.it("requires a full quiet window after normal-mode input", function()
    local h = harness()
    h.run(400)
    h.now = 59000
    vim.api.nvim_feedkeys("l", "xt", false)
    h.now = 60000; h.flush()
    t.assert_eq(h.restarts, 0)
    h.now = 119000; h.flush()
    t.assert_eq(h.restarts, 1)
  end)

  t.it("gives up after bounded retries and records why", function()
    local h = harness()
    h.mode = "i"
    h.run(400)
    for _ = 0, reclaim.defaults.retries do h.flush() end
    t.assert_eq(h.restarts, 0)
    t.assert_eq(#h.deferred, 0)
    t.assert_eq(h.probes[#h.probes], "skipped:editor-busy")
  end)

  t.it("never restarts twice within the session interval, even for a new client", function()
    local clients = {}
    local h = harness({ get_client_by_id = function(id) return clients[id] end })
    clients[7] = h.client
    clients[8] = vim.tbl_extend("force", h.client, { id = 8 })
    h.run(400); h.flush()
    t.assert_eq(h.restarts, 1)
    local function run8(tasks)
      reclaim.on_progress(8, "clangd", { token = "backgroundIndexProgress", value = { kind = "report", message = "1/" .. tasks } })
      reclaim.on_progress(8, "clangd", { token = "backgroundIndexProgress", value = { kind = "end" } })
    end
    h.now = 60 * 1000
    run8(400); h.flush()
    t.assert_eq(h.restarts, 1)
    t.assert_eq(h.probes[#h.probes], "skipped:interval")
  end)

  t.it("ignores other servers, other tokens and batch-scope readers", function()
    local h = harness()
    reclaim.on_progress(7, "lua_ls", { token = "backgroundIndexProgress", value = { kind = "end" } })
    reclaim.on_progress(7, "clangd", { token = "other", value = { kind = "end" } })
    t.assert_eq(#h.deferred, 0)
    h.client.config._ue_batch_scope = "x"
    h.run(400); h.flush()
    t.assert_eq(h.restarts, 0)
  end)
end)
