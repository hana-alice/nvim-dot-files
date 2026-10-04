-- Run with navigation_native.py: real installed Snacks/clangd/GLOBAL, a native
-- one-command fixture CDB, isolated stdpath/probes. UE discovery/readiness and
-- prepare are seams; compiler responses and coordinator proof are not mocked.
local cfg, dir, plugin_data, clangd = ...
vim.fn.writefile({}, dir .. "/native-setup-stages.log")
local function mark(label)
  vim.fn.writefile({ label }, dir .. "/native-setup-stages.log", "a")
end
mark("start")
vim.opt.rtp:prepend(cfg)
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
vim.o.swapfile, vim.o.shada, vim.o.hidden, vim.o.more = false, "", true, false
vim.o.shortmess = "filnxtToOFc"
vim.env.NVIM_UE_PROBE_PATH, vim.env.NVIM_UE_LOG_DIR = dir .. "/probes.json", dir .. "/logs"
vim.env.UE_CLANGD = clangd
vim.g.started_with_stdin = true
local messages = {}
vim.notify = function(message)
  messages[#messages + 1] = tostring(message)
end
local root = dir .. "/fixture"
vim.fn.mkdir(root, "p")
local source, header = root .. "/main.cpp", root .. "/main.hpp"
local lines = {
  '#include "main.hpp"',
  "int selected() { return 7; }",
  "int middle() { return selected(); }",
  "int root() { return middle(); }",
  "int recursive() { return recursive(); }",
  "// selected",
  "int unicode() { /*前😀*/ return selected(); }",
  "int use_type() { Leaf value; return 0; }",
  "int use_base() { Base value; return 0; }",
}
for line = 10, 160 do
  lines[line] = "// native reading context " .. line
end
vim.fn.writefile(lines, source)
vim.fn.writefile(
  { "#pragma once", "struct Base {};", "struct Derived : Base {};", "struct Leaf : Derived {};", "int selected();" },
  header
)
local command = { "clang++", "-std=c++17", "-c", source }
local cdb = vim.json.encode({ { directory = root, file = source, arguments = command } })
vim.fn.writefile({ cdb }, root .. "/compile_commands.json")
local tags = {}
for index = 1, 128 do
  tags[index] = "int tagged" .. index .. "() { return selected(); }"
end
vim.fn.writefile(tags, root .. "/tagged.cpp")
mark("require-ue")
local actual_ue = require("ue")
clangd = actual_ue.clangd_cmd()[1]
assert(vim.fn.executable(clangd) == 1, "native clangd unavailable")
vim.env.UE_CLANGD = clangd
mark("ue-loaded")
local context = {
  engine_root = root,
  project_root = root,
  state = { target_platform = "Win64", target_configuration = "Test", target = "NativeFixture" },
  paths = { active_cdb = root .. "/compile_commands.json", workspace_db = root, state = root .. "/state.json" },
}
local index = {
  readiness = "ready",
  freshness = "fresh",
  complete = true,
  generation_id = "native-reading-fixture",
  coverage_level = "full",
  artifact_fingerprint = vim.fn.sha256(cdb),
}
local state = {
  source = source,
  header = header,
  root = root,
  lines = lines,
  context = context,
  received = {},
  delivered = {},
  delay = {},
  trace = {},
  gtags_started = 0,
  gtags_kill = 0,
  messages = messages,
}
package.loaded.ue = {
  resolve_context = function()
    return context
  end,
  clangd_cmd = function()
    return { clangd }
  end,
  semantic_index_snapshot = function()
    return vim.deepcopy(index)
  end,
  gtags_references_async = function(symbol, callback, opts)
    state.gtags_started = state.gtags_started + 1
    local handle = actual_ue.gtags_references_async(symbol, function(...)
      local arguments = { ... }
      state.gtags_received = (state.gtags_received or 0) + 1
      state.gtags_hits = arguments[2] and #arguments[2] or 0
      vim.defer_fn(function()
        state.gtags_delivered = (state.gtags_delivered or 0) + 1
        callback(unpack(arguments))
      end, state.gtags_delay or 0)
    end, opts)
    if handle then
      state.gtags_handle = handle
      local kill = handle.kill
      handle.kill = function(self, signal)
        state.gtags_kill = state.gtags_kill + 1
        return kill(self, signal)
      end
    end
    return handle
  end,
}
-- Only the UE discovery/preparation boundary is supplied. The actual fixture
-- CDB is consumed by this real clangd, and every semantic answer is native.
package.loaded["ue.clangd_commands"] = {
  ensure = function(_, buf, callback)
    local path = vim.api.nvim_buf_get_name(buf):gsub("\\", "/")
    if path ~= source then
      callback(false, "fixture-source-not-covered")
      return
    end
    callback(true, nil, { workingDirectory = root, compilationCommand = vim.deepcopy(command) })
  end,
}
for _, plugin in ipairs({ "snacks.nvim", "LazyVim", "lazy.nvim" }) do
  vim.opt.rtp:append(plugin_data .. "/lazy/" .. plugin)
end
_G.Snacks = require("snacks")
_G.LazyVim = require("lazyvim")
LazyVim.config = require("lazyvim.config")
local opts = { dashboard = { enabled = false }, picker = { enabled = true } }
mark("snacks-opts")
opts = require("plugins.snacks")[1].opts(nil, opts) or opts
mark("snacks-setup")
Snacks.setup(opts)
mark("edit-source")
vim.cmd.edit(vim.fn.fnameescape(source))
state.buf, state.win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.bo.filetype = "cpp"
state.client_id = vim.lsp.start({
  name = "clangd",
  root_dir = root,
  cmd = {
    clangd,
    "--background-index=false",
    "--enable-config=false",
    "--clang-tidy=false",
    "--pch-storage=memory",
    "--compile-commands-dir=" .. root,
    "-j=1",
    "--log=error",
  },
}, {
  bufnr = state.buf,
  reuse_client = function()
    return false
  end,
})
local client = assert(vim.lsp.get_client_by_id(state.client_id))
mark("client-initialize")
assert(vim.wait(10000, function()
  return client.initialized
end, 10))
mark("client-ready")
local request = client.request
client.request = function(self, method, params, callback, buf)
  state.trace[#state.trace + 1] = { method = method }
  return request(self, method, params, function(err, response, ctx, config)
    if method == "textDocument/symbolInfo" and not err and type(response) == "table" then
      local item = response[1] or response
      state.native_identity = {
        provider = "native-clangd",
        usr_hash = item.usr and vim.fn.sha256(item.usr),
        definition_line = item.definitionRange and item.definitionRange.range.start.line + 1,
      }
    end
    state.received[method] = (state.received[method] or 0) + 1
    vim.defer_fn(function()
      state.delivered[method] = (state.delivered[method] or 0) + 1
      callback(err, response, ctx, config)
    end, state.delay[method] or 0)
  end, buf)
end
state.client = client
local cancel_request = client.cancel_request
client.cancel_request = function(self, id)
  state.lsp_cancel = (state.lsp_cancel or 0) + 1
  return cancel_request(self, id)
end
function state.at(line, word)
  require("utils.ue_goto.reading").cancel()
  vim.api.nvim_set_current_win(state.win)
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.api.nvim_win_set_cursor(state.win, { line, (word and assert(state.lines[line]:find(word, 1, true)) or 1) - 1 })
end
function state.wait_picker()
  assert(
    vim.wait(10000, function()
      local picker = Snacks.picker.get()[1]
      return picker and picker:count() > 0 and not picker.matcher.task:running()
    end, 10),
    "reading picker unavailable"
  )
  local picker = Snacks.picker.get()[1]
  local visible_preview = not picker.layout:is_hidden("preview")
  if visible_preview then
    assert(
      vim.wait(1000, function()
        local buf = picker.preview and picker.preview.win and picker.preview.win.buf
        return buf and vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= ""
      end, 10),
      "native preview text unavailable"
    )
  end
  vim.cmd.redraw()
  return {
    count = picker:count(),
    auto_confirm = picker.opts.auto_confirm == true,
    preview = visible_preview,
    preview_text = visible_preview,
    title = picker.opts.title,
    cursor = vim.api.nvim_win_get_cursor(state.win),
    source = vim.api.nvim_win_get_buf(state.win) == state.buf,
  }
end
function state.other(tab)
  if tab then
    vim.cmd.tabnew()
  else
    vim.cmd.vsplit()
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unrelated unsaved input" })
  state.other_win, state.other_buf = win, buf
  return { win = win, buf = buf }
end
function state.clean_other()
  if state.other_win and vim.api.nvim_win_is_valid(state.other_win) then
    vim.api.nvim_win_close(state.other_win, true)
  end
  if state.other_buf and vim.api.nvim_buf_is_valid(state.other_buf) then
    vim.api.nvim_buf_delete(state.other_buf, { force = true })
  end
  state.other_win, state.other_buf = nil, nil
  vim.api.nvim_set_current_win(state.win)
end
require("utils.ue_goto.reading").setup_commands()
_G.nav = state
local owned = require("utils.ue_goto.reading_owner")
local close_picker = owned.close_picker
owned.close_picker = function(owner, picker)
  local event = { before = owned.current(owner, true), epoch = owner.epoch, source_win = owner.win }
  local result = close_picker(owner, picker)
  event.result, event.cancelled, event.after_win = result, owner.cancelled == true, vim.api.nvim_get_current_win()
  state.last_close = event
  return result
end
return {
  fixture_only = true,
  fixture_coverage_only = true,
  lines = #lines,
  bytes = vim.uv.fs_stat(source).size,
  client_id = state.client_id,
  cdb_commands = 1,
  clangd = clangd,
}
