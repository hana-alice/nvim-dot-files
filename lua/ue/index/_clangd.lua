-- ue.index._clangd — bounded clangd restart coordination.
return function(M, core)
  local RT = core.RT
  local unix_now = core.h.unix_now

  M.maybe_restart_clangd_for_index = function(dependencies)
    dependencies = dependencies or {}
    local now = (dependencies.now or unix_now)()
    if (now - RT.last_restart_at) < RT.restart_debounce_s then return end
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
  end
end
