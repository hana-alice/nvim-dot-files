local M = {}
local platform = require("utils.platform")

local function present(value)
  return type(value) == "string" and value ~= ""
end

function M.should_use_osc52(env, host)
  env = env or vim.env
  host = host or {
    allows_osc52 = platform.driver().allows_osc52(),
    is_neovide = vim.g.neovide == true,
  }

  if host.allows_osc52 == false or host.is_neovide then
    return false
  end
  return present(env.SSH_TTY) or present(env.SSH_CONNECTION) or present(env.ZELLIJ)
end

local function paste_from_unnamed()
  return {
    vim.fn.split(vim.fn.getreg(""), "\n"),
    vim.fn.getregtype(""),
  }
end

function M.setup(env, host)
  if not M.should_use_osc52(env, host) then
    return false
  end

  local osc52 = require("vim.ui.clipboard.osc52")
  vim.o.clipboard = "unnamedplus"
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = osc52.copy("+"),
      ["*"] = osc52.copy("*"),
    },
    -- OSC 52 clipboard reads are commonly blocked by terminal emulators.
    -- Keep provider paste synchronous and let bracketed terminal paste handle
    -- Windows -> remote Nvim instead.
    paste = {
      ["+"] = paste_from_unnamed,
      ["*"] = paste_from_unnamed,
    },
  }
  return true
end

return M
