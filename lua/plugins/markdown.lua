return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    cmd = { "RenderMarkdown", "MarkdownPreview", "MarkdownEdit", "MarkdownPreviewToggle" },
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
    },
    opts = {
      render_modes = { "n", "c", "t" },
      anti_conceal = {
        enabled = true,
        above = 0,
        below = 0,
      },
    },
    config = function(_, opts)
      local render_markdown = require("render-markdown")
      render_markdown.setup(opts)

      local function recreate_user_command(name, callback, desc)
        pcall(vim.api.nvim_del_user_command, name)
        vim.api.nvim_create_user_command(name, callback, { desc = desc })
      end

      recreate_user_command("MarkdownPreview", function()
        render_markdown.buf_enable()
      end, "Markdown: enable rendered preview for current buffer")

      recreate_user_command("MarkdownEdit", function()
        render_markdown.buf_disable()
      end, "Markdown: show raw markdown for current buffer")

      recreate_user_command("MarkdownPreviewToggle", function()
        render_markdown.buf_toggle()
      end, "Markdown: toggle rendered preview for current buffer")
    end,
  },
}
