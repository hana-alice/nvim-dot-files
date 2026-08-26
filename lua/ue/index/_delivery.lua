-- ue/index/_delivery.lua — is the controlled semantic index actually DELIVERED?
--
-- WHY THIS MODULE EXISTS
-- ----------------------
-- `UEPrepare` schedules the controlled BackgroundIndex on every completion path,
-- but the build itself is a separate child process that can take minutes over
-- ~16k TUs. Prepare used to print "UEPrepare done" and finish its progress handle
-- the moment the CDB existed, so a user whose index build was still running (or
-- had already failed) reasonably concluded the semantic layer was ready. It was
-- not, and `gd` then degraded with nothing on screen explaining why.
--
-- Reported symptom (2026-08-26): a symbol with exactly ONE definition produced
-- "wait a while, then a few unity cpp files to choose from". The user had run the
-- habitual flow (set platform -> set project -> build -> UEPrepare) and was right
-- to expect it to work. Requiring them to also remember a platform-specific
-- index command is a design failure, not a user error.
--
-- So "delivered" needs a single, honest verdict that prepare can state out loud.
-- Keeping it separate from _generation.lua also keeps that file under the
-- 800-line structure limit rather than inflating it.
--
-- Loader style per lua/ue/index/AGENTS.md: `return function(M, core)`, sharing
-- core.h / core.RT / core.deps. Loaded after _generation so index_status_summary
-- is already defined.

local fs = require("ue.core.fs")

return function(M, core)
  --- Verdict on whether the semantic index is delivered for the active tuple.
  ---
  --- Pure over an injected summary so the wording contract is headless-testable
  --- without a real index on disk.
  --- @param summary table result of M.index_status_summary
  --- @return string verdict ready|building|queued|failed|interrupted|pending
  --- @return string line human-readable line for the prepare summary
  M.index_delivery_line = function(summary)
    summary = summary or {}
    local status = fs.trim(tostring(summary.status or ""))
    local phase = fs.trim(tostring(summary.phase_label or summary.phase or ""))
    local coverage = fs.trim(tostring(summary.coverage_level or ""))

    if status == "running" then
      return "building", ("Semantic index: BUILDING (%s) — C++ definition navigation is not ready yet")
        :format(phase ~= "" and phase or "index")
    end
    if status == "error" then
      return "failed", "Semantic index: FAILED — C++ definition navigation stays degraded (see :NvimLog)"
    end
    if status == "interrupted" then
      return "interrupted",
        "Semantic index: INTERRUPTED by a previous exit — it will be rebuilt; navigation not ready yet"
    end
    if (tonumber(summary.queue_count) or 0) > 0 then
      return "queued", ("Semantic index: QUEUED (%s) — building shortly")
        :format(table.concat(summary.queued or {}, ","))
    end
    -- Only a selected artifact of the CURRENT generation counts as delivered.
    -- A stale or missing selection MUST NOT be reported as ready: the clangd gate
    -- consumes persisted readiness, so claiming "ready" here while the gate defers
    -- is exactly the contradiction that hid this defect (K41).
    if summary.freshness ~= "missing" and summary.freshness ~= "stale"
        and coverage ~= "" and coverage ~= "-" then
      return "ready", ("Semantic index: ready (%s)"):format(coverage)
    end
    return "pending", "Semantic index: not delivered yet — C++ definition navigation is not ready"
  end

  --- Newline-prefixed delivery line for the UEPrepare summary, or "" when status
  --- cannot be read. Lives here rather than in ue.lua so the façade stays thin
  --- and its monotonically decreasing line ratchet keeps falling.
  --- @param ctx table
  --- @return string suffix
  M.prepare_delivery_suffix = function(ctx)
    local ok, _, line = pcall(function()
      return M.index_delivery_line(M.index_status_summary(ctx))
    end)
    if ok and type(line) == "string" and line ~= "" then
      return "\n" .. line
    end
    return ""
  end

  --- Report controlled-CDB artifacts that exist on disk but CANNOT back the
  --- current generation, so "present" is never mistaken for "usable".
  ---
  --- WHY: `select_active_artifact` already refuses artifacts whose manifest does
  --- not match the active generation, so a stale file can never be *selected* --
  --- correctness was fine. What was missing is OBSERVABILITY: the files just sit
  --- there. On this machine `current.json` and `hot.json` (46MB each, a month old)
  --- had no manifest at all, which reads as "the index exists" to anyone looking
  --- at the directory while the gate silently defers. Naming the mismatch is what
  --- turns a confusing silence into an explanation.
  ---
  --- Deliberately REPORT-ONLY: deleting another generation's artifact is unsafe
  --- here because a second Neovim on a different tuple may legitimately own it
  --- (K27/C5b invalidation matrix, K43 multi-instance isolation). Reclamation
  --- belongs to an explicit, lease-held prepare step.
  --- @param ctx table
  --- @return table[] rows { phase, path, reason, size }
  M.stale_index_artifacts = function(ctx)
    local rows = {}
    if not ctx or not ctx.paths then
      return rows
    end
    local state = core.h.ensure_index_state(ctx)
    local generation = core.h.generation_for_context(ctx)
    local paths = {
      current = ctx.paths.index_current_cdb,
      hot = ctx.paths.index_hot_cdb,
      full = ctx.paths.index_full_cdb,
    }
    for _, phase in ipairs({ "current", "hot", "full" }) do
      local path = paths[phase]
      local stat = path and vim.uv.fs_stat(path) or nil
      if stat and stat.type == "file" then
        local manifest = core.h.read_index_manifest(core.h.index_manifest_path(path))
        local reason
        if not manifest then
          reason = "no manifest (cannot prove which build produced it)"
        elseif not core.h.same_generation(manifest, generation) then
          reason = "generation mismatch (built for a different build/tuple)"
        elseif not core.h.same_generation(state.index_artifacts[phase], generation) then
          reason = "not registered for the active generation"
        end
        if reason then
          rows[#rows + 1] = {
            phase = phase,
            path = path,
            reason = reason,
            size = stat.size or 0,
          }
        end
      end
    end
    return rows
  end
end
