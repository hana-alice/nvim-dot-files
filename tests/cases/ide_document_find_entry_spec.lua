local t = require("tests.harness")
local cfg = t.bootstrap()

-- Entry-only transport seam: the real root mappings/native visual mode deliver
-- arguments to open(). Search and picker behavior are verified separately.
local function native(code)
  local root = assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/document-find-entry-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(root, "p")
  local setup = string.format(
    [[
local cfg, root = %q, %q
vim.opt.rtp:prepend(cfg)
package.path=cfg..'/lua/?.lua;'..cfg..'/lua/?/init.lua;'..package.path
vim.g.mapleader=' '
vim.o.hidden=true;vim.o.swapfile=false;vim.o.shada=''
vim.api.nvim_set_current_dir(root)
local api=vim.api
local calls, notices={},{}
package.loaded['utils.document_find']={open=function(opts) calls[#calls+1]={opts=opts} end}
vim.notify=function(message) notices[#notices+1]=tostring(message) end
dofile(cfg..'/lua/config/keymaps.lua')
local function mapping(mode,key)
  local m=vim.fn.maparg(key,mode,false,true)
  assert(type(m.callback)=='function','actual find callback missing')
  return m.callback
end
local function registers()
  return {unnamed=vim.fn.getreginfo('"'),named=vim.fn.getreginfo('a')}
end
]],
    cfg,
    root
  )
  local script = root .. "/case.lua"
  vim.fn.writefile(vim.split(setup .. code, "\n", { plain = true }), script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }, {
      text = true,
      env = {
        NVIM_UE_PROBE_PATH = root .. "/probes.json",
        NVIM_UE_LOG_DIR = root .. "/logs",
        NVIM_LOG_FILE = root .. "/nvim.log",
        XDG_DATA_HOME = root .. "/data",
        XDG_STATE_HOME = root .. "/state",
        XDG_CACHE_HOME = root .. "/cache",
      },
    })
    :wait(12000)
  vim.fn.delete(root, "rf")
  t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
end

t.describe("document Find root entry native transport", function()
  t.it("sf opens an empty find and sF forwards the actual current word", function()
    native([[
api.nvim_buf_set_lines(0,0,-1,false,{'alpha ThingName beta'})
api.nvim_win_set_cursor(0,{1,8})
local tick=api.nvim_buf_get_changedtick(0)
mapping('n',' sf')()
assert(#calls==1 and calls[1].opts==nil)
mapping('n',' sF')()
assert(#calls==2 and calls[2].opts.text=='ThingName')
assert(api.nvim_buf_get_changedtick(0)==tick and vim.bo.modified)
]])
  end)

  t.it("live visual text preserves literal punctuation and Unicode instead of old marks", function()
    native([[
local literal='[x].*+#%中文'
api.nvim_buf_set_lines(0,0,-1,false,{'aa '..literal..' zz','stale selection'})
api.nvim_buf_set_mark(0,'<',2,0,{});api.nvim_buf_set_mark(0,'>',2,4,{})
vim.fn.setreg('a','retained register');local before=registers()
api.nvim_win_set_cursor(0,{1,3});vim.cmd.normal({args={'v'},bang=true})
api.nvim_win_set_cursor(0,{1,14})
assert(vim.fn.mode()=='v' and vim.fn.getpos("'<")[2]==2)
mapping('x',' sF')()
assert(#calls==1 and calls[1].opts.text==literal)
assert(vim.fn.mode()=='n' and vim.deep_equal(before,registers()))
assert(api.nvim_buf_get_lines(0,0,-1,false)[1]=='aa '..literal..' zz')
]])
  end)

  t.it("a backwards live visual selection uses its current endpoints", function()
    native([[
api.nvim_buf_set_lines(0,0,-1,false,{'aa token.* zz','old range'})
api.nvim_buf_set_mark(0,'<',2,0,{});api.nvim_buf_set_mark(0,'>',2,3,{})
api.nvim_win_set_cursor(0,{1,9});vim.cmd.normal({args={'v'},bang=true})
api.nvim_win_set_cursor(0,{1,3})
mapping('x',' sF')()
assert(#calls==1 and calls[1].opts.text=='token.*')
]])
  end)

  t.it("multiline visual refusal retains the active selection and all registers", function()
    native([[
api.nvim_buf_set_lines(0,0,-1,false,{'first row','second row','old marks'})
api.nvim_buf_set_mark(0,'<',3,0,{});api.nvim_buf_set_mark(0,'>',3,3,{})
vim.fn.setreg('a','retained register')
api.nvim_win_set_cursor(0,{1,2});vim.cmd.normal({args={'v'},bang=true})
api.nvim_win_set_cursor(0,{2,5})
local mode,anchor,cursor,tick=vim.fn.mode(),vim.fn.getpos('v'),api.nvim_win_get_cursor(0),api.nvim_buf_get_changedtick(0)
local before=registers()
mapping('x',' sF')()
assert(#calls==0 and #notices==1 and notices[1]:find('单行',1,true))
assert(vim.fn.mode()==mode and vim.deep_equal(anchor,vim.fn.getpos('v')) and vim.deep_equal(cursor,api.nvim_win_get_cursor(0)))
assert(api.nvim_buf_get_changedtick(0)==tick and vim.deep_equal(before,registers()))
]])
  end)
end)
