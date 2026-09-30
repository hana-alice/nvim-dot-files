local t = require("tests.harness")
t.bootstrap()

local function fixture(run)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_retain_reader"
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, root .. "/Engine/Source/A.cpp")
  vim.bo[buf].filetype = "cpp"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  local ctx = { engine_root = root, project_root = root .. "/Game",
    paths = { semantic_cdb = root .. "/background/compile_commands.json" } }
  local stopped, deferred = 0, 0
  local client = { id = 101, initialized = true, attached_buffers = { [buf] = true },
    config = { cmd = { "clangd", "--compile-commands-dir=" .. root .. "/background" }, filetypes = { "cpp" } },
    is_stopped = function() return false end, stop = function() stopped = stopped + 1 end }
  local clients = { client }
  local scope = require("utils.platform").driver().path_key(ctx.paths.semantic_cdb)
  local statuses = { { scope = scope, phase = "waiting", waiting = true, busy = false } }
  local recovery = require("ue.index.batch_recovery")
  local old_clients, old_status = vim.lsp.get_clients, recovery.status
  vim.lsp.get_clients = function(opts)
    local found = {}
    for _, value in ipairs(clients) do
      if not opts.bufnr or value.attached_buffers[opts.bufnr] then found[#found + 1] = value end
    end
    return found
  end
  recovery.status = function() return statuses end
  local runtime = { last_restart_at = 0, restart_debounce_s = 10 }
  local index = {}
  require("ue.index._clangd")(index, { RT = runtime, h = { unix_now = function() return 100 end } })
  local deps = { context = ctx, original_changed = false, list_bufs = function() return {} end,
    defer_fn = function() deferred = deferred + 1 end }
  local ok, err = pcall(run, { ctx = ctx, client = client, clients = clients, statuses = statuses,
    buf = buf, runtime = runtime, deps = deps, restart = index.maybe_restart_clangd_for_index,
    counts = function() return stopped, deferred end })
  recovery.status, vim.lsp.get_clients = old_status, old_clients
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err) end
end

t.describe("original reader retained while frozen activation waits for documents", function()
  t.it("does not restart, postpone or consume debounce when only frozen publication changes", function()
    fixture(function(f)
      f.runtime.last_restart_at = 99
      local restarted, delay = f.restart(f.deps)
      t.assert_false(restarted); t.assert_nil(delay)
      t.assert_eq(f.runtime.last_restart_at, 99)
      local stopped, deferred = f.counts()
      t.assert_eq(stopped, 0); t.assert_eq(deferred, 0)
      t.assert_true(vim.bo[f.buf].modified)
    end)
  end)

  t.it("uses the resolved effective command and ignores an unrelated reader", function()
    fixture(function(f)
      f.client.config._ue_resolved_cmd = f.client.config.cmd
      f.client.config.cmd = function() error("must not execute a dynamic command") end
      local foreign = vim.deepcopy(f.client)
      foreign.config._ue_resolved_cmd = { "clangd", "--compile-commands-dir=/foreign" }
      f.clients[#f.clients + 1] = foreign
      t.assert_false(f.restart(f.deps))
      t.assert_eq(f.counts(), 0)
    end)
  end)

  for _, case in ipairs({ "clean", "unregistered", "wrong-scope", "busy", "ready", "not-waiting",
    "foreign-dirty", "wrong-filetype", "frozen-scope", "frozen-directory", "second-frozen", "multiple",
    "missing-flag", "changed-original", "stopped", "uninitialized", "unattached", "invalidation",
    "split-option", "single-dash", "foreign-original", "missing-context", "duplicate-original",
    "original-then-verified", "verified-then-original", "mixed-split", "mixed-single-dash", "mixed-empty",
    "second-unparseable", "relative-primary", "second-relative", "relative-context" }) do
    t.it("retains the existing restart path for " .. case, function()
      fixture(function(f)
        if case == "clean" then vim.bo[f.buf].modified = false
        elseif case == "unregistered" then f.statuses[1] = nil
        elseif case == "wrong-scope" then f.statuses[1].scope = "another-scope"
        elseif case == "busy" then f.statuses[1].busy = true
        elseif case == "ready" then f.statuses[1].phase = "ready"
        elseif case == "not-waiting" then f.statuses[1].waiting = false
        elseif case == "foreign-dirty" or case == "wrong-filetype" then
          f.client.attached_buffers = { [vim.api.nvim_get_current_buf()] = true }
          if case == "foreign-dirty" then vim.api.nvim_buf_set_name(f.buf, f.ctx.engine_root .. "-foreign/A.cpp")
          else vim.bo[f.buf].filetype = "text" end
        elseif case == "frozen-scope" then f.client.config._ue_batch_scope = f.statuses[1].scope
        elseif case == "frozen-directory" then
          f.client.config.cmd[2] = "--compile-commands-dir=" .. vim.fs.dirname(f.ctx.paths.semantic_cdb) .. "/verified"
        elseif case == "second-frozen" or case == "multiple" then
          local other = vim.deepcopy(f.client); other.id = 102
          if case == "second-frozen" then other.config._ue_batch_scope = f.statuses[1].scope end
          f.clients[#f.clients + 1] = other
        elseif case == "missing-flag" then f.deps.original_changed = nil
        elseif case == "changed-original" then f.deps.original_changed = true
        elseif case == "stopped" then f.client.is_stopped = function() return true end
        elseif case == "uninitialized" then f.client.initialized = false
        elseif case == "unattached" then f.client.attached_buffers = {}
        elseif case == "invalidation" then f.deps.invalidated_frozen_batch = true
        elseif case == "split-option" then
          f.client.config.cmd = { "clangd", "--compile-commands-dir", vim.fs.dirname(f.ctx.paths.semantic_cdb) }
        elseif case == "single-dash" then
          f.client.config.cmd[2] = "-compile-commands-dir=" .. vim.fs.dirname(f.ctx.paths.semantic_cdb)
        elseif case == "duplicate-original" then
          f.client.config.cmd[3] = f.client.config.cmd[2]
        elseif case == "original-then-verified" or case == "verified-then-original" then
          local original = f.client.config.cmd[2]
          local verified = original .. "/verified"
          f.client.config.cmd[2] = case == "original-then-verified" and original or verified
          f.client.config.cmd[3] = case == "original-then-verified" and verified or original
        elseif case == "mixed-split" then
          f.client.config.cmd[3] = "--compile-commands-dir"
          f.client.config.cmd[4] = "/foreign"
        elseif case == "mixed-single-dash" then f.client.config.cmd[3] = "-compile-commands-dir=/foreign"
        elseif case == "mixed-empty" then f.client.config.cmd[3] = "--compile-commands-dir="
        elseif case == "second-unparseable" then
          local other = vim.deepcopy(f.client); other.id = 102; other.config.cmd = { "clangd" }
          f.clients[#f.clients + 1] = other
        elseif case == "relative-primary" then f.client.config.cmd[2] = "--compile-commands-dir=background"
        elseif case == "second-relative" then
          local other = vim.deepcopy(f.client); other.id = 102
          other.config.cmd[2] = "--compile-commands-dir=background"
          f.clients[#f.clients + 1] = other
        elseif case == "relative-context" then
          f.ctx.paths.semantic_cdb = "background/compile_commands.json"
          f.statuses[1].scope = f.ctx.paths.semantic_cdb
          f.client.config.cmd[2] = "--compile-commands-dir=background"
        elseif case == "foreign-original" then f.client.config.cmd[2] = "--compile-commands-dir=/foreign"
        elseif case == "missing-context" then f.deps.context = nil end
        t.assert_true(f.restart(f.deps))
        local stopped, deferred = f.counts()
        t.assert_eq(stopped, #f.clients); t.assert_eq(deferred, 1)
        t.assert_eq(f.runtime.last_restart_at, 100)
      end)
    end)
  end
end)
