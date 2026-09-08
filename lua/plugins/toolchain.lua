-- Tool versions are provisioned outside Neovim (CONSTRAINTS P2/C1).
-- Clear inherited lists in opts functions: LazyVim extends ensure_installed,
-- so a plain empty table would retain its stylua/shfmt/server defaults.
local function manual_install_only(_, opts)
  opts.ensure_installed = {}
  return opts
end

return {
  {
    "mason-org/mason.nvim",
    opts = manual_install_only,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    opts = manual_install_only,
  },
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      for name, server in pairs(opts.servers or {}) do
        if type(server) ~= "table" then
          server = { enabled = server ~= false }
          opts.servers[name] = server
        end
        -- LazyVim derives its install list from each individual server;
        -- setting only the '*' defaults does not disable that installation.
        server.mason = false
      end
      return opts
    end,
  },
}
