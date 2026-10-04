return {
  {
    "saghen/blink.cmp",
    optional = true,
    opts = function(_, opts)
      opts = opts or {}
      opts.keymap = opts.keymap or {}

      opts.keymap["<Tab>"] = {
        "snippet_forward",
        "select_next",
        LazyVim.cmp.map({ "ai_nes", "ai_accept" }),
        "fallback",
      }
      opts.keymap["<S-Tab>"] = {
        "snippet_backward",
        "select_prev",
        "fallback",
      }

      opts.sources = opts.sources or {}
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.providers.snippets = opts.sources.providers.snippets or {}
      local snippets = opts.sources.providers.snippets
      snippets.opts = snippets.opts or {}
      local extended = snippets.opts.extended_filetypes or {}
      extended.cpp = extended.cpp or {}
      if not vim.tbl_contains(extended.cpp, "unreal") then
        extended.cpp[#extended.cpp + 1] = "unreal"
      end
      snippets.opts.extended_filetypes = extended
      local previous_filter = snippets.opts.filter_snippets
      local audited = vim.fs.normalize(vim.fn.stdpath("config") .. "/snippets/unreal.json")
      snippets.opts.filter_snippets = function(ft, file)
        -- The bundled framework file contains legacy generated/RPC templates.
        -- Keep ordinary C++ snippets; expose only our audited UE declarations.
        if ft == "unreal" and vim.fs.normalize(file) ~= audited then return false end
        return not previous_filter or previous_filter(ft, file)
      end

      -- Backport of upstream PR #2378 (not yet released as of v1.10.2):
      -- prevents `start_col must be less than or equal to end_col` thrown
      -- from blink.cmp's text_edits.write_to_dot_repeat when fo includes
      -- 't' or 'c' and a preview pushes the line past textwidth.
      require("workarounds.blink_cmp.auto_wrap_undo_preview").apply()

      return opts
    end,
  },
}
