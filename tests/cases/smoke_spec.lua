-- tests/cases/smoke_spec.lua
-- 配置加载冒烟：关键模块可 require、ue.setup() 注册命令不报错。

local t = require("tests.harness")
t.bootstrap()

t.describe("smoke: 核心模块加载", function()
  t.it("require('ue') 返回 table", function()
    t.assert_type(require("ue"), "table")
  end)
  t.it("require('ue.config') 返回 table", function()
    t.assert_type(require("ue.config"), "table")
  end)
  t.it("require('utils.platform') 返回 table", function()
    t.assert_type(require("utils.platform"), "table")
  end)
  t.it("require('utils.android_device') 返回 table", function()
    t.assert_type(require("utils.android_device"), "table")
  end)
  t.it("require('utils.log') 返回 table", function()
    t.assert_type(require("utils.log"), "table")
  end)
end)

t.describe("smoke: clangd capabilities", function()
  t.it("不再发送 clangd 已弃用的 offsetEncoding 扩展", function()
    local path = vim.fn.stdpath("config") .. "/lua/plugins/ue.lua"
    local f = assert(io.open(path, "rb"))
    local source = f:read("*a")
    f:close()
    t.assert_false(source:find("offsetEncoding", 1, true) ~= nil,
      "Neovim 已通过 LSP 3.17 general.positionEncodings 协商编码")
  end)

  t.it("clangd 启动时用原生 LSP 已解析的 root 生成 scoped CDB 命令", function()
    local path = vim.fn.stdpath("config") .. "/lua/plugins/ue.lua"
    local specs = dofile(path)
    local lsp_spec = specs[2]
    local opts = { servers = {} }
    lsp_spec.opts(nil, opts)

    local clangd = opts.servers.clangd
    t.assert_type(clangd.cmd, "function",
      "原生 vim.lsp 不执行 on_new_config；cmd 必须在 root_dir 解析后动态生成")
    t.assert_nil(clangd.on_new_config,
      "nvim-lspconfig 原生配置尚不支持 on_new_config")

    local ue = require("ue")
    local old_clangd_cmd = ue.clangd_cmd
    local old_rpc_start = vim.lsp.rpc.start
    local seen = {}
    ue.clangd_cmd = function(root_dir)
      seen.root_dir = root_dir
      return { "/fake/clangd", "--compile-commands-dir=/fake/scoped-cdb" }
    end
    vim.lsp.rpc.start = function(cmd, dispatchers, spawn)
      seen.cmd = cmd
      seen.dispatchers = dispatchers
      seen.spawn = spawn
      return { fake = true }
    end

    local config = {
      root_dir = "/fake/UnrealEngine",
      cmd_cwd = "/fake/cwd",
      cmd_env = { SAMPLE = "1" },
      detached = false,
    }
    local dispatchers = { marker = true }
    local ok, rpc = pcall(clangd.cmd, dispatchers, config)
    ue.clangd_cmd = old_clangd_cmd
    vim.lsp.rpc.start = old_rpc_start
    if not ok then error(rpc) end

    t.assert_eq(seen.root_dir, config.root_dir)
    t.assert_eq(seen.dispatchers, dispatchers)
    t.assert_eq(seen.spawn.cwd, config.cmd_cwd)
    t.assert_eq(seen.spawn.env, config.cmd_env)
    t.assert_eq(seen.spawn.detached, config.detached)
    t.assert_contains(seen.cmd, "--compile-commands-dir=/fake/scoped-cdb")
    t.assert_eq(config._ue_resolved_cmd, seen.cmd,
      "exact-command transport must be able to inspect the argv used by the cmd factory")
    t.assert_true(rpc.fake)
  end)
end)

t.describe("smoke: ue.setup() 注册命令", function()
  t.it("ue.setup() 无异常", function()
    require("ue").setup()
  end)

  local cmds = {
    "UEDAPAttach", "UEDAPLaunch", "UEDAPContinue", "UEDAPPause",
    "UEDAPToggleBreakpoint", "UEDAPStepOver", "UEDAPStepIn",
    "UEDAPStepOut", "UEDAPToggleUI", "UEDAPREPL", "UEDAPDiag",
  }
  for _, c in ipairs(cmds) do
    t.it("命令 :" .. c .. " 已注册", function()
      require("ue").setup()
      t.assert_eq(vim.fn.exists(":" .. c), 2, c .. " 未注册")
    end)
  end
end)
