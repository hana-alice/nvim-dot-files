-- Shared picker presentation; no jobs, state polling or provider substitution.
local M = {}
local presentation = require("utils.code_search.picker")

function M.status(picker, metadata, token)
  if vim.in_fast_event() then
    local frozen = vim.deepcopy(metadata)
    vim.schedule(function()
      M.status(picker, frozen, token)
    end)
    return
  end
  if not picker or picker.closed or (token and picker._ue_search_generation ~= token) then
    return
  end
  picker.opts.ue_search_status = vim.deepcopy(metadata)
  local base = picker.opts.ue_search_base_title or picker.title or picker.opts.title or "Search"
  picker.opts.ue_search_base_title = base
  local displayed = vim.deepcopy(metadata)
  if metadata.visible ~= nil then
    displayed.delivered = metadata.visible
    if metadata.complete and metadata.visible == 0 then
      displayed.state = "empty"
    end
  end
  picker.title = "[" .. presentation.status_label(displayed) .. "] " .. base
  if picker.update_titles then
    picker:update_titles()
  end
end

function M.begin(picker)
  local token = {}
  if picker then
    picker._ue_search_generation = token
  end
  return token
end

function M.format(item, picker)
  local copy = vim.tbl_extend("force", {}, item)
  local location = item.ue_location
  local pending_column = item.loc and not item.loc.resolved and item.loc.encoding ~= "utf-8"
  if item.pos then
    local line_only = pending_column or (location and location.precision == "line")
    copy.pos = { item.pos[1], line_only and 0 or (tonumber(item.pos[2]) or 0) + 1 }
  end
  local chunks = require("snacks.picker.format").file(copy, picker)
  if location and location.precision == "line" then
    chunks[#chunks + 1] = { " [行定位]", "SnacksPickerComment" }
  elseif pending_column then
    chunks[#chunks + 1] = { " [列待预览]", "SnacksPickerComment" }
  end
  return chunks
end

return M
