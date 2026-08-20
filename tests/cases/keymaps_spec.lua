-- tests/cases/keymaps_spec.lua
-- 快捷键绑定回归。
-- 前置：headless `-l` 不自动加载 LazyVim 的 config.keymaps，需手动 dofile；
--       且必须先设 leader、再 require("ue").setup() 让命令/前缀就绪。

local t = require("tests.harness")
local cfg = t.bootstrap()

-- 固定前置序（探针验证）：leader → ue.setup → dofile(keymaps)。
vim.g.mapleader = " "
vim.g.maplocalleader = " "
require("ue").setup()
local ok_km, km_err = pcall(dofile, cfg .. "/lua/config/keymaps.lua")

local is_windows = require("utils.platform").is_windows

t.describe("keymaps: 加载", function()
  t.it("config/keymaps.lua 可 dofile 成功", function()
    t.assert_true(ok_km, "dofile keymaps 失败: " .. tostring(km_err))
  end)

  t.it("VimEnter 前加载也会立即安装 UE runtime overrides", function()
    local command = table.concat({
      "local did = vim.v.vim_did_enter",
      ("dofile(%q)"):format(cfg .. "/lua/config/keymaps.lua"),
      "local mapped = vim.fn.maparg('<leader>ub', 'n') ~= ''",
      "vim.api.nvim_out_write(('EARLY_KEYMAP did=%d mapped=%s\\n'):format(did, tostring(mapped)))",
    }, "; ")
    local result = vim.system({
      vim.v.progpath,
      "--headless",
      "-i", "NONE",
      "-u", cfg .. "/init.lua",
      "-c", "lua " .. command,
      "-c", "qa!",
    }, {
      text = true,
      env = vim.tbl_extend("force", vim.fn.environ(), {
        NVIM_CORE_HEALTH_NO_MUTATE = "1",
      }),
    }):wait(20000)

    local output = (result.stdout or "") .. (result.stderr or "")
    t.assert_eq(result.code, 0, output ~= "" and output or "child nvim failed")
    t.assert_contains(output, "EARLY_KEYMAP did=0 mapped=true")
  end)
end)

t.describe("keymaps: DAP 功能键多模式", function()
  local fkeys = { "<F5>", "<F6>", "<F9>", "<F10>", "<F11>", "<S-F11>" }
  for _, key in ipairs(fkeys) do
    for _, mode in ipairs({ "n", "i", "t", "v" }) do
      t.it(key .. " 在 " .. mode .. " 模式有映射", function()
        t.assert_true(t.get_keymap(mode, key) ~= nil,
          key .. " (" .. mode .. ") 未绑定")
      end)
    end
  end

  t.it("<F5> → UEDAPContinue", function()
    local m = t.get_keymap("n", "<F5>")
    t.assert_true(m ~= nil, "<F5> 未绑定")
    t.assert_contains(m.rhs or "", "UEDAPContinue")
  end)
  t.it("<F9> → UEDAPToggleBreakpoint", function()
    local m = t.get_keymap("n", "<F9>")
    t.assert_true(m ~= nil, "<F9> 未绑定")
    t.assert_contains(m.rhs or "", "UEDAPToggleBreakpoint")
  end)
  t.it("<F10> → UEDAPStepOver", function()
    local m = t.get_keymap("n", "<F10>")
    t.assert_true(m ~= nil, "<F10> 未绑定")
    t.assert_contains(m.rhs or "", "UEDAPStepOver")
  end)
end)

t.describe("keymaps: leader 代表键", function()
  local function rhs_of(mode, lhs)
    local m = t.get_keymap(mode, lhs)
    return m and (m.rhs or "") or nil
  end

  t.it("<leader>? → UECheatsheet（可搜索快捷键帮助）", function()
    local r = rhs_of("n", "<leader>?")
    t.assert_true(r ~= nil, "<leader>? 未绑定")
    t.assert_contains(r, "UECheatsheet")
  end)
  t.it("<leader>uW → WindowTitle（命名系统窗口）", function()
    local r = rhs_of("n", "<leader>uW")
    t.assert_true(r ~= nil, "<leader>uW 未绑定")
    t.assert_contains(r, "WindowTitle")
  end)

  t.it("<leader>db → UEDAPToggleBreakpoint", function()
    local r = rhs_of("n", "<leader>db")
    t.assert_true(r ~= nil, "<leader>db 未绑定")
    t.assert_contains(r, "UEDAPToggleBreakpoint")
  end)
  t.it("<leader>dc → UEDAPContinue", function()
    local r = rhs_of("n", "<leader>dc")
    t.assert_true(r ~= nil, "<leader>dc 未绑定")
    t.assert_contains(r, "UEDAPContinue")
  end)
  t.it("<leader>da 含 UEDAPAttach", function()
    local r = rhs_of("n", "<leader>da")
    t.assert_true(r ~= nil, "<leader>da 未绑定")
    t.assert_contains(r, "UEDAPAttach")
  end)
  for _, lhs in ipairs({ "<leader>vv", "<leader>vb", "<leader>vg" }) do
    t.it(lhs .. " 存在 (sidebar)", function()
      t.assert_true(t.get_keymap("n", lhs) ~= nil, lhs .. " 未绑定")
    end)
  end
  t.it("<leader>uA → UESetAndroidDevice", function()
    local r = rhs_of("n", "<leader>uA")
    t.assert_true(r ~= nil, "<leader>uA 未绑定")
    t.assert_contains(r, "UESetAndroidDevice")
  end)
  t.it("<leader>ub → UEBuild (runtime override)", function()
    local r = rhs_of("n", "<leader>ub")
    t.assert_true(r ~= nil, "<leader>ub 未绑定")
    t.assert_contains(r, "UEBuild")
  end)
  t.it("<leader>ui → UEInstall (按当前平台分派)", function()
    local r = rhs_of("n", "<leader>ui")
    t.assert_true(r ~= nil, "<leader>ui 未绑定")
    t.assert_contains(r, "UEInstall")
    t.assert_false(r:find("UEInstallAndroid", 1, true) ~= nil)
  end)
  t.it("<leader>us → UEBuildAndroidSO (跳过 APK)", function()
    local r = rhs_of("n", "<leader>us")
    t.assert_true(r ~= nil, "<leader>us 未绑定")
    t.assert_contains(r, "UEBuildAndroidSO")
  end)
  t.it("<leader>uq → UEDeployAndroidSO (快速替换 SO)", function()
    local r = rhs_of("n", "<leader>uq")
    t.assert_true(r ~= nil, "<leader>uq 未绑定")
    t.assert_contains(r, "UEDeployAndroidSO")
  end)
  t.it("<leader>ul → UELaunch (runtime override)", function()
    local r = rhs_of("n", "<leader>ul")
    t.assert_true(r ~= nil, "<leader>ul 未绑定")
    t.assert_contains(r, "UELaunch")
  end)
  t.it("<leader>uN → NotificationHistory (runtime override)", function()
    local r = rhs_of("n", "<leader>uN")
    t.assert_true(r ~= nil, "<leader>uN 未绑定")
    t.assert_contains(r, "NotificationHistory")
  end)
  for _, lhs in ipairs({ "<leader>ut", "<leader>uC" }) do
    t.it(lhs .. " → ThemePicker (runtime override)", function()
      local r = rhs_of("n", lhs)
      t.assert_true(r ~= nil, lhs .. " 未绑定")
      t.assert_contains(r, "ThemePicker")
    end)
  end
  t.it("<leader>X → Tasks", function()
    local r = rhs_of("n", "<leader>X")
    t.assert_true(r ~= nil, "<leader>X 未绑定")
    t.assert_contains(r, "Tasks")
  end)
  t.it("<leader>Xs → TaskStop", function()
    local r = rhs_of("n", "<leader>Xs")
    t.assert_true(r ~= nil, "<leader>Xs 未绑定")
    t.assert_contains(r, "TaskStop")
  end)
  t.it("<leader>XA → TaskStopAll", function()
    local r = rhs_of("n", "<leader>XA")
    t.assert_true(r ~= nil, "<leader>XA 未绑定")
    t.assert_contains(r, "TaskStopAll")
  end)
end)

t.describe("keymaps: 核心编辑/导航键", function()
  t.it("gd 存在", function() t.assert_true(t.get_keymap("n", "gd") ~= nil) end)
  t.it("gr 存在", function() t.assert_true(t.get_keymap("n", "gr") ~= nil) end)
  t.it("<C-LeftMouse> 不把 dotted member 当文件交给 gf", function()
    local mapping = t.get_keymap("n", "<C-LeftMouse>")
    t.assert_true(mapping ~= nil and type(mapping.callback) == "function")

    local original_buf = vim.api.nvim_get_current_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "[ParallelRenderCommandEncoder.GetPtr() setLabel:@\"fixture\"]",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })

    local original_fallback = package.loaded["utils.lsp_fallback"]
    local original_normal = vim.cmd.normal
    local definitions = 0
    local normal_calls = 0
    package.loaded["utils.lsp_fallback"] = {
      definition = function() definitions = definitions + 1 end,
    }
    vim.cmd.normal = function()
      normal_calls = normal_calls + 1
    end
    vim.v.errmsg = ""
    mapping.callback()
    local errmsg = vim.v.errmsg
    vim.cmd.normal = original_normal
    package.loaded["utils.lsp_fallback"] = original_fallback

    vim.api.nvim_set_current_buf(original_buf)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    t.assert_eq(normal_calls, 0, "dotted member must not attempt gf")
    t.assert_eq(definitions, 1, "dotted member must route directly to semantic definition")
    t.assert_false(errmsg:find("E447", 1, true) ~= nil,
      "smart mouse jump must not emit a failed file lookup before gd")
  end)
  t.it("gc (n) 存在", function() t.assert_true(t.get_keymap("n", "gc") ~= nil) end)
  t.it("gc (x) 存在", function() t.assert_true(t.get_keymap("x", "gc") ~= nil) end)
  t.it("gcc 存在", function() t.assert_true(t.get_keymap("n", "gcc") ~= nil) end)

  if is_windows then
    t.it("cmdline <C-v> 粘贴自系统剪贴板 (<C-R>+)", function()
      local m = t.get_keymap("c", "<C-v>")
      t.assert_true(m ~= nil, "cmdline <C-v> 未绑定")
      -- nvim 规范化存储为大写 <C-R>+；大小写不敏感比较。
      t.assert_contains((m.rhs or ""):upper(), "<C-R>+")
    end)
    t.it("insert <C-v> 粘贴自系统剪贴板 (<C-R><C-O>+)", function()
      local m = t.get_keymap("i", "<C-v>")
      t.assert_true(m ~= nil, "insert <C-v> 未绑定")
      t.assert_contains((m.rhs or ""):upper(), "<C-R><C-O>+")
    end)
  end
end)
