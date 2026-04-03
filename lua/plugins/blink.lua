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
    end,
  },
}
