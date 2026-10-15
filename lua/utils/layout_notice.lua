-- Navigation provenance is derived on UI events; statusline redraws read text only.
local M = {}
local api = vim.api
local queued, notice_tab = false, nil

local function queue(notify)
  if notify then
    notice_tab = api.nvim_get_current_tabpage()
  end
  if queued then
    return
  end
  queued = true
  vim.schedule(function()
    queued = false
    local tab, entered = api.nvim_get_current_tabpage(), notice_tab
    notice_tab = nil
    local layout = package.loaded["utils.layout"]
    local source = layout and layout.navigation_source and layout.navigation_source()
    local text = source
        and ("编辑 ← %s tab %d · <leader>w[ 返回"):format(
          source.kind == "review" and "审阅" or "调试",
          source.tabnr
        )
      or ""
    local previous = vim.t[tab].ue_layout_source or ""
    vim.t[tab].ue_layout_source = text
    if entered == tab and text ~= "" and text ~= previous then
      vim.notify(text, vim.log.levels.INFO, { title = "Layout" })
    end
  end)
end

function M.setup()
  local group = api.nvim_create_augroup("UELayoutNavigationNotice", { clear = true })
  api.nvim_create_autocmd("TabLeave", {
    group = group,
    callback = function()
      vim.t.ue_layout_source = ""
    end,
  })
  api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      queue(true)
    end,
  })
  api.nvim_create_autocmd({ "BufEnter", "WinClosed", "TabClosed", "BufWipeout" }, {
    group = group,
    callback = function()
      queue(false)
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "CodeDiffOpen", "CodeDiffClose" },
    callback = function(ev)
      -- Close is emitted before owner cleanup and layout's scheduled retirement.
      if ev.match == "CodeDiffClose" then
        vim.schedule(function()
          queue(false)
        end)
      else
        queue(false)
      end
    end,
  })
  queue(false)
end

return M
