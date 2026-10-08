-- Background header warmup shares the foreground resolver and its proof gates.
-- It owns no navigation outcome, destination cache or window lineage.
local M = {}
local headers = { h = true, hh = true, hpp = true, hxx = true, inl = true, ipp = true, ixx = true }

function M.install(client, deps)
  deps = deps or {}
  local admission = deps.admission or require("utils.host_admission")
  local cpu = deps.cpu or require("utils.cpu_load")
  local defer = deps.defer or vim.defer_fn
  local state = { generation = 0 }
  local background = {}
  local function trace(event, reason)
    if type(client.trace_event) == "function" then
      client.trace_event(event, { stale_reason = reason, provider = "prewarm" })
    end
  end

  function background.cancel(reason)
    if state.active then trace("prewarm-cancel", reason or "superseded") end
    state.active = false
    state.generation = state.generation + 1
    if state.timer then
      pcall(state.timer.stop, state.timer)
      pcall(state.timer.close, state.timer)
      state.timer = nil
    end
    if state.control then state.control:cancel(); state.control = nil end
    if state.subscriber then cpu.unsubscribe(state.subscriber); state.subscriber = nil end
    if type(client.cancel_queued_actions) == "function" then client.cancel_queued_actions() end
  end

  function background.start(bufnr)
    bufnr = bufnr and bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then return false end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if not headers[path:lower():match("%.([^./\\]+)$") or ""]
        or vim.bo[bufnr].buftype ~= "" then return false end
    local winid = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(winid) ~= bufnr then return false end
    -- Hidden/temporary buffers emit FileType while LSP loads. They have no
    -- ownership of the current header's background transaction.
    background.cancel()
    state.active = true
    trace("prewarm-start")
    local generation = state.generation
    local function current()
      return state.generation == generation and vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_get_current_win() == winid and vim.api.nvim_win_get_buf(winid) == bufnr
    end
    -- Let buffer/window transition and any successful jump lineage commit finish.
    state.timer = defer(function()
      state.timer = nil
      if not current() then return end
      local snapshot = {
        prewarm = true, token = generation, background_is_current = current,
        winid = winid, bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(winid),
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
        document_version = vim.api.nvim_buf_get_changedtick(bufnr),
      }
      local function allowed(reading)
        local options = admission.options()
        options.max_deferrals = math.huge
        return admission.admit(reading, 0, options)
      end
      state.subscriber = cpu.subscribe(function(reading)
        if current() and not allowed(reading) then background.cancel("host-pressure") end
      end)
      local _, _, _, control = admission.run_when_allowed({
        name = "header semantic prewarm", options = { max_deferrals = math.huge }, retry_ms = 250,
        on_error = function() if current() then background.cancel("prewarm-error") end end,
        start = function()
          if not current() then return end
          trace("prewarm-admitted")
          local environment = client.discover_toolchain(bufnr, { route = "header" })
          if not environment or not current() then background.cancel("environment-unavailable"); return end
          client.capture_overlays(snapshot, environment)
          client.resolve_header({
            snapshot = snapshot, environment = environment, path = path,
            line = snapshot.cursor[1], column = snapshot.cursor[2] + 1,
          }, function()
            -- Never publish a semantic result or commit lineage from warmup.
            if current() then background.cancel("finished") end
          end)
        end,
      })
      if current() then state.control = control else control:cancel() end
    end, 50)
    return true
  end

  function background.on_enter(event)
    if event.buf ~= vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) then return false end
    return background.start(event.buf)
  end

  function background.setup()
    local group = vim.api.nvim_create_augroup("UESemanticHeaderPrewarm", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
      group = group, callback = function(event) background.on_enter(event) end,
      desc = "Warm proven C++ header contexts without navigation side effects",
    })
    vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "TextChanged", "TextChangedI" }, {
      group = group, callback = function(event) background.cancel(event.event) end,
      desc = "Cancel obsolete queued C++ header prewarm",
    })
  end

  return background
end

return M
