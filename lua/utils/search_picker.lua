-- Indexed search UI; ue.lua owns context resolution and the public facade.
local M = {}
local fs = require("ue.core.fs")
local trim = fs.trim
local ui = require("utils.search_ui")
local controls = require("utils.search_controls")
local presentation = require("utils.code_search.picker")

function M.open(opts, ctx, owner)
  local snacks = require("snacks")
  local code_search = require("utils.code_search")
  local source_path = vim.api.nvim_buf_get_name(0)
  local cs_ctx = { workspace_root = owner.workspace_root, csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil }
  local has_index = code_search.is_indexed(cs_ctx)
  local backend_label = has_index and "csearch" or "rg"

  -- In-panel scope filter (change `refactor-search-system`): capture the
  -- current buffer's module/plugin scope at open time so <a-s> can restrict
  -- the search to it without leaving the picker. The scope's root path is
  -- escaped into an RE2 fragment passed to csearch's -f file-path filter.
  -- nil when the current file isn't inside any module/plugin (toggle no-ops).
  local grep_scope = owner.scope

  local function grep_picker_title(scoped, options)
    local base = owner.grep_backend_title(opts.title or "Grep All Code", backend_label)
    if options then
      return controls.title(base, options)
    end
    if scoped and grep_scope then
      return base .. " [scope: " .. tostring(grep_scope.label or grep_scope.name or "current") .. "]"
    end
    return base .. " [scope: all]"
  end

  local title_default = owner.grep_backend_title("Grep All Code", backend_label)
  local live_min_chars = opts.live_min_chars or 2
  local live_max_count = opts.max_count or 5000
  local short_live_max_count = opts.short_live_max_count or 1200
  local function update_scope_title(picker)
    picker.opts.ue_search_base_title = grep_picker_title(picker.opts.scoped, picker.opts)
    ui.status(picker, picker.opts.ue_search_status or { state = "waiting" })
  end

  -- ─ Helpers shared by both csearch and rg paths ──────────────────────
  -- Dev toggle for A/B against vanilla snacks: structured path/count formatter and
  -- preview throttle are off when false. Runtime: :UEGrepGroupingToggle.
  local grouping_enabled = (vim.g.ue_grep_grouping_enabled == true)
  -- csearch emits hits grouped by file. Buffer only the current file so its count is
  -- known, then annotate and emit the original match rows. Unlike the old synthetic
  -- header design, this never creates a selectable item without a source location.
  local function make_file_grouping_cb(cb)
    local current_file = nil
    local current_items = {}

    local function flush()
      if #current_items == 0 then
        return
      end
      for _, item in ipairs(owner.grep_annotate_file_group(current_items, ctx)) do
        cb(item)
      end
      current_items = {}
    end

    local function push(item)
      if item == nil then
        return
      end
      if current_file ~= nil and item.file ~= current_file then
        flush()
      end
      current_file = item.file
      current_items[#current_items + 1] = item
    end

    return push, flush
  end

  -- Per-picker keymap override:
  -- snacks default <Tab> = select_and_next (multi-select), which on huge
  -- grep result lists costs a full list redraw + selected-set highlight
  -- recompute on EVERY press — feels laggy when the user is just scanning
  -- with key-repeat. Override <Tab> to plain list_down here. Multi-select
  -- still available via <S-Tab> / <C-Space> (which we leave alone).
  local fast_tab_keys = {
    win = {
      input = { keys = { ["<Tab>"] = { "list_down", mode = { "i", "n" } } } },
      list = { keys = { ["<Tab>"] = "list_down" } },
    },
  }

  -- Preview throttle: snacks default is 60ms which is faster than typical
  -- Tab key-repeat (30-50ms), so each Tab still fires a fresh preview build.
  -- For UE-scale files (.cpp 500KB+, 50-200ms TS highlight), this stacks up
  -- and feels laggy. Bump to 200ms — preview renders only after the user
  -- pauses scrolling.
  local function on_show_picker(picker)
    pcall(function()
      local snacks_util = require("snacks.util")
      local ref = picker:ref()
      picker._throttled_preview = snacks_util.throttle(function()
        local this = ref()
        if this then
          this:_show_preview()
        end
      end, { ms = 200, name = "preview" })
    end)
  end

  -- ─ Diagnostic trace (opt-in via vim.g.ue_grep_trace) ────────────────
  -- When enabled, write per-event lines to a stable log path so we can
  -- post-mortem WHY the picker felt laggy on a real human typing session.
  -- Zero overhead when disabled (single boolean check per event).
  --
  -- Toggle: :UEGrepTraceToggle  (or set vim.g.ue_grep_trace = true)
  -- Log:    vim.fn.stdpath("state") .. "/ue_grep_trace.log"
  local trace_enabled = vim.g.ue_grep_trace == true
  local trace_log_path = vim.fn.stdpath("state") .. ("/ue_grep_trace.%d.log"):format(vim.fn.getpid())
  local trace_t0 = vim.loop.hrtime()
  local function trace(fmt, ...)
    if not trace_enabled then
      return
    end
    local ms = (vim.loop.hrtime() - trace_t0) / 1e6
    local line = string.format("[+%8.1fms] " .. fmt, ms, ...)
    local f = io.open(trace_log_path, "a")
    if f then
      f:write(line .. "\n")
      f:close()
    end
  end
  if trace_enabled then
    -- Truncate at session start so each <leader>/ produces a clean timeline.
    local f = io.open(trace_log_path, "w")
    if f then
      f:write(
        string.format(
          "=== UE grep trace  %s  backend=%s  grouping=%s  has_index=%s ===\n",
          os.date("%Y-%m-%d %H:%M:%S"),
          backend_label,
          tostring(grouping_enabled),
          tostring(has_index)
        )
      )
      f:close()
    end
  end

  -- Backend diagnostic — now OPT-IN (was always-on during the "<leader>/
  -- missing results" investigation; that's confirmed fixed). Gated on the same
  -- vim.g.ue_grep_trace flag so a normal grep writes nothing to disk (P5: no
  -- silent per-action side-effects). Enable with :UEGrepTraceToggle when
  -- debugging backend/mode/result-count.
  local debug_log_path = vim.fn.stdpath("state") .. ("/ue_grep_backend_debug.%d.log"):format(vim.fn.getpid())
  local function grep_debug(fmt, ...)
    if vim.g.ue_grep_trace ~= true then
      return
    end
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then
      line = tostring(fmt)
    end
    local f = io.open(debug_log_path, "a")
    if f then
      f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n")
      f:close()
    end
  end
  do
    local idx_size = nil
    if cs_ctx.csearch_idx then
      local st = vim.loop.fs_stat(cs_ctx.csearch_idx)
      idx_size = st and st.size or nil
    end
    grep_debug(
      "OPEN backend=%s has_index=%s idx=%s idx_size=%s title=%s",
      tostring(backend_label),
      tostring(has_index),
      tostring(cs_ctx.csearch_idx),
      tostring(idx_size),
      tostring(owner.grep_backend_title(opts.title or title_default, backend_label))
    )
  end

  -- ── csearch fast path ────────────────────────────────────────────────
  if has_index then
    snacks.picker.pick({
      source = "ue_grep_csearch",
      -- Record the query only when a result is actually opened, so search
      -- history keeps useful searches instead of every typing pause.
      confirm = require("utils.search_recipe").confirm,
      jump = { match = false },
      on_close = require("utils.search_recipe").save_resume_options,
      title = grep_picker_title(false),
      search = opts.search or "",
      pattern = opts.pattern or "",
      ue_search_context = ctx,
      ue_search_recipe = opts.ue_search_recipe,
      ue_scope_kind = opts.ue_scope_kind or (opts.scoped and "module" or "workspace"),
      ue_scope_roots = opts.ue_scope_roots or (opts.scoped and grep_scope and { grep_scope.root }) or controls.roots(
        ctx
      ),
      glob = opts.glob or {},
      exclude = opts.exclude or {},
      ft = opts.ft or {},
      code_only = opts.code_only == true,
      live = true,
      supports_live = true,
      need_search = true,
      limit = live_max_count,
      limit_live = live_max_count,
      matcher = grouping_enabled and { sort = false } or nil, -- preserve csearch file groups
      layout = { preset = "telescope" },
      -- Search mode toggles. snacks auto-merges these with built-in toggles
      -- (regex, follow, hidden, ignored, modified — see snacks/picker/config/
      -- defaults.lua). For each entry it auto-generates a toggle_<name>
      -- action that flips picker.opts[name] then calls picker:find().
      --
      -- Title icon semantics: snacks renders icon when picker.opts[name] ==
      -- toggle.value. We want "icon visible = mode ENABLED" so:
      --   regex: value=true   → R shows when regex mode is ON (literal off)
      --   word:  value=true   → W shows when whole-word ON
      --   case:  value=true   → C shows when case-sensitive ON
      -- Without overriding regex here, snacks' default value=false would
      -- show R when LITERAL mode is on, which is reverse intuition.
      regex = opts.regex == true,
      literal = opts.regex ~= true,
      word = opts.word == true,
      case = opts.case == true,
      scoped = opts.scoped == true,
      toggles = {
        regex = { icon = "R", value = true },
        literal = { icon = "L", value = true },
        word = { icon = "W", value = true },
        case = { icon = "C", value = true },
        scoped = { icon = "S", value = true },
      },
      -- Keymaps: Alt-r/g/x/w/c = mode toggles, shown live as R/W/C icons in
      -- the picker title. <a-r> is the intuitive "regex" toggle (matches
      -- snacks' own default); <a-g> = "grep regex" mnemonic alias. Both flip
      -- the same regex flag. <a-w>/<a-x> = whole-word, <a-c> = case-sensitive.
      -- <a-s> = restrict to the current module/plugin scope (in-panel scope
      -- filter; shows an "S" icon when active).
      -- NOTE: <a-r> previously collided with NVIDIA App's global Performance
      -- Overlay hotkey; if it ever stops reaching nvim again, use <a-g>.
      win = vim.tbl_deep_extend("force", grouping_enabled and fast_tab_keys.win or {}, {
        input = {
          keys = {
            ["<a-r>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
            ["<a-g>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
            ["<a-x>"] = { "ue_grep_toggle_word", mode = { "i", "n" } },
            ["<a-w>"] = { "ue_grep_toggle_word", mode = { "i", "n" } },
            ["<a-c>"] = { "ue_grep_toggle_case", mode = { "i", "n" } },
            ["<a-s>"] = { "ue_grep_toggle_scope", mode = { "i", "n" } },
            ["<a-d>"] = { "ue_grep_choose_scope", mode = { "i", "n" } },
            ["<a-f>"] = { "ue_grep_file_masks", mode = { "i", "n" } },
          },
        },
      }),
      actions = {
        ue_grep_choose_scope = function(picker)
          controls.choose_scope(picker, ctx, grep_scope, source_path, update_scope_title)
        end,
        ue_grep_file_masks = function(picker)
          controls.masks(picker, update_scope_title)
        end,
        ue_grep_toggle_regex = function(picker)
          picker.opts.regex = not picker.opts.regex
          picker.opts.literal = not picker.opts.regex
          require("snacks").notify(
            (picker.opts.regex and "✓ regex ON " or "✗ regex OFF (literal)"),
            { title = "UE grep", level = "info" }
          )
          picker.list:set_target()
          picker:find()
        end,
        ue_grep_toggle_word = function(picker)
          picker.opts.word = not picker.opts.word
          require("snacks").notify(
            (picker.opts.word and "✓ whole-word ON " or "✗ whole-word OFF"),
            { title = "UE grep", level = "info" }
          )
          picker.list:set_target()
          picker:find()
        end,
        ue_grep_toggle_case = function(picker)
          picker.opts.case = not picker.opts.case
          require("snacks").notify(
            (picker.opts.case and "✓ case-sensitive ON " or "✗ ignore-case"),
            { title = "UE grep", level = "info" }
          )
          grep_debug("TOGGLE backend=csearch case=%s", tostring(picker.opts.case == true))
          picker.list:set_target()
          picker:find()
        end,
        ue_grep_toggle_scope = function(picker)
          if not grep_scope then
            require("snacks").notify(
              "✗ no module/plugin scope (current file isn't inside one)",
              { title = "UE grep", level = "warn" }
            )
            return
          end
          picker.opts.scoped = not picker.opts.scoped
          picker.opts.ue_scope_kind = picker.opts.scoped and "module" or "workspace"
          picker.opts.ue_scope_roots = picker.opts.scoped and { grep_scope.root } or controls.roots(ctx)
          update_scope_title(picker)
          require("snacks").notify(
            (
              picker.opts.scoped and ("✓ scope: " .. (grep_scope.label or grep_scope.name or "current"))
              or "✗ scope OFF (whole workspace)"
            ),
            { title = "UE grep", level = "info" }
          )
          picker.list:set_target()
          picker:find()
        end,
      },
      format = grouping_enabled and owner.grep_format_grouped or ui.format,
      on_show = function(picker)
        update_scope_title(picker)
        if grouping_enabled then
          on_show_picker(picker)
        end
      end,
      finder = function(_picker_opts, finder_ctx)
        local pattern = finder_ctx.filter.search
        local _picker = finder_ctx and finder_ctx.picker
        local _po = _picker and _picker.opts or {}
        local generation = ui.begin(_picker)
        local post_filter, filter_err = presentation.compile_filter({
          include = _po.glob,
          exclude = _po.exclude,
          types = _po.ft,
          roots = _po.ue_scope_roots,
        })
        if not post_filter then
          ui.status(_picker, { state = "error", reason = "invalid-filter", error = filter_err }, generation)
          return function() end
        end
        if not owner.grep_live_search_ready(pattern, live_min_chars, _po.regex ~= true) then
          ui.status(_picker, { state = "waiting", complete = false, delivered = 0 }, generation)
          return function() end
        end
        ui.status(_picker, { state = "running", complete = false, delivered = 0 }, generation)
        trace("finder START pattern=%q", pattern)
        return function(cb)
          -- snacks finder protocol: this function MUST block until ALL
          -- callbacks have been emitted, otherwise snacks marks the finder
          -- "done" and any later cb call trips its "yielded after done"
          -- bug-trap. We start csearch in the background, queue items
          -- through a buffer, and use ctx.async:sleep() to yield to the
          -- picker until the csearch process reports done OR the picker
          -- aborts us (sleep returns early on abort).
          local done = false
          local pending = {} -- items waiting to be drained on the main loop
          local pending_len = 0
          local items_received = 0
          local items_emitted = 0
          local terminal_metadata

          local function enqueue(item)
            pending_len = pending_len + 1
            pending[pending_len] = item
          end
          local queue_item = enqueue
          local flush_file_group = function() end
          if grouping_enabled then
            queue_item, flush_file_group = make_file_grouping_cb(enqueue)
          end

          local t_cs_spawn_0 = vim.loop.hrtime()
          local cs_first_line_logged = false
          -- Read mode toggles from picker.opts (Alt-r/Alt-x/Alt-c flip
          -- these in place via snacks auto-generated toggle_<name> actions,
          -- then picker:find() restarts this finder so we see the new values).
          local pattern_len = #trim(tostring(pattern or ""))
          local mode_case = _po.case == true
          local mode_ignore_case = not mode_case
          grep_debug(
            "FINDER backend=csearch pattern=%q regex=%s word=%s case=%s ignore_case=%s max=%d",
            tostring(pattern),
            tostring(_po.regex == true),
            tostring(_po.word == true),
            tostring(mode_case),
            tostring(mode_ignore_case),
            pattern_len <= live_min_chars and short_live_max_count or live_max_count
          )
          local scope_re = controls.path_filter(_po.ue_scope_roots)
          local stop = code_search.stream(cs_ctx, pattern, {
            require_index = true,
            code_only = _po.code_only,
            smart_case = true,
            max_count = pattern_len <= live_min_chars and short_live_max_count or live_max_count,
            regex = _po.regex == true, -- snacks default false = literal
            word = _po.word == true,
            case = mode_case,
            ignore_case = mode_ignore_case,
            path_filter = scope_re, -- in-panel scope filter (<a-s>)
          }, {
            on_line = function(file, lnum, col, text, location)
              if not cs_first_line_logged then
                cs_first_line_logged = true
                trace("PHASE csearch_first_line=%.2fms after_spawn", (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)
              end
              -- Buffer only real match items. The literal path carries an
              -- exact end_pos so Snacks preview never reinterprets raw input
              -- such as "." as Vim regex syntax.
              local item = owner.grep_hit_item(file, lnum, col, text, pattern, _po.regex == true, location)
              if presentation.filter_item(item, post_filter) then
                queue_item(item)
              end
              items_received = items_received + 1
            end,
            on_done = function(code, err, metadata)
              -- csearch output is file-grouped. Close the final group before
              -- done=true so the normal budgeted drain sees every annotated
              -- real hit and never needs a synthetic header row.
              flush_file_group()
              done = true
              metadata = metadata or { state = code == 0 and "complete" or "error", delivered = items_received }
              metadata.visible = pending_len
              metadata.error = err
              terminal_metadata = metadata
              ui.status(_picker, metadata, generation)
              trace(
                "csearch DONE pat=%q recv=%d code=%s err=%s elapsed=%.1fms",
                pattern,
                items_received,
                tostring(code),
                tostring(err and err:sub(1, 80)),
                (vim.loop.hrtime() - t_cs_spawn_0) / 1e6
              )
              grep_debug(
                "DONE backend=csearch pattern=%q recv=%d code=%s err=%s elapsed=%.1fms",
                tostring(pattern),
                items_received,
                tostring(code),
                tostring(err and err:sub(1, 120)),
                (vim.loop.hrtime() - t_cs_spawn_0) / 1e6
              )
            end,
          })
          trace("PHASE cs_stream_call_returned=%.2fms", (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)

          -- Abort belongs to the finder itself, including same-query mode/scope
          -- changes. No polling timer is needed to discover coroutine death.
          finder_ctx.async:on("abort", function()
            stop("picker-aborted")
          end)
          finder_ctx.async:on("error", function()
            stop("finder-error")
          end)

          -- Drain loop: sleep in short slices so we can flush pending
          -- items frequently AND react to picker aborts (filter.search
          -- changing under us). Small slice (5ms) lets us notice aborts
          -- fast — when the user is typing, each keystroke aborts the
          -- prior finder, and a 30ms slice meant 30ms of dead csearch
          -- output kept landing in the picker. Per-tick cb count is also
          -- capped so we never hand snacks more than CB_BUDGET items in
          -- one frame (large bursts → snacks rebuilds list+highlight per
          -- batch and can stall the main loop for tens of ms).
          -- Tunables: smaller slice = faster abort response; smaller
          -- budget = lower per-tick stall on snacks redraw. Sweet spot
          -- found empirically at 2ms / 80 — abort after typing a key is
          -- ~imperceptible, and large result bursts (Render*, FName etc.)
          -- spread across ~10 frames at 16ms each instead of stalling
          -- one frame for 100ms+.
          local drain_slice_ms = 2
          local CB_BUDGET = 80 -- items per drain tick
          local max_total_ms = 30000 -- absolute upper bound, ~30s
          local elapsed = 0
          local read_idx = 1
          local tick_count = 0
          local longest_drain_ms = 0
          while not done and elapsed < max_total_ms do
            tick_count = tick_count + 1
            -- Abort detection: compare against LIVE picker input, not the
            -- finder_ctx.filter snapshot (snacks captures the filter at
            -- finder start and never updates it for this finder, so
            -- finder_ctx.filter.search would always equal `pattern`).
            local cur_search = nil
            do
              local p = finder_ctx and finder_ctx.picker
              if p and p.input and p.input.filter then
                cur_search = p.input.filter.search
              end
            end
            if cur_search ~= nil and trim(cur_search) ~= pattern then
              trace(
                "ABORT pat=%q new=%q tick=%d elapsed=%dms recv=%d emit=%d pending=%d",
                pattern,
                tostring(cur_search),
                tick_count,
                elapsed,
                items_received,
                items_emitted,
                pending_len - read_idx + 1
              )
              pcall(stop)
              break
            end
            -- Drain up to CB_BUDGET items accumulated since last slice.
            -- Use read_idx + pending_len rather than #pending: drained
            -- entries are set to nil below, and Lua's length operator is
            -- undefined on tables with holes. Using #pending here used to
            -- drop tail hits (e.g. backend recv=15 but picker emitted=12).
            local n = pending_len
            if read_idx <= n then
              local stop_at = math.min(n, read_idx + CB_BUDGET - 1)
              local drain_t0 = vim.loop.hrtime()
              for i = read_idx, stop_at do
                local item = pending[i]
                if item then
                  cb(item)
                  items_emitted = items_emitted + 1
                end
                pending[i] = nil
              end
              local drain_ms = (vim.loop.hrtime() - drain_t0) / 1e6
              if drain_ms > longest_drain_ms then
                longest_drain_ms = drain_ms
              end
              if drain_ms > 20 then
                trace(
                  "SLOW DRAIN tick=%d elapsed=%dms emitted=%d in %.1fms (budget=%d, queue_len=%d)",
                  tick_count,
                  elapsed,
                  stop_at - read_idx + 1,
                  drain_ms,
                  CB_BUDGET,
                  n - stop_at
                )
              end
              read_idx = stop_at + 1
            end
            finder_ctx.async:sleep(drain_slice_ms)
            elapsed = elapsed + drain_slice_ms
          end

          -- Detect WHY we exited the loop. If the user aborted us
          -- (filter changed), we MUST NOT call cb anymore — snacks has
          -- marked our finder done and any further cb trips the
          -- "yielded after done" bug-trap. Just kill the subprocess and
          -- discard any pending items.
          -- Detect WHY we exited the loop. Use LIVE picker input (not
          -- finder_ctx.filter snapshot — same reason as drain abort).
          local final_cur = nil
          do
            local p = finder_ctx and finder_ctx.picker
            if p and p.input and p.input.filter then
              final_cur = p.input.filter.search
            end
          end
          local aborted = (final_cur ~= nil and trim(final_cur) ~= pattern)

          if not aborted then
            flush_file_group()
            -- Final drain after done (still safe — we haven't returned).
            -- Resume from read_idx so we don't double-cb earlier items.
            local final_drain_t0 = vim.loop.hrtime()
            local final_count = 0
            for i = read_idx, pending_len do
              local item = pending[i]
              if item then
                cb(item)
                final_count = final_count + 1
                items_emitted = items_emitted + 1
                if final_count % CB_BUDGET == 0 and i < pending_len then
                  finder_ctx.async:sleep(drain_slice_ms)
                end
              end
              pending[i] = nil
            end
            local final_drain_ms = (vim.loop.hrtime() - final_drain_t0) / 1e6
            trace("FINAL DRAIN pat=%q count=%d in %.1fms", pattern, final_count, final_drain_ms)
            grep_debug(
              "FINAL backend=csearch pattern=%q final_count=%d total_recv=%d emitted_before_final=%d",
              tostring(pattern),
              final_count,
              items_received,
              items_emitted
            )
          end

          -- Stop the subprocess if it's still alive (timeout / abort path).
          if not done then
            pcall(stop)
          end
          if terminal_metadata and not aborted then
            ui.status(_picker, terminal_metadata, generation)
          end

          trace(
            "finder END pat=%q aborted=%s ticks=%d elapsed=%dms recv=%d emit=%d longest_drain=%.1fms",
            pattern,
            tostring(aborted),
            tick_count,
            elapsed,
            items_received,
            items_emitted,
            longest_drain_ms
          )
          grep_debug(
            "END backend=csearch pattern=%q aborted=%s recv=%d emitted=%d longest_drain=%.1fms",
            tostring(pattern),
            tostring(aborted),
            items_received,
            items_emitted,
            longest_drain_ms
          )
        end
      end,
    })
    return true
  end

  -- ── No csearch index: <leader>/ NEVER falls back to rg ─────────────
  -- Hard contract (change `refactor-search-system`): this entry is csearch-
  -- ONLY. We removed all three former rg back-doors (rg-batched fallback,
  -- return-nil -> snacks dir-walk, and the "ue_grep_rg" fast-path). When no
  -- csearch index is available we surface a visible error and open NO picker.
  -- rg lives on elsewhere: <leader>sG (ue_grep_all) is the explicit rg entry,
  -- and code_search.stream() keeps its rg branch for gd/gr fallback (P12).
  if not vim.b._ue_grep_no_index_warned then
    vim.b._ue_grep_no_index_warned = true
    vim.schedule(function()
      vim.notify(
        "UE grep: no csearch index — <leader>/ is csearch-only and will not "
          .. "fall back to rg. Run :UEPrepare to build the index. "
          .. "(For an explicit rg search use <leader>sG.)",
        vim.log.levels.ERROR,
        { title = "UE" }
      )
    end)
  end
  return nil
end

return M
