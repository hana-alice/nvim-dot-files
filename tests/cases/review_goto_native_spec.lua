local t = require("tests.harness")
local cfg = t.bootstrap()

local native = [=[
local cfg, root, plugins, clangd, reuse_git, compiler = unpack(arg)
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind)
  if kind == "cache" or kind == "state" or kind == "log" then return root .. "/" .. kind end
  return stdpath(kind)
end
for _, kind in ipairs({"cache", "state", "log", "logs"}) do vim.fn.mkdir(root .. "/" .. kind, "p") end
vim.env.NVIM_UE_LOG_DIR=root .. "/logs"
vim.env.NVIM_UE_PROBE_PATH=root .. "/probes.json"
vim.env.NVIM_LOG_FILE=root .. "/log/nvim.log"
vim.opt.rtp:prepend(cfg)
package.path=cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend(plugins .. "/codediff.nvim")
require("codediff.config").setup({})
require("codediff.core.virtual_file").setup()
local api=vim.api
local function write(file, lines) assert(vim.fn.writefile(lines, root .. "/" .. file)==0) end
local function git(...)
  local cmd={"git", "-C", root}
  vim.list_extend(cmd,{...})
  local result=vim.system(cmd,{text=true}):wait(5000)
  assert(result.code==0,(result.stderr or "") .. (result.stdout or ""))
  return vim.trim(result.stdout)
end
write("defs.hpp", {"inline int review_target() { return 42; }"})
write("main.cpp", {'#include "defs.hpp"', "int run() { return review_target(); }"})
write("compile_commands.json", {vim.json.encode({{
  directory=root, file=root .. "/main.cpp",
  arguments={compiler, "-std=c++20", "-c", root .. "/main.cpp"},
}})})
local old, new
if reuse_git and reuse_git ~= "" then
  -- A task can forbid Git writes while still requiring native range review.
  -- Copy only fixture metadata; all Git invocations in this branch are read-only.
  local function copy_tree(source, destination)
    vim.fn.mkdir(destination, "p")
    for name, kind in vim.fs.dir(source) do
      if kind == "directory" then copy_tree(source .. "/" .. name, destination .. "/" .. name)
      else assert(vim.uv.fs_copyfile(source .. "/" .. name, destination .. "/" .. name)) end
    end
  end
  copy_tree(reuse_git .. "/.git", root .. "/.git")
  old, new = git("rev-parse", "HEAD^"), git("rev-parse", "HEAD")
  write("main.cpp", vim.split(git("show", new .. ":main.cpp"), "\n", {plain=true}))
else
  git("init", "--quiet")
  git("add", "main.cpp", "defs.hpp", "compile_commands.json")
  git("-c", "user.name=Review fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Establish isolated navigation evidence")
  old=git("rev-parse", "HEAD")
  write("main.cpp", {"// second revision", '#include "defs.hpp"', "int run() { return review_target(); }"})
  git("add", "main.cpp")
  git("-c", "user.name=Review fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Exercise revision coordinate mapping")
  new=git("rev-parse", "HEAD")
end
local ue_context={engine_root=root, project_root=root, state={}, paths={active_cdb=root .. "/compile_commands.json", cdb_shards_dir=root .. "/shards"}}
package.loaded["ue"]={resolve_context=function() return ue_context end,
  clangd_cmd=function() return {clangd} end,
  semantic_index_snapshot=function() return {readiness="ready", freshness="fresh", complete=true, generation_id="review-native", artifact_fingerprint="fixture"} end}
local command={clangd, "--background-index", "-j=1", "--log=verbose", "--compile-commands-dir=" .. root}
vim.lsp.config("clangd", {name="clangd", cmd=command, filetypes={"cpp"}, root_dir=function(_, cb) cb(root) end})
local ready=false
require("codediff.ui.view").create({git_root=root,
  original={relative="main.cpp",absolute=root .. "/main.cpp"},
  modified={relative="main.cpp",absolute=root .. "/main.cpp"},
  original_revision=old,modified_revision=new},"cpp",function() ready=true end)
assert(vim.wait(5000,function() return ready end,10),"CodeDiff range failed")
local reviewtab=api.nvim_get_current_tabpage()
local layout=require("utils.layout")
local session=assert(require("codediff.ui.lifecycle").get_session(reviewtab))
layout.track_review(reviewtab,session)
local left,right=session.original_win,session.modified_win
local leftbuf,rightbuf=api.nvim_win_get_buf(left),api.nvim_win_get_buf(right)
assert(api.nvim_buf_get_name(leftbuf):match("^codediff://"),"not a revision buffer")
assert(api.nvim_buf_get_name(rightbuf):match("^codediff://"),"not a revision range")
local messages={}
local notify=vim.notify
vim.notify=function(message,level,opts) messages[#messages+1]=message; notify(message,level,opts) end
local traces={}
local Client=require("vim.lsp.client")
local request=Client.request
Client.request=function(client, method, params, handler, buf)
  if method=="textDocument/symbolInfo" or method=="textDocument/definition" then
    local name=api.nvim_buf_get_name(buf)
    assert(not name:match("^codediff://"),"semantic request sent to revision")
    assert(vim.lsp.buf_is_attached(buf,client.id),"semantic request sent to detached real file")
    traces[#traces+1]={method=method,buf=buf,file=name,client=client.id,root=client.config.root_dir}
  end
  return request(client,method,params,handler,buf)
end
local fallback=require("utils.lsp_fallback")
local results={}
local function stopped_all()
  for _, client in ipairs(vim.lsp.get_clients({name="clangd",_uninitialized=true})) do client:stop(true) end
  assert(vim.wait(3000,function() return #vim.lsp.get_clients({name="clangd",_uninitialized=true})==0 end,10))
end
local function go(label)
  api.nvim_set_current_tabpage(reviewtab)
  api.nvim_set_current_win(left)
  api.nvim_win_set_cursor(left,{2,19})
  local rightcursor=api.nvim_win_get_cursor(right)
  local before=#traces
  local started=vim.uv.hrtime()
  fallback.definition()
  assert(vim.wait(12000,function()
    return vim.fs.normalize(api.nvim_buf_get_name(0))==root .. "/defs.hpp"
  end,10),label .. ": wrong destination " .. api.nvim_buf_get_name(0) .. " " .. vim.inspect(messages))
  assert(api.nvim_get_current_tabpage()~=reviewtab,"gd did not leave review")
  assert(layout.current_group().kind=="normal","gd destination not normal")
  assert(api.nvim_win_get_buf(left)==leftbuf and api.nvim_win_get_buf(right)==rightbuf,"gd overwrote review")
  assert(vim.deep_equal(api.nvim_win_get_cursor(left),{2,19}),"gd moved revision cursor")
  assert(vim.deep_equal(api.nvim_win_get_cursor(right),rightcursor),"gd moved paired cursor")
  assert(#api.nvim_tabpage_list_wins(reviewtab)==2,"gd created review browser split")
  assert(#traces>before,"real semantic requests missing")
  results[#results+1]={scenario=label,elapsed_ms=(vim.uv.hrtime()-started)/1000000,requests=#traces-before,destination=api.nvim_buf_get_name(0)}
  assert(layout.back(),"UELayoutBack missing review history")
  assert(api.nvim_get_current_win()==left,"back did not restore source review window")
end
go("cold-start")
local hidden=vim.fn.bufnr(root .. "/main.cpp")
assert(hidden>0 and api.nvim_buf_is_loaded(hidden),"real source not loaded")
assert(#vim.fn.win_findbuf(hidden)==0,"real source must be hidden after definition")
go("hidden-loaded")
stopped_all()
local wrongroot=root .. "/wrong-root"
vim.fn.mkdir(wrongroot,"p")
local wrongbuf=api.nvim_create_buf(true,false)
api.nvim_buf_set_name(wrongbuf,wrongroot .. "/other.cpp")
vim.bo[wrongbuf].filetype="cpp"
local wrongid=assert(vim.lsp.start({name="clangd",cmd=command,root_dir=wrongroot},{bufnr=wrongbuf}))
assert(vim.wait(3000,function() return vim.lsp.get_client_by_id(wrongid).initialized end,10),"wrong-root client failed")
assert(vim.lsp.buf_attach_client(hidden,wrongid),"wrong-root fixture did not attach source")
go("different-root-running")
assert(not vim.lsp.buf_is_attached(hidden,wrongid),"wrong-root client stayed attached to source")
stopped_all()
local failed_exit
local failed=assert(vim.lsp.start({name="clangd",cmd={clangd,"--task-m-invalid-option"},root_dir=wrongroot,
  on_exit=function(code) failed_exit=code end},{bufnr=wrongbuf}))
assert(vim.wait(3000,function() return failed_exit~=nil end,10),"failed clangd did not exit")
assert(failed_exit~=0,"invalid clangd option unexpectedly succeeded")
go("exited-client-hidden-buffer")
stopped_all()
local timeout_client=assert(vim.lsp.start({name="clangd",cmd=command,root_dir=wrongroot},{bufnr=wrongbuf}))
assert(vim.wait(3000,function() return vim.lsp.get_client_by_id(timeout_client).initialized end,10))
vim.lsp.config("clangd",{root_dir=function() end})
api.nvim_set_current_tabpage(reviewtab)
api.nvim_set_current_win(left)
api.nvim_win_set_cursor(left,{2,19})
local before=#traces
local callbacks=0
assert(require("utils.review_goto").definition(function() callbacks=callbacks+1 end,{timeout_ms=80}))
assert(vim.wait(1000,function() return messages[#messages] and messages[#messages]:find("附加超时",1,true) end,10),"timeout notification missing")
assert(callbacks==0 and #traces==before,"timeout dispatched semantic work")
assert(messages[#messages]:find("ms",1,true) and messages[#messages]:find("client 状态",1,true),"timeout lacks evidence")
assert(messages[#messages]:find("wrong-root",1,true) and messages[#messages]:find("attached=false",1,true),"timeout lacks running-client state")
write("result.json",{vim.json.encode({commits={old,new},scenarios=results,requests=traces,failed_client={id=failed,exit_code=failed_exit},timeout=messages[#messages]})})
stopped_all()
io.write("NATIVE_REVIEW_GD_OK\n")
vim.cmd("qa!")
]=]

t.describe("review_goto real CodeDiff range + clangd", function()
  local plugins = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")
  -- The installed LLVM may live anywhere (CI installs it under the runner temp).
  local clangd = vim.env.UE_CLANGD or vim.fn.exepath("clangd")
  if clangd == "" then clangd = "C:/Program Files/LLVM/bin/clangd.exe" end
  local compiler = vim.fs.joinpath(vim.fs.dirname(clangd), "clang++" .. (vim.fn.has("win32") == 1 and ".exe" or ""))
  if vim.fn.executable(clangd) ~= 1 or vim.fn.executable(compiler) ~= 1
    or not vim.uv.fs_stat(plugins .. "/codediff.nvim") then
    t.skip("cold/hidden/wrong-root/exited/timeout end-to-end", "installed native tools unavailable", { native = true })
    return
  end
  t.it("cold/hidden/wrong-root/exited revision gd reaches another file and timeout stays fail-closed", function()
    local runroot = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(runroot, "p")
    local script = runroot .. "/review-native.lua"
    vim.fn.writefile(vim.split(native, "\n", { plain = true }), script)
    local process = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE",
      "-l", script, cfg, runroot, plugins, clangd, vim.env.NVIM_TEST_REVIEW_GIT_FIXTURE or "", compiler }, { text = true,
      env = { NVIM_LOG_FILE = runroot .. "/nvim.log", XDG_STATE_HOME = runroot .. "/state" } }):wait(35000)
    t.assert_eq(process.code, 0, (process.stderr or "") .. (process.stdout or ""))
    t.assert_contains(process.stdout, "NATIVE_REVIEW_GD_OK")
    local result = vim.json.decode(table.concat(vim.fn.readfile(runroot .. "/result.json"), "\n"))
    t.assert_eq(#result.scenarios, 4)
    t.assert_true(result.commits[1] ~= result.commits[2])
    -- Retain task evidence; do not remove fixture repositories or logs.
    local evidence = vim.env.NVIM_TEST_REVIEW_GIT_FIXTURE and "n1-gd-native-result.json" or "m-gd-native-result.json"
    vim.fn.mkdir(cfg .. "/.tmp/review-gd", "p")
    vim.fn.writefile({vim.json.encode({root=runroot,result=result})}, cfg .. "/.tmp/review-gd/" .. evidence)
  end)
end)
