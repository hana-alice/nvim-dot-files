-- Real Neovim + clangd + installed CodeDiff integration. Child process isolation
-- also keeps intentionally broken legacy controls out of the regression runner.
local function native_paths()
  local clangd = vim.env.UE_CLANGD or vim.fn.exepath("clangd")
  if clangd == "" and vim.fn.has("win32") == 1 then
    clangd = (vim.env.ProgramFiles or "C:/Program Files") .. "/LLVM/bin/clangd.exe"
  end
  local codediff = vim.fn.stdpath("data") .. "/lazy/codediff.nvim"
  return clangd, codediff
end

local function integration(mode)
  local cfg = vim.fn.stdpath("config")
  vim.opt.rtp:prepend(cfg)
  package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  vim.env.XDG_STATE_HOME = root .. "/state"
  vim.env.XDG_CACHE_HOME = root .. "/cache"
  vim.env.NVIM_LOG_FILE = root .. "/nvim.log"
  vim.env.NVIM_UE_LOG_DIR = root .. "/logs"
  vim.env.NVIM_UE_PROBE_PATH = root .. "/probes.json"
  vim.lsp.set_log_level("debug")
  local clangd, codediff = native_paths()
  assert(vim.fn.executable(clangd) == 1, "real clangd unavailable: " .. clangd)
  assert(vim.fn.isdirectory(codediff) == 1, "installed CodeDiff unavailable")
  vim.opt.rtp:prepend(codediff)
  local repo = root .. "/repo"
  vim.fn.mkdir(repo, "p")
  local function git(args)
    local cmd = { "git", "-C", repo }
    vim.list_extend(cmd, args)
    local result = vim.system(cmd, { text = true }):wait(10000)
    assert(result.code == 0, result.stderr)
    return vim.trim(result.stdout)
  end
  git({ "init", "--quiet" })
  vim.fn.writefile({ "int alpha() { return 1; }" }, repo .. "/a.cpp")
  vim.fn.writefile({ "int beta() { return 2; }" }, repo .. "/b.cpp")
  git({ "add", "a.cpp", "b.cpp" })
  -- Staged :0 revisions need no commit and never update any user Git refs.
  local report = { mode = mode, fixture_root = root, clangd = clangd,
    version = vim.version(), events = {}, messages = {}, text_document_traffic = {} }
  local function event(kind, extra)
    report.events[#report.events + 1] = vim.tbl_extend("force", { kind = kind }, extra or {})
  end
  local notify = vim.notify
  vim.notify = function(msg, level)
    report.messages[#report.messages + 1] = { text = tostring(msg), level = level }
  end
  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach", "FileType" }, {
    callback = function(args)
      event(args.event, { buf = args.buf, name = vim.api.nvim_buf_get_name(args.buf),
        filetype = vim.bo[args.buf].filetype, client_id = args.data and args.data.client_id })
    end,
  })
  local workaround = require("workarounds.clangd.non_file_uri_detach")
  local native_attach = vim.lsp.buf_attach_client
  if mode == "legacy" or mode == "legacy-retain" then
    -- Exact old timing, with real core/client: synchronous detach in LspAttach.
    vim.api.nvim_create_autocmd("LspAttach", { callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == "clangd" and vim.api.nvim_buf_get_name(args.buf):find("://", 1, true) then
        event("legacy_sync_detach", { buf = args.buf })
        vim.lsp.buf_detach_client(args.buf, client.id)
      end
    end })
  elseif mode ~= "unguarded" then
    workaround.apply()
  end
  local virtual = require("codediff.core.virtual_file")
  virtual.setup()
  local loaded = {}
  vim.api.nvim_create_autocmd("User", { pattern = "CodeDiffVirtualFileLoaded", callback = function(args)
    loaded[args.data.buf] = true
  end })
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/a.cpp"))
  local source = vim.api.nvim_get_current_buf()
  local id = vim.lsp.start({ name = "clangd", cmd = { clangd, "-j=1", "--background-index=false", "--clang-tidy=false" },
    root_dir = repo, capabilities = vim.lsp.protocol.make_client_capabilities() }, { bufnr = source })
  assert(id, "failed to start real clangd")
  local client = vim.lsp.get_client_by_id(id)
  local real_notify = client.notify
  client.notify = function(self, method, params)
    local uri = params and params.textDocument and params.textDocument.uri
    if uri then report.text_document_traffic[#report.text_document_traffic + 1] = { method = method, uri = uri } end
    return real_notify(self, method, params)
  end
  if mode == "fixed-late-rename" then
    -- Real startup remains asynchronous: attach a file, then have the real
    -- CodeDiff loader repurpose the same buffer before initialize completes.
    assert(not client.initialized, "late-rename control missed initialization window")
    report.attached_before_rename = client.attached_buffers[source] == true
    vim.api.nvim_buf_set_name(source, virtual.create_url(repo, ":0", "a.cpp"))
    vim.api.nvim_exec_autocmds("BufReadCmd", { buffer = source })
    event("rename_before_initialize", { buf = source, uri = vim.uri_from_bufnr(source) })
    assert(vim.wait(10000, function() return client.initialized and loaded[source] end, 10), "late revision load timeout")
    vim.wait(100, function() return false end, 10)
    report.attached_after_initialize = client.attached_buffers[source] == true
    report.revision_content = vim.api.nvim_buf_get_lines(source, 0, -1, false)
    report.virtual_did_open_count = 0
    for _, record in ipairs(report.text_document_traffic) do
      if record.method == "textDocument/didOpen" and record.uri:match("^codediff:") then
        report.virtual_did_open_count = report.virtual_did_open_count + 1
      end
    end
    local ordinary = vim.fn.bufadd(repo .. "/b.cpp")
    vim.fn.bufload(ordinary)
    report.normal_file_attach = vim.lsp.buf_attach_client(ordinary, id)
    report.normal_file_still_attached = client.attached_buffers[ordinary] == true
    report.delete_ok, report.delete_error = pcall(vim.api.nvim_buf_delete, source, { force = true })
    report.v_errmsg = vim.v.errmsg
    client:stop(true)
    vim.wait(1000, function() return client:is_stopped() end, 10)
    workaround.disable()
    vim.notify = notify
    io.write("REVIEW_H_REPORT=" .. vim.json.encode(report) .. "\n")
    assert(report.attached_before_rename, "late-rename control never attached the original file")
    assert(not report.attached_after_initialize, "deferred initialization attached a CodeDiff URI")
    assert(report.virtual_did_open_count == 0, "deferred initialization sent virtual didOpen")
    assert(report.revision_content[1] == "int alpha() { return 1; }", "real CodeDiff content did not load")
    assert(report.normal_file_attach and report.normal_file_still_attached, "normal file attachment regressed")
    assert(report.delete_ok and not report.v_errmsg:find("_changetracking.lua", 1, true), "late buffer delete crashed")
    return report
  end
  assert(vim.wait(10000, function() return client.initialized end, 10), "clangd initialize timeout")
  -- Build a genuine CodeDiff session, using its real virtual BufReadCmd loader.
  local config = function(file)
    return { git_root = repo, original_revision = ":0", modified_revision = "WORKING", layout = "side-by-side",
      original = { absolute = repo .. "/" .. file, relative = file },
      modified = { absolute = repo .. "/" .. file, relative = file } }
  end
  local view = require("codediff.ui.view")
  local lifecycle = require("codediff.ui.lifecycle")
  view.create(config("a.cpp"))
  local tab = vim.api.nvim_get_current_tabpage()
  assert(vim.wait(10000, function() return lifecycle.get_session(tab) ~= nil end, 10), "CodeDiff session timeout")
  local old = lifecycle.get_session(tab).original_bufnr
  assert(vim.wait(10000, function() return loaded[old] end, 10), "CodeDiff revision load timeout")
  report.virtual_before_attach = { buf = old, name = vim.api.nvim_buf_get_name(old), filetype = vim.bo[old].filetype,
    buftype = vim.bo[old].buftype, lines = vim.api.nvim_buf_get_lines(old, 0, -1, false), clients = #vim.lsp.get_clients({ bufnr = old }) }
  event("explicit_buf_attach_client", { buf = old, uri = vim.uri_from_bufnr(old) })
  local attach = mode == "fixed-fallback" and native_attach or vim.lsp.buf_attach_client
  local guarded_on_attach
  if mode == "fixed-fallback" then
    guarded_on_attach = client.on_attach
    client.on_attach = getmetatable(client).__index.on_attach
    report.bypassed_client_on_attach_guard = true
  end
  report.attach_return = attach(old, id)
  if guarded_on_attach then client.on_attach = guarded_on_attach end
  report.bypassed_pre_attach_guard = mode == "fixed-fallback"
  report.attached_immediate = client.attached_buffers[old] == true
  vim.wait(100, function() return false end, 10)
  report.attached_after_schedule = client.attached_buffers[old] == true
  if mode == "unguarded" or mode == "legacy" or mode == "legacy-retain" then
    report.highlight_request = { method = "textDocument/documentHighlight", uri = vim.uri_from_bufnr(old) }
    local response = client:request_sync("textDocument/documentHighlight", {
      textDocument = { uri = report.highlight_request.uri }, position = { line = 0, character = 4 } }, 3000, old)
    report.highlight_response = response
  end
  -- Same installed plugin update path as explorer selection, including its
  -- pcall(nvim_buf_delete) at side_by_side/update.lua:305.
  if mode == "legacy-retain" then
    -- Separate control: defer wipe until the plugin's explicit delete branch.
    -- The default-nowrite/wipe control above fails earlier in edit_in_place.
    vim.bo[old].bufhidden = "hide"
    report.retain_until_explicit_delete = true
  end
  local switch_ok, switch_result = xpcall(function() return view.update(tab, config("b.cpp")) end, debug.traceback)
  report.switch_return = switch_ok and switch_result or false
  report.switch_error = not switch_ok and switch_result or nil
  vim.wait(300, function() return false end, 10)
  report.old_buffer_valid = vim.api.nvim_buf_is_valid(old)
  report.source_still_attached = client.attached_buffers[source] == true
  report.changetracking_crash = false
  if report.switch_error and report.switch_error:find("_changetracking.lua", 1, true) then
    report.changetracking_crash = true
  end
  for _, msg in ipairs(report.messages) do
    if msg.text:find("_changetracking.lua", 1, true) and msg.text:find("buf_state", 1, true) then
      report.changetracking_crash = true
    end
  end
  -- vim callback errors use nvim_err_writeln rather than vim.notify on 0.11.
  report.v_errmsg = vim.v.errmsg
  if report.v_errmsg:find("_changetracking.lua", 1, true) then report.changetracking_crash = true end
  report.virtual_traffic_count = 0
  for _, record in ipairs(report.text_document_traffic) do
    if record.uri:match("^codediff:") then report.virtual_traffic_count = report.virtual_traffic_count + 1 end
  end
  client:stop(true)
  vim.wait(1000, function() return client:is_stopped() end, 10)
  workaround.disable()
  vim.notify = notify
  io.write("REVIEW_H_REPORT=" .. vim.json.encode(report) .. "\n")
  if mode == "fixed" or mode == "fixed-fallback" then
    if mode == "fixed" then
      assert(report.attach_return == false and not report.attached_immediate, "virtual attachment reached native clangd")
      assert(report.virtual_traffic_count == 0, "blocked revision emitted textDocument traffic")
      assert(#report.messages == 0, "normal guarded path emitted an LSP warning")
    end
    assert(not report.attached_after_schedule, "clangd remained attached to CodeDiff virtual buffer")
    assert(not report.changetracking_crash, "buffer switch triggered changetracking crash")
    assert(report.switch_return, "CodeDiff did not complete its file switch")
    assert(not report.old_buffer_valid, "CodeDiff failed to remove old revision buffer")
    assert(report.source_still_attached, "normal file buffer lost its real clangd client")
    if mode == "fixed-fallback" then
      assert(report.attached_immediate, "fallback control did not enter native attach")
      assert(report.virtual_traffic_count > 0, "fallback control did not send native didOpen")
    end
  end
  return report
end

if vim.env.NVIM_REVIEW_H_CHILD == "1" then
  local ok, err = xpcall(function() integration(vim.env.NVIM_REVIEW_H_MODE or "fixed") end, debug.traceback)
  if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
  return
end

local t = require("tests.harness")
local cfg = t.bootstrap()
t.describe("workarounds: real clangd non-file CodeDiff lifecycle", function()
  local clangd, codediff = native_paths()
  if vim.fn.executable(clangd) ~= 1 or vim.fn.executable("git") ~= 1 or vim.fn.isdirectory(codediff) ~= 1 then
    t.skip("virtual revision attachment and switch are safe", "requires installed real clangd, Git and CodeDiff", { native = true })
    return
  end
  for _, mode in ipairs({ "fixed", "fixed-fallback", "fixed-late-rename" }) do
    t.it(mode .. ": virtual attachment and switch are safe; file client remains attached", function()
      local result = vim.system({ vim.v.progpath, "--headless", "-l", cfg .. "/tests/cases/workarounds_non_file_uri_spec.lua" }, {
        text = true, env = { NVIM_REVIEW_H_CHILD = "1", NVIM_REVIEW_H_MODE = mode, UE_CLANGD = clangd },
      }):wait(30000)
      t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
      t.assert_contains(result.stdout, "REVIEW_H_REPORT=")
      t.assert_false((result.stderr or ""):find("_changetracking.lua", 1, true), result.stderr)
    end)
  end
end)
