local cfg = vim.fn.stdpath("config")
vim.opt.rtp:prepend(cfg)

local package_globs = cfg .. "/lua/?.lua;"
  .. cfg .. "/lua/?/init.lua;"
  .. cfg .. "/?.lua;"
  .. cfg .. "/?/init.lua;"
if not package.path:find(cfg .. "/lua/?.lua;", 1, true) then
  package.path = package_globs .. package.path
end

local protocol = require("utils.ue_goto.semantic_protocol")
local sidecar = require("utils.ue_goto.semantic_sidecar").new()

local running = true

local function emit(frame)
  io.stdout:write(protocol.encode(frame))
  io.stdout:flush()
end

local decoder = protocol.new_decoder({
  on_frame = function(frame)
    if not running then return end
    local ok, response = pcall(function()
      return sidecar:handle_request(frame)
    end)
    if not ok then
      io.stderr:write("[ue.semantic_sidecar] request crashed: " .. tostring(response) .. "\n")
      emit(protocol.request_error(frame, "internal-error", "sidecar request crashed", {
        op = frame.op,
        error = response,
      }))
      return
    end
    emit(response)
    if frame.op == "shutdown" then
      running = false
    end
  end,
  on_error = function(frame)
    emit(frame)
  end,
})

-- Read a bounded libuv chunk, stop reading while it is decoded/processed, then
-- resume. Standard io.read(n) can wait for n bytes and deadlock an interactive
-- client; read('*l') can allocate an unbounded line before the decoder sees it.
local input = assert(vim.uv.new_pipe(false))
assert(input:open(0))
local on_read
on_read = function(err, chunk)
  input:read_stop()
  vim.schedule(function()
    if not running then return end
    if err then
      emit(protocol.protocol_error(nil, "stdin-read-error", tostring(err)))
      running = false
    elseif chunk then
      decoder:push(chunk)
    else
      decoder:finish()
      running = false
    end
    if running then input:read_start(on_read) end
  end)
end
input:read_start(on_read)
while running do vim.wait(1000, function() return not running end, 10) end

input:read_stop()
input:close()
sidecar:shutdown()
