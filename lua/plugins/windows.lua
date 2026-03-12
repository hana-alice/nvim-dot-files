if vim.fn.has("win32") == 0 and vim.fn.has("win64") == 0 then
  return {}
end

local function ue_status()
  local status = vim.g.ueindex_status
  if not status or status == "" then
    return ""
  end
  return status
end

return {
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      opts.sections = opts.sections or {}
      opts.sections.lualine_x = opts.sections.lualine_x or {}

      for _, component in ipairs(opts.sections.lualine_x) do
        if component == ue_status then
          return
        end
      end

      table.insert(opts.sections.lualine_x, 1, ue_status)
    end,
  },
}
