-- ue.index._clangd — bounded clangd restart coordination.
return function(M, core)
  local RT = core.RT
  local unix_now = core.h.unix_now

  local function retain_original_reader(dependencies)
    local ctx = dependencies.context
    if dependencies.original_changed ~= false or dependencies.invalidated_frozen_batch == true
        or not ctx or not ctx.paths or not ctx.paths.semantic_cdb then return false end
    local fs = require("ue.core.fs")
    if not fs.is_absolute_path(vim.fs.normalize(ctx.paths.semantic_cdb)) then return false end
    local path_key = require("utils.platform").driver().path_key
    local function key(path) return path_key(vim.fs.normalize(path)) end
    local scope = key(ctx.paths.semantic_cdb)
    local waiting = false
    for _, status in ipairs(require("ue.index.batch_recovery").status()) do
      if status.scope == scope and status.waiting == true and status.phase == "waiting" and status.busy == false then
        waiting = true; break
      end
    end
    if not waiting then return false end
    local original_dir = key(vim.fs.dirname(ctx.paths.semantic_cdb))
    local frozen_dir = key(vim.fs.joinpath(original_dir, "verified"))
    local function directory(client)
      local config = client.config or {}
      local cmd = config._ue_resolved_cmd or config.cmd
      if type(cmd) ~= "table" or not vim.islist(cmd) then return end
      -- Match the recovery owner's reader contract: only its canonical option
      -- form can later be rediscovered and promoted when documents become clean.
      local selected
      for _, arg in ipairs(cmd) do
        if type(arg) ~= "string" then return end
        if arg == "--compile-commands-dir" or arg == "-compile-commands-dir"
            or arg:match("^%-%-?compile%-commands%-dir=") then
          local path = arg:match("^%-%-compile%-commands%-dir=(.+)$")
          -- Duplicate or mixed spellings have unproven effective precedence.
          if not path or selected or not fs.is_absolute_path(vim.fs.normalize(path)) then return end
          selected = key(path)
        end
      end
      return selected
    end
    local function owns(client)
      return directory(client) == original_dir and not (client.config or {})._ue_batch_scope
    end
    local reader
    for _, client in ipairs((dependencies.get_clients or vim.lsp.get_clients)({ name = "clangd" })) do
      local client_dir = directory(client)
      if not client_dir then return false end
      local batch_scope = (client.config or {})._ue_batch_scope
      if (type(batch_scope) == "string" and key(batch_scope) == scope) or client_dir == frozen_dir then
        return false
      end
      if owns(client) and client.initialized and not (client.is_stopped and client:is_stopped()) then
        for buffer in pairs(client.attached_buffers or {}) do
          if (dependencies.buffer_loaded or vim.api.nvim_buf_is_loaded)(buffer) then
            if reader then return false end
            reader = client; break
          end
        end
      end
    end
    return reader ~= nil and require("ue.index.batch_documents").modified(nil, ctx, reader.config.filetypes, owns)
  end

  M.maybe_restart_clangd_for_index = function(dependencies)
    dependencies = dependencies or {}
    -- The original reader already has the unchanged commands. Recovery owns
    -- the eventual fully validated frozen promotion; do not consume debounce.
    if retain_original_reader(dependencies) then return false end
    local now = (dependencies.now or unix_now)()
    if dependencies.invalidated_frozen_batch ~= true and (now - RT.last_restart_at) < RT.restart_debounce_s then
      return false, math.max(1, math.ceil((RT.restart_debounce_s - (now - RT.last_restart_at)) * 1000))
    end
    RT.last_restart_at = now

    local get_clients = dependencies.get_clients or vim.lsp.get_clients
    local list_bufs = dependencies.list_bufs or vim.api.nvim_list_bufs
    local buffer_valid = dependencies.buffer_valid or vim.api.nvim_buf_is_valid
    local buffer_loaded = dependencies.buffer_loaded or vim.api.nvim_buf_is_loaded
    local buffer_filetype = dependencies.buffer_filetype or function(bufnr)
      return vim.bo[bufnr].filetype
    end
    local defer_fn = dependencies.defer_fn or vim.defer_fn
    local start_clangd = dependencies.start_clangd or function(bufnr)
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("LspStart clangd")
      end)
    end

    local clients = get_clients({ name = "clangd" })
    local cpp_bufs = {}
    for _, client in ipairs(clients) do
      for buf in pairs(client.attached_buffers or {}) do
        if buffer_valid(buf) and buffer_loaded(buf) then
          cpp_bufs[buf] = true
        end
      end
      client:stop()
    end
    for _, bufnr in ipairs(list_bufs()) do
      if buffer_loaded(bufnr) then
        local ft = buffer_filetype(bufnr)
        if ft == "cpp" or ft == "c" or ft == "h" or ft == "objcpp" or ft == "objc" then
          cpp_bufs[bufnr] = true
        end
      end
    end

    defer_fn(function()
      for bufnr in pairs(cpp_bufs) do
        if buffer_valid(bufnr) then
          start_clangd(bufnr)
        end
      end
    end, 500)
    return true
  end

  -- A new attached client proves that the old in-memory BackgroundIndex was
  -- retired. Its normal startup revalidates persisted dependency digests.
  M.restart_source_clangd = function(ctx, callback, dependencies)
    dependencies = dependencies or {}
    local fs = require("ue.core.fs")
    local path_key = require("utils.platform").driver().path_key
    local function key(path) return path_key(fs.norm(path)):gsub("/+$", "") end
    local directory = key(vim.fs.dirname(ctx.paths.semantic_cdb))
    local function owns(client)
      local config = client and client.config or {}
      local cmd = config._ue_resolved_cmd or config.cmd
      if type(cmd) ~= "table" then return false end
      for index = #cmd, 1, -1 do
        local arg = cmd[index]
        local value = type(arg) == "string" and arg:match("^%-%-?compile%-commands%-dir=(.+)$")
        if arg == "--compile-commands-dir" or arg == "-compile-commands-dir" then value = cmd[index + 1] end
        if value then return key(value) == directory end
      end
      return false
    end
    local clients, old = {}, {}
    for _, client in ipairs((dependencies.get_clients or vim.lsp.get_clients)({ name = "clangd" })) do
      if owns(client) then clients[#clients + 1] = client; old[client.id] = true end
    end
    local create = dependencies.create_autocmd or vim.api.nvim_create_autocmd
    local delete = dependencies.delete_autocmd or vim.api.nvim_del_autocmd
    local get_client = dependencies.get_client_by_id or vim.lsp.get_client_by_id
    local done, autocmd = false, nil
    local function finish(ok)
      if done then return end
      done = true
      if autocmd then pcall(delete, autocmd) end
      callback(ok)
    end
    autocmd = create("LspAttach", { callback = function(event)
      local id = event.data and event.data.client_id
      if id and not old[id] and owns(get_client(id)) then finish(true) end
    end })
    -- No current reader: keep the request until the next natural attachment,
    -- rather than spawning an indexer or repeatedly rebuilding an unused CDB.
    if #clients == 0 then return true end
    local options = vim.tbl_extend("force", dependencies, {
      get_clients = function() return clients end, list_bufs = function() return {} end,
    })
    local ok, started, delay = pcall(M.maybe_restart_clangd_for_index, options)
    if not ok or not started then
      done = true
      pcall(delete, autocmd)
      return false, delay or 5000
    end
    (dependencies.defer_fn or vim.defer_fn)(function() finish(false) end, 15000)
    return true
  end
end
