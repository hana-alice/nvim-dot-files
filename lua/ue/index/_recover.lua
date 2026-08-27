-- ue/index/_recover.lua — rebuild index readiness from PERSISTED evidence.
--
-- WHY THIS MODULE EXISTS
-- ----------------------
-- Readiness was decided solely from the in-process `state` ledger
-- (`state.index_selection` + `state.index_artifacts`). That ledger is fragile: a
-- process that dies mid-write, a concurrent writer, or a crashing script can wipe
-- it. When that happens the controlled CDBs, index artifacts and semantic CDB are
-- all still sitting on disk, yet readiness reports "missing" and the user's only
-- documented recourse is to re-run a multi-minute `UEPrepare`.
--
-- The user's objection was exactly right: "why do I still need prepare?" Nothing
-- about the build changed; only our bookkeeping was lost.
--
-- The spec already forbids this. openspec/specs/cpp-semantic-index-coverage,
-- Scenario "Prepared tuple artifacts survive a Nvim restart":
--   * selection, MANIFEST, controlled CDB, semantic CDB + source CDB signature
--     still provable => clangd SHALL consume the persisted artifacts
--   * "系统 MUST NOT 因新的 Lua 进程尚未执行 UEPrepare 而要求重复 prepare"
--
-- The manifest (`<idx>.manifest.json`) is the designed self-evidence: it binds
-- generation_id, build_key and cdb_source_signature to a specific artifact. So
-- recovery is not a workaround -- it is the contract that was never implemented.
--
-- FAIL CLOSED. Recovery must never widen what counts as ready: a manifest that
-- is missing, unparsable, bound to a different build, or pointing at absent files
-- yields "unusable"/"stale" and the caller keeps deferring. Recovering a WRONG
-- index would silently produce wrong definitions, which is far worse than asking
-- for a rebuild.
--
-- Loader style per lua/ue/index/AGENTS.md; loaded after _generation so the
-- manifest/generation helpers exist on core.h.

local fs = require("ue.core.fs")

return function(M, core)
  --- Classify one persisted manifest against the active build evidence.
  ---
  --- Pure apart from the injectable `exists` probe, so every branch is testable
  --- without staging hundreds of megabytes of real artifacts.
  ---
  --- @param manifest table|nil parsed `<idx>.manifest.json`
  --- @param evidence table { generation_id, build_key, cdb_source_signature }
  --- @param exists? fun(path:string):boolean
  --- @return string verdict "usable" | "stale" | "unusable"
  --- @return string reason stable, machine-readable reason
  M.classify_persisted_manifest = function(manifest, evidence, exists)
    evidence = evidence or {}
    exists = exists or function(p)
      local st = vim.uv.fs_stat(p)
      return st ~= nil and st.type == "file"
    end

    if type(manifest) ~= "table" then
      return "unusable", "manifest-missing-or-unparsable"
    end

    -- Identity first: an artifact from another build must never be revived.
    local function same(field)
      local want = fs.trim(tostring(evidence[field] or ""))
      local got = fs.trim(tostring(manifest[field] or ""))
      -- Unknown evidence cannot prove a match; treat it as a mismatch.
      return want ~= "" and got ~= "" and want == got
    end

    if not same("generation_id") then
      return "stale", "manifest-generation-mismatch"
    end
    if not same("build_key") then
      return "stale", "manifest-build-key-mismatch"
    end
    -- The source CDB is what the artifact was derived from; if it changed, the
    -- artifact describes a compilation database that no longer exists.
    if not same("cdb_source_signature") then
      return "stale", "manifest-cdb-signature-mismatch"
    end

    -- A manifest is a claim; the files it names are the proof.
    local index_path = fs.trim(tostring(manifest.index_path or ""))
    if index_path == "" or not exists(index_path) then
      return "unusable", "manifest-index-artifact-missing"
    end
    local background = fs.trim(tostring(manifest.background_cdb_path or ""))
    if background ~= "" and not exists(background) then
      return "unusable", "manifest-background-cdb-missing"
    end
    if fs.trim(tostring(manifest.artifact_fingerprint or "")) == "" then
      return "unusable", "manifest-missing-fingerprint"
    end

    return "usable", "ok"
  end

  --- Does the in-process ledger still describe a usable artifact?
  --- Used to decide whether disk recovery is even needed. Pure.
  --- @param state table persisted index state
  --- @return boolean intact
  M.ledger_is_intact = function(state)
    state = state or {}
    local artifacts = state.index_artifacts
    -- vim.json turns an empty Lua table into `[]`, so a wiped ledger comes back
    -- as an empty LIST, not a map. Both must count as lost.
    if type(artifacts) ~= "table" or vim.tbl_isempty(artifacts) then
      return false
    end
    local selection = state.index_selection
    if type(selection) ~= "table" then
      return false
    end
    if fs.trim(tostring(selection.artifact_fingerprint or "")) == "" then
      return false
    end
    return true
  end

  --- Rebuild `index_artifacts` + `index_selection` from persisted manifests.
  ---
  --- Returns the phases recovered and the per-phase verdicts, so callers can log
  --- WHY nothing was recovered instead of silently deferring.
  ---
  --- @param ctx table
  --- @param state table persisted index state (mutated on success)
  --- @param deps? table { read_manifest, manifest_path, phase_paths, generation, exists }
  --- @return string[] recovered phases
  --- @return table<string,string> verdicts phase -> reason
  M.recover_from_disk = function(ctx, state, deps)
    deps = deps or {}
    local verdicts = {}
    local recovered = {}
    if not ctx or type(state) ~= "table" then
      return recovered, verdicts
    end

    local manifest_path = deps.manifest_path or core.h.index_manifest_path
    local read_manifest = deps.read_manifest or core.h.read_index_manifest
    local phase_paths = deps.phase_paths or M.index_phase_paths
    local generation = deps.generation
      or (core.h.generation_for_context and core.h.generation_for_context(ctx))
    if not (manifest_path and read_manifest and phase_paths and generation) then
      return recovered, verdicts
    end

    local base_cdb = core.h.base_compile_commands_path
      and core.h.base_compile_commands_path(ctx) or nil
    local evidence = {
      generation_id = generation.generation_id,
      build_key = generation.build_key,
      cdb_source_signature = deps.cdb_source_signature
        or (core.h.file_signature and base_cdb and core.h.file_signature(base_cdb)) or "",
    }

    -- vim.json decodes an empty Lua table back as an empty LIST, so a wiped
    -- ledger arrives as a sequence rather than a map. Normalise before writing.
    local artifacts = state.index_artifacts
    if type(artifacts) ~= "table" or (#artifacts > 0 and artifacts[1] ~= nil) or vim.tbl_isempty(artifacts) then
      state.index_artifacts = {}
    end

    for _, phase in ipairs({ "current", "hot", "full" }) do
      local _, index_path = phase_paths(ctx, phase)
      local manifest = index_path and read_manifest(manifest_path(index_path)) or nil
      local verdict, reason = M.classify_persisted_manifest(manifest, evidence, deps.exists)
      verdicts[phase] = reason
      if verdict == "usable" then
        state.index_artifacts[phase] = manifest
        recovered[#recovered + 1] = phase
      end
    end

    return recovered, verdicts
  end

  --- Recover readiness in place when (and only when) the ledger has been lost.
  ---
  --- Called from `semantic_index_snapshot` so every readiness query benefits,
  --- including the clangd gate. Kept here rather than in _generation so the
  --- recovery policy lives in one file and _generation stays under its line limit.
  --- @param ctx table
  --- @param state table persisted index state (mutated on successful recovery)
  --- @return boolean recovered
  M.maybe_recover_readiness = function(ctx, state)
    if not ctx or type(state) ~= "table" then
      return false
    end
    if M.ledger_is_intact(state) then
      return false
    end

    local recovered, verdicts = M.recover_from_disk(ctx, state)
    if #recovered == 0 then
      -- Explain WHY nothing was recovered: a silent defer is precisely what made
      -- this failure class so hard to diagnose.
      if verdicts and next(verdicts) then
        pcall(function()
          require("utils.log").debug_ctx("ue.index",
            "no recoverable index artifacts on disk", verdicts)
        end)
      end
      return false
    end

    local generation = core.h.generation_for_context(ctx)
    local selection = core.h.select_active_artifact(state, generation)
    core.h.update_index_selection(state, selection, generation, "fresh")
    core.h.save_index_state(ctx, state)
    pcall(function()
      require("utils.log").info_ctx("ue.index", "recovered index readiness from disk", {
        phases = table.concat(recovered, ","),
      })
    end)
    return true
  end
end
