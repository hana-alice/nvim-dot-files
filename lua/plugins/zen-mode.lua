-- Zen Mode: distraction-free editor pane.
--
-- Mapped to <leader>z (uncommon — verified no collision in lua/ on
-- 2026-04-27). Sized for a typical UE source file (max 120-col guideline
-- + 10 col gutter slack = 130). On Neovide we keep cmdline visible
-- because <leader>/ pickers and :UE* commands rely on it for feedback.
return {
  {
    "folke/zen-mode.nvim",
    cmd = { "ZenMode" },
    keys = {
      { "<leader>z", function() require("zen-mode").toggle() end, desc = "Zen Mode toggle" },
    },
    opts = {
      window = {
        backdrop = 0.95,
        width = 130,
        height = 1,
        options = {
          number = false,
          relativenumber = false,
          cursorline = false,
          cursorcolumn = false,
          signcolumn = "no",
          list = false,
        },
      },
      plugins = {
        options = {
          enabled = true,
          ruler = false,
          showcmd = false,
          laststatus = 0,
        },
        twilight = { enabled = false },
        gitsigns = { enabled = false },
        tmux = { enabled = false },
      },
    },
  },
}
