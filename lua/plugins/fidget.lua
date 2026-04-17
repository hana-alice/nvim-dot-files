return {
  {
    "j-hui/fidget.nvim",
    event = "VeryLazy",
    opts = function()
      local notification = require("fidget.notification")
      return {
        progress = {
          display = {
            done_ttl = 8,
          },
        },
        notification = {
          configs = {
            default = vim.tbl_extend("force", notification.default_config, {
              ttl = 10,
            }),
          },
        },
      }
    end,
  },
}
