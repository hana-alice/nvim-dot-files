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

while running do
  local line = io.read("*l")
  if line == nil then break end
  decoder:push(line .. "\n")
end

decoder:finish()
sidecar:shutdown()
