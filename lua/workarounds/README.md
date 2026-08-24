# lua/workarounds/

This directory holds **isolated workarounds** — code that exists only to
work around bugs, platform quirks, or upstream limitations. Main logic
must never carry quirk handling inline; everything that can be labelled
"this is here because of X" lives here.

## Why isolate

* **Findability** — `:WorkaroundList` enumerates every active workaround,
  what it works around, and how to know when it can be removed.
* **Reversibility** — disabling a workaround is one line: comment its
  `apply()` call. No surgery in the main module.
* **Diff hygiene** — when the upstream bug is fixed, the cleanup is one
  `git rm`, not a code-archaeology session.
* **Ownership** — every workaround names the platform/version/issue it's
  for, so you know whether it still applies on your current setup.

## Layout

```
lua/workarounds/
  init.lua                    -- registry, :WorkaroundList, status API
  README.md                   -- this file
  TEMPLATE.lua                -- copy-and-edit starter
  <scope>/<name>.lua          -- one workaround per file
```

`<scope>` is the surface being patched (e.g. `neovide`, `snacks`,
`treesitter`, `clangd`, `lazyvim`). `<name>` is short and snake_case.

## Frontmatter contract

Every workaround file MUST start with this header (parsed by the
registry). Comments-only — no `--[[...]]` blocks, so grep-friendly:

```lua
-- WORKAROUND
-- name: <unique-id matching file path, e.g. neovide.snacks_picker_freeze>
-- scope: <neovide|snacks|treesitter|clangd|lazyvim|windows|...>
-- issue: https://github.com/.../issues/N   (or "internal: <one-line>")
-- symptom: one sentence describing what the user sees if missing
-- introduced: YYYY-MM-DD
-- removal_condition: when this can be deleted (e.g. "snacks.nvim >= 2.20"
--                    or "neovide ships native picker support")
-- owner: hana-alice
-- enabled: true|false
-- END WORKAROUND
```

The body must export at least `M.apply()` (idempotent setup) and may
export `M.disable()` for runtime toggling.

## Calling pattern

In main code, instead of inlining the fix:

```lua
-- BAD: inline workaround buried in main logic
if vim.g.neovide then
  vim.opt.something = "weird"
  ...30 lines of patching...
end

-- GOOD: one explicit call site, fix lives elsewhere
require("workarounds.neovide.snacks_picker_freeze").apply()
```

The registry (`workarounds.init`) loads enabled workarounds in startup
order; you can either eager-call from `init.lua` or let the registry
auto-discover by scanning the directory.

## Commands

* `:WorkaroundList` — table of all workarounds (name, scope, enabled,
  introduced, removal_condition).
* `:WorkaroundStatus <name>` — inspect one workaround's runtime state.
* `:WorkaroundDisable <name>` / `:WorkaroundEnable <name>` — runtime
  toggle (does NOT undo already-applied patches; restart for full
  effect).

## When to NOT isolate

* The fix is genuinely the right solution for the problem (not a
  workaround). Then it belongs in main logic with a normal comment.
* The user explicitly says "fix it in place" / "原地改". Then inline
  with a `-- NOTE` comment.

If unsure, isolate. Cleanup is cheap; embedded quirks rot.
