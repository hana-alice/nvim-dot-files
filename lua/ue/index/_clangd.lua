-- ue.index._clangd — bounded clangd restart coordination.
return function(M, core)
  local RT = core.RT
  local unix_now = core.h.unix_now

  M.maybe_restart_clangd_for_index = function()
    local now = unix_now()
    if (now - RT.last_restart_at) < RT.restart_debounce_s then return end
    RT.last_restart_at = now

    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients == 0 then return end

    local cpp_bufs = {}
    for _, client in ipairs(clients) do
      for buf in pairs(client.attached_buffers or {}) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
          cpp_bufs[buf] = true
        end
      end
      client:stop()
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local ft = vim.bo[bufnr].filetype
        if ft == "cpp" or ft == "c" or ft == "h" or ft == "objcpp" or ft == "objc" then
          cpp_bufs[bufnr] = true
        end
      end
    end

    vim.defer_fn(function()
      for bufnr in pairs(cpp_bufs) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("LspStart clangd")
          end)
        end
      end
    end, 500)
  end
end
