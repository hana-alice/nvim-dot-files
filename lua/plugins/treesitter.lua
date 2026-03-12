return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    opts = function(_, opts)
      opts = opts or {}
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, {
        "bash",
        "c",
        "cpp",
        "json",
        "lua",
        "markdown",
        "markdown_inline",
        "query",
        "regex",
        "vim",
        "vimdoc",
      })
      opts.ensure_installed = vim.fn.uniq(opts.ensure_installed)
      opts.highlight = opts.highlight or {}
      opts.highlight.enable = true
      opts.indent = opts.indent or {}
      opts.indent.enable = true
      opts.auto_install = true
    end,
  },
}
