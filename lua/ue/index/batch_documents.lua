-- Loaded document metadata only; no source reads or project resolution.
local M = {}
local fs = require("ue.core.fs")
local platform = require("utils.platform")

local function key(path)
  return platform.driver().path_key(vim.fs.normalize(path))
end

function M.modified(bufnr, ctx, filetypes, owns_client)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified and vim.bo[buffer].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" then
        if buffer == bufnr then return true end
        for _, client in ipairs(vim.lsp.get_clients({ name = "clangd", bufnr = buffer })) do
          if owns_client(client) then return true end
        end
        if filetypes == nil or vim.tbl_contains(filetypes, vim.bo[buffer].filetype) then
          local path = key(name)
          for _, field in ipairs({ "engine_root", "project_root" }) do
            if ctx[field] and fs.path_has_prefix(path, key(ctx[field])) then return true end
          end
        end
      end
    end
  end
  return false
end

return M
