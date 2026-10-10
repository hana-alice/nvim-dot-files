-- Run the installed grep provider's native argv/transform with visible errors.
-- The provider still owns argument semantics; the existing reader owns EOF,
-- limits and cancellation. Nothing here builds a shell command or scans twice.
local M = {}
local uv = vim.uv or vim.loop
local ui = require("utils.search_ui")

function M.find(opts, ctx)
  return function(cb)
    local picker = ctx.picker
    local token = ui.begin(picker)
    local done, pending, received = false, {}, 0
    local admission = require("utils.host_admission")
    local foreground = admission.foreground_begin("explicit grep")
    local released = false
    local function release()
      if released then
        return
      end
      released = true
      admission.foreground_done(foreground)
    end
    ui.status(picker, { state = "running", delivered = 0 }, token)
    local reader = require("utils.code_search.stream_reader").new({
      backend = "rg",
      max_count = picker.opts.max_count or 5000,
      timeout_ms = picker.opts.timeout_ms or 30000,
      parse = function(record)
        local item = { text = record }
        local transformed = opts.transform and opts.transform(item, ctx)
        if transformed == false then
          return false
        end
        if type(transformed) == "table" then
          item = transformed
        end
        return {
          file = item.file,
          lnum = item.pos and item.pos[1],
          col = item.pos and item.pos[2],
          text = item.text,
          location = { item = item },
        }
      end,
    }, {
      on_line = function(_, _, _, _, location)
        received = received + 1
        pending[received] = location.item
      end,
      on_done = function(_, err, metadata)
        done = true
        metadata.error = err
        ui.status(picker, metadata, token)
        release()
      end,
    })
    local arguments = vim.deepcopy(opts.args or {})
    if opts.cmd == "rg" then
      table.insert(arguments, 1, "--threads=1")
    end
    local handle, spawn_err = uv.spawn(opts.cmd, {
      args = arguments,
      cwd = opts.cwd,
      env = opts.env,
      hide = true,
      stdio = { nil, reader.stdout, reader.stderr },
    }, function(code, signal)
      reader:exit(code, signal)
    end)
    local stop = reader:attach(handle, spawn_err)
    ctx.async:on("abort", function()
      stop("picker-aborted")
      release()
    end)
    ctx.async:on("error", function()
      stop("finder-error")
      release()
    end)
    local index = 1
    while not done or index <= received do
      local last = math.min(received, index + 79)
      for row = index, last do
        cb(pending[row])
        pending[row] = nil
      end
      index = last + 1
      if not done or index <= received then
        ctx.async:sleep(2)
      end
    end
  end
end

return M
