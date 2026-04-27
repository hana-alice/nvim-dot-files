return {
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts = opts or {}
      opts.keymap = opts.keymap or {}

      opts.keymap["<Tab>"] = {
        "select_next",
        LazyVim.cmp.map({ "snippet_forward", "ai_nes", "ai_accept" }),
        "fallback",
      }
      opts.keymap["<S-Tab>"] = {
        "select_prev",
        "snippet_backward",
        "fallback",
      }

      -- Backport of upstream PR #2378 (not yet released as of v1.10.2):
      -- prevents `start_col must be less than or equal to end_col` thrown
      -- from blink.cmp's text_edits.write_to_dot_repeat when fo includes
      -- 't' or 'c' and a preview pushes the line past textwidth.
      require("workarounds.blink_cmp.auto_wrap_undo_preview").apply()

      return opts
    end,
  },
}
