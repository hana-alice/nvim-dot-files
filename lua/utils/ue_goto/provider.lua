-- Stable public provider surface; implementations have separate owners.
local M = { config = { LSP_RETRY_COUNT = 20, LSP_RETRY_INTERVAL_MS = 2000 } }

function M.sync_locations(...)
  return require("utils.ue_goto.lsp_transport").sync_locations(...)
end
function M.async_lsp_request(...)
  return require("utils.ue_goto.clangd_adapter").async_lsp_request(...)
end
function M.async_clangd_symbol_info(...)
  return require("utils.ue_goto.clangd_adapter").async_clangd_symbol_info(...)
end
function M.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, callback)
  return require("utils.ue_goto.compat_navigation").async_lsp_definition_with_retry(
    bufnr, ref_file, ref_line, still_current, callback, M.config)
end
function M.gtags_fallback_async(...)
  return require("utils.ue_goto.compat_navigation").gtags_fallback_async(...)
end
return M
