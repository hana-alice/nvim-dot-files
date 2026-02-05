return {
  -- File finding / grep
  { "nvim-lua/plenary.nvim" },
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          -- Respect .gitignore; critical for UE (Intermediate/DDC)
          file_ignore_patterns = {
            "DerivedDataCache/",
            "Intermediate/",
            "Saved/",
            "Binaries/",
          },
        },
      })
    end,
  },

  -- LSP
  { "neovim/nvim-lspconfig" },

  -- Optional but recommended: completion UI (kept minimal)
  { "hrsh7th/nvim-cmp" },
  { "hrsh7th/cmp-nvim-lsp" },
  { "hrsh7th/cmp-buffer" },
  { "hrsh7th/cmp-path" },

  -- Auto pairs: (), {}, [], "", ''
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    opts = { check_ts = true, enable_check_bracket_line = false },
    config = function(_, opts)
      local npairs = require("nvim-autopairs")
      npairs.setup(opts)
      local ok_cmp, cmp = pcall(require, "cmp")
      if ok_cmp then
        local cmp_autopairs = require("nvim-autopairs.completion.cmp")
        cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
      end
    end,
  },
  
  -- Core fzf engine (git plugin, auto build/download binary)

	-- Modern Lua UI for fzf
	
	{
	  "ibhagwan/fzf-lua",
	  dependencies = { "junegunn/fzf" },
	},

  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,      -- main 分支要求：不要 lazy-load
    build = false,
  },

  {
    "numToStr/Comment.nvim",
    opts = {},
    lazy = false,
  },

  -- Surround: ys/cs/ds
  {
    "kylechui/nvim-surround",
    version = "*",
    event = "VeryLazy",
    opts = {},
  },

  -- Formatting (safe even if formatter binaries are missing)
  {
    "stevearc/conform.nvim",
    event = "VeryLazy",
  },



  -- Diagnostics UI (workspace/buffer list, references, etc.)
  {
    "folke/trouble.nvim",
    cmd = { "Trouble" },
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = { focus = true },
  },

  -- Git: signs/blame/hunks
{
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = {
    signs = {
      add = { text = "+" },
      change = { text = "~" },
      delete = { text = "_" },
      topdelete = { text = "‾" },
      changedelete = { text = "~" },
      untracked = { text = "┆" },
    },
    current_line_blame = false, -- toggle via keymap
    watch_gitdir = { follow_files = true },
    attach_to_untracked = true,
    update_debounce = 100,
  },
},

-- Git: full diff UI (great for MR/PR review)
{
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
},

-- Git: :Git status/commit/rebase etc.
{
  "tpope/vim-fugitive",
  cmd = { "Git", "G", "Gdiffsplit", "Gvdiffsplit", "Gwrite", "Gread", "Gblame" },

},

-- Git: LazyGit integration
{
  "kdheepak/lazygit.nvim",
  cmd = { "LazyGit", "LazyGitConfig", "LazyGitCurrentFile", "LazyGitFilter", "LazyGitFilterCurrentFile" },
  dependencies = { "nvim-lua/plenary.nvim" },
},

  { "folke/tokyonight.nvim", lazy = false, priority = 1000 },

  {
    "mikavilpas/yazi.nvim",
    version = "*",
    event = "VeryLazy",
    dependencies = 
    {
      { "nvim-lua/plenary.nvim", lazy = true },
    },
  },
  {
    "p00f/clangd_extensions.nvim",
    ft = { "c", "cpp", "objc", "objcpp" },
  },

  {
    "rmagatti/auto-session",
    lazy = false, -- 建议别懒加载：要在启动阶段恢复 session
  }




}
