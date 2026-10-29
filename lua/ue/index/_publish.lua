-- Publish verified controlled CDBs and reuse an unchanged publication.
return function(M, core)
  local fs = require("ue.core.fs")
  local _ufs = fs
  local RT = core.RT
  local file_signature = core.h.file_signature

  local function read_cdb(path)
    if not path or path == "" or not _ufs.is_file(path) then return nil end
    local content = core.deps.read_all(path)
    local ok, decoded = pcall(vim.json.decode, content or "")
    if not ok or type(decoded) ~= "table" then return nil end
    return decoded, content
  end

  local function atomic_write_json(path, value)
    if M._publication_guard then M._publication_guard() end
    _ufs.ensure_dir(vim.fs.dirname(path))
    local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
    if not core.deps.write_all(tmp, vim.json.encode(value)) then
      pcall(vim.fn.delete, tmp)
      return false, "temporary write failed"
    end
    if M._publication_guard then
      local current, reason = pcall(M._publication_guard)
      if not current then pcall(vim.fn.delete, tmp); return false, tostring(reason) end
    end
    local ok, err = (vim.uv or vim.loop).fs_rename(tmp, path)
    if not ok then
      pcall(vim.fn.delete, tmp)
      return false, "atomic rename failed: " .. tostring(err)
    end
    return true
  end

  -- Publish one controlled, coverage-complete database for clangd BackgroundIndex.
  -- Exact open-buffer commands are supplied separately through clangd's
  -- compilationDatabaseChanges protocol extension. Compiler-authored UBT unity
  -- groups are used when fully proven; exact per-file entries retain coverage
  -- elsewhere. Every completed phase is additive; current/hot entries lead the
  -- queue for responsiveness but can never remove the broad full baseline.
  local function clangd_cdb_entry(entry)
    local published = {
      directory = entry.directory,
      file = entry.file,
    }
    if type(entry.arguments) == "table" then
      -- Entries are freshly decoded for this publication and never mutated.
      -- Retain the argv reference instead of copying every large command again.
      published.arguments = entry.arguments
    elseif type(entry.command) == "string" then
      published.command = entry.command
    end
    if entry.output ~= nil then published.output = entry.output end
    return published
  end

  local function entry_key(entry)
    if type(entry) ~= "table" or type(entry.directory) ~= "string" or type(entry.file) ~= "string"
      or (entry.output ~= nil and type(entry.output) ~= "string") then return nil end
    if type(entry.arguments) == "table" then
      if not vim.islist(entry.arguments) then return nil end
      for _, argument in ipairs(entry.arguments) do
        if type(argument) ~= "string" then return nil end
      end
    elseif type(entry.command) ~= "string" then
      return nil
    end
    local native = clangd_cdb_entry(entry)
    -- An ordered tuple avoids JSON object-key order and preserves command
    -- variants for the same file, including the literal optional output.
    return vim.json.encode({ native.directory, native.file, native.arguments or vim.NIL,
      native.command or vim.NIL, native.output or vim.NIL })
  end

  local function same_publication(previous, proposed)
    if vim.deep_equal(previous, proposed) then return true end
    if not vim.islist(previous) or #previous ~= #proposed then return false end
    local path_key = require("utils.platform").driver().path_key
    local identities = {}
    local function file_identity(entry)
      if type(entry) ~= "table" or type(entry.file) ~= "string"
        or type(entry.directory) ~= "string" then return nil end
      local file = fs.norm(entry.file)
      if not fs.is_absolute_path(file) then file = fs.join(entry.directory, file) end
      if not fs.is_absolute_path(file) then return nil end
      return path_key(vim.fs.normalize(file))
    end
    for _, entry in ipairs(previous) do
      local file, command = file_identity(entry), entry_key(entry)
      if not file or not command or identities[file]
        or not vim.deep_equal(entry, clangd_cdb_entry(entry)) then return false end
      identities[file] = command
    end
    for _, entry in ipairs(proposed) do
      local file = file_identity(entry)
      if not file or identities[file] ~= entry_key(entry) then return false end
      identities[file] = nil -- A second command for this file makes ordering significant.
    end
    return true
  end

  local function publication_key(ctx, state, generation, base_path)
    local key = {
      context = { ctx.engine_root or "", ctx.project_root or "", ctx.paths.platform_key or "" },
      base = { base_path, file_signature(base_path) },
      generation = { generation.generation_id, generation.build_key or "" },
      published = { ctx.paths.semantic_cdb, file_signature(ctx.paths.semantic_cdb) },
      batches = file_signature(fs.join(vim.fs.dirname(ctx.paths.semantic_cdb), "batches.json")),
      phases = {},
    }
    for _, phase in ipairs({ "current", "hot", "full" }) do
      local artifact = state.index_artifacts and state.index_artifacts[phase]
      if artifact and artifact.generation_id == generation.generation_id then
        key.phases[#key.phases + 1] = { phase, artifact.background_cdb_path, artifact.background_cdb_hash or "",
          file_signature(artifact.background_cdb_path) }
      end
    end
    return key
  end

  -- SeenKeys is keyed by file, so an additional command variant for an old
  -- file is not an additive update. Compare literal argv/cwd/output as well.
  local function append_only(previous, proposed)
    if not vim.islist(previous) or #previous == 0 or #proposed <= #previous then return false end
    local path_key = require("utils.platform").driver().path_key
    local function commands(entries)
      local result = {}
      for _, entry in ipairs(entries) do
        local file = M.normalize_cdb_file(entry)
        local command = entry_key(entry)
        if not command or not fs.is_absolute_path(file) then return nil end
        file = path_key(vim.fs.normalize(file))
        if result[file] then return nil end
        result[file] = command
      end
      return result
    end
    local before, after = commands(previous), commands(proposed)
    if not before or not after then return false end
    for file, command in pairs(before) do
      if after[file] ~= command then return false end
    end
    return true
  end

  local function empty_migration()
    return { count = 0, removed = 0, removed_by_identity = 0, missing = 0, errors = {},
      compare_ms = 0, delete_ms = 0, scan_ms = 0, read_ms = 0, scan_count = 0, candidates_read = 0 }
  end

  -- clangd tests source digests, not the stored main command, when loading a
  -- shard. A former wrapper member can therefore survive as an exact main with
  -- the old context. Compare the two live views, never the base/phase metadata.
  local function invalidate_migrated_mains(previous, proposed, cdb_path)
    local uv = vim.uv or vim.loop
    local report, started = empty_migration(), uv.hrtime()
    local driver = require("utils.platform").driver()
    local function commands(entries)
      local result = {}
      for _, entry in ipairs(entries or {}) do
        local file = M.normalize_cdb_file(entry)
        if fs.is_absolute_path(file) then
          file = vim.fs.normalize(file)
          local key = driver.path_key(file)
          local item = result[key]
          if not item then item = { file = file, keys = {} }; result[key] = item end
          -- Preserve same-main variant order, just as same_publication does.
          item.keys[#item.keys + 1] = entry_key(entry)
        else
          report.errors[#report.errors + 1] = { file = file, error = "main path is not absolute" }
        end
      end
      return result
    end
    local before = commands(vim.islist(previous) and previous or {})
    local after, migrated = commands(proposed), {}
    for key, item in pairs(after) do
      if not before[key] or not vim.deep_equal(before[key].keys, item.keys) then
        migrated[#migrated + 1] = item.file
      end
    end
    table.sort(migrated)
    report.count = #migrated
    report.compare_ms = (uv.hrtime() - started) / 1e6
    local cache = fs.join(vim.fs.dirname(cdb_path), ".cache", "clangd", "index")
    require("ue.index.shard_migration").invalidate(migrated, cache, report)
    pcall(function()
      local log = require("utils.log")
      local emit = #report.errors > 0 and log.warn_ctx or log.info_ctx
      emit("ue.index", "published main context migration", { context_migrated = report })
    end)
    return report
  end

  M.publish_semantic_cdb = function(ctx, state, generation)
    local base_path = M.base_compile_commands_path(ctx)
    if not base_path or not _ufs.is_file(base_path) then
      return false, "base compile_commands.json is unreadable"
    end
    local key = publication_key(ctx, state, generation, base_path)
    local cached = RT.publication_cache
    -- Tier 1 receipts refer to live inputs and may be changed independently of
    -- phase CDB stats. Recheck them before allowing an unchanged publication.
    if cached and not cached.has_tier1 and vim.deep_equal(cached.key, key) then
      return true, { entry_count = cached.entry_count,
        controlled_entry_count = cached.controlled_entry_count,
        shader_compatibility_count = cached.shader_compatibility_count, changed = false, original_changed = false,
        ordinary = cached.ordinary, context_migrated = empty_migration() }
    end
    RT.publication_cache = nil

    local merged, seen, frozen, frozen_seen, receipts, batches = {}, {}, {}, {}, {}, {}
    local tier1_batches, tier1_consumed, tier1_fallbacks, has_tier1 = {}, {}, {}, false
    local tier1_proposals, tier1_validated = {}, {}
    -- Reuse byte reads only within this publication. Phase manifests and stat
    -- identities cannot detect same-size live input edits between publications.
    local content_hashes = {}
    local function current_content_hash(path)
      if type(path) ~= "string" or path == "" or path:find("%z")
        or not fs.is_absolute_path(path) then return nil end
      if content_hashes[path] == nil then
        local content = _ufs.is_file(path) and core.deps.read_all(path) or nil
        content_hashes[path] = content and vim.fn.sha256(content) or false
      end
      return content_hashes[path] or nil
    end
    local function is_sha256(value)
      return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
    end
    local function tier1_fallback(phase, entry, reason, source)
      tier1_fallbacks[#tier1_fallbacks + 1] = { phase = phase, candidate = entry.file, reason = reason,
        original_source = source }
    end
    local function tier1_recover_originals(entry)
      local path, digest = entry.nvim_ue_tier1_receipt, entry.nvim_ue_tier1_receipt_sha256
      if type(path) ~= "string" or path == "" or type(digest) ~= "string" or digest == "" then return nil end
      local receipt, content = read_cdb(path)
      if not receipt or vim.fn.sha256(content) ~= digest or receipt.schema ~= 1
        or (receipt.tier ~= 1 and receipt.tier ~= 2)
        or type(receipt.original_entries) ~= "table" or not vim.islist(receipt.original_entries)
        or #receipt.original_entries == 0 then return nil end
      local keys = {}
      for _, original in ipairs(receipt.original_entries) do
        local key = entry_key(original)
        if not key or keys[key] then return nil end
        keys[key] = true
      end
      -- A sealed receipt can restore its old UBT commands when the phase's
      -- semantic file is lost. It cannot authorize its live candidate this way.
      return receipt.original_entries
    end
    local function tier1_receipt(entry, originals, phase_candidates)
      local path, digest = entry.nvim_ue_tier1_receipt, entry.nvim_ue_tier1_receipt_sha256
      if type(path) ~= "string" or path == "" or type(digest) ~= "string" or digest == "" then
        return nil, "tier1-receipt-identity-missing"
      end
      local candidate_key = entry_key(entry)
      if not candidate_key then return nil, "tier1-candidate-command-malformed" end
      if phase_candidates[candidate_key] ~= 1 then return nil, "tier1-candidate-repeated-in-phase" end
      local receipt, content = read_cdb(path)
      if not receipt or vim.fn.sha256(content) ~= digest then return nil, "tier1-receipt-sha256-mismatch" end
      if receipt.schema ~= 1 or (receipt.tier ~= 1 and receipt.tier ~= 2)
        or receipt.accepted ~= true or receipt.reusable ~= true
        or type(receipt.gates) ~= "table" or receipt.gates.compile_success ~= true
        or receipt.gates.main_shards_complete ~= true or receipt.gates.members_equal ~= true then
        return nil, "tier1-receipt-not-accepted"
      end
      if receipt.tier == 2 then
        if vim.env.NVIM_UE_TIER2 ~= "1" then return nil, "tier2-disabled" end
        if entry.nvim_ue_tier ~= 2 or receipt.gates.include_resolution_equal ~= true then
          return nil, "tier2-receipt-not-accepted"
        end
      elseif entry.nvim_ue_tier == 2 then
        return nil, "tier2-receipt-tier-mismatch"
      end
      if entry_key(receipt.candidate) ~= candidate_key then return nil, "tier1-candidate-command-mismatch" end
      if type(receipt.inputs) ~= "table" or not vim.islist(receipt.inputs) or #receipt.inputs == 0 then
        return nil, "tier1-inputs-missing"
      end
      for _, input in ipairs(receipt.inputs) do
        if type(input) ~= "table" or not is_sha256(input.sha256) then
          return nil, "tier1-input-identity-malformed"
        end
        if current_content_hash(input.path) ~= input.sha256 then return nil, "tier1-input-content-mismatch" end
      end
      if not is_sha256(receipt.candidate_sha256) then return nil, "tier1-candidate-content-identity-missing" end
      if current_content_hash(M.normalize_cdb_file(entry)) ~= receipt.candidate_sha256 then
        return nil, "tier1-candidate-content-mismatch"
      end
      if type(receipt.original_entries) ~= "table" or not vim.islist(receipt.original_entries)
        or #receipt.original_entries == 0 then return nil, "tier1-original-commands-missing" end
      if receipt.tier == 2 then
        local path_key = require("utils.platform").driver().path_key
        local inputs, definitions = {}, {}
        for _, input in ipairs(receipt.inputs) do inputs[path_key(fs.norm(input.path))] = true end
        for _, original in ipairs(receipt.original_entries) do
          local arguments, position = original.arguments or {}, 1
          while position <= #arguments do
            local argument, header = arguments[position], nil
            if argument == "-include" then
              header, position = arguments[position + 1], position + 1
            elseif type(argument) == "string" then
              header = argument:match("^%-include=(.+)$")
            end
            if type(header) == "string" and vim.fs.basename(fs.norm(header)):match("^Definitions%.") then
              header = fs.norm(header)
              if not fs.is_absolute_path(header) then header = fs.join(original.directory, header) end
              local key = path_key(header)
              if not inputs[key] then return nil, "tier2-definition-input-missing" end
              definitions[key] = true
            end
            position = position + 1
          end
        end
        if vim.tbl_count(definitions) < 2 then return nil, "tier2-definition-inputs-missing" end
      end
      if originals[candidate_key] then return nil, "tier1-candidate-aliases-original" end
      local consumed = {}
      for _, original in ipairs(receipt.original_entries) do
        local original_key = entry_key(original)
        if not original_key or not originals[original_key] then return nil, "tier1-phase-original-absent-or-changed" end
        if consumed[original_key] then return nil, "tier1-original-repeated-in-receipt" end
        consumed[original_key] = true
      end
      local previous = tier1_validated[candidate_key]
      if previous and (previous.path ~= path or previous.digest ~= digest) then
        return nil, "tier1-candidate-conflicting-receipts"
      end
      return { path = path, digest = digest, entry = entry, originals = consumed, key = candidate_key }
    end
    local shader_compatibility = {}
    local function add_entries(entries, target, keys)
      target, keys = target or merged, keys or seen
      if not vim.islist(entries) then return false end
      for _, entry in ipairs(entries or {}) do
        local key = entry_key(entry)
        if not key then return false end
        local file = M.normalize_cdb_file(entry)
        -- This route is emitted only after the producer's sealed exact-command
        -- identity matches. A shader suffix alone never authorizes exclusion.
        -- Active and phase semantic CDBs retain the original donor commands.
        if entry.nvim_ue_background_route == "shader-compatibility" then
          shader_compatibility[file:lower()] = true
        elseif file ~= "" and not keys[key] then
          keys[key] = true
          -- Phase artifacts retain nvim_ue_members/nvim_ue_module_root for the
          -- semantic sidecar. clangd's JSONCompilationDatabase parser rejects
          -- unknown keys, so its published view must contain standard fields
          -- only or the entire controlled BackgroundIndex silently disappears.
          target[#target + 1] = clangd_cdb_entry(entry)
        end
      end
      return true
    end
    local controlled_count = 0
    for _, phase in ipairs({ "current", "hot", "full" }) do
      local artifact = state.index_artifacts and state.index_artifacts[phase] or nil
      if artifact and artifact.generation_id == generation.generation_id then
        local entries, content = read_cdb(artifact.background_cdb_path)
        if not entries then
          return false, phase .. " controlled background CDB is unreadable"
        end
        if artifact.background_cdb_hash and artifact.background_cdb_hash ~= vim.fn.sha256(content) then
          return false, phase .. " controlled background CDB no longer matches its successful manifest"
        end
        local has_batch, phase_tier1, phase_candidates = false, false, {}
        for _, entry in ipairs(entries) do
          if type(entry) == "table" and entry.nvim_ue_tier1_receipt then
            has_tier1, phase_tier1 = true, true
            local candidate_key = entry_key(entry)
            if candidate_key then phase_candidates[candidate_key] = (phase_candidates[candidate_key] or 0) + 1 end
          end
        end
        local originals, semantic_content
        if phase_tier1 then
          originals, semantic_content = read_cdb(artifact.semantic_cdb_path)
          if not originals or not vim.islist(originals) or not artifact.semantic_cdb_hash
            or vim.fn.sha256(semantic_content) ~= artifact.semantic_cdb_hash then
            originals = nil
          end
        end
        local original_keys = {}
        for _, original in ipairs(originals or {}) do
          local original_key = entry_key(original)
          if original_key then original_keys[original_key] = true end
        end
        local frozen_entries, recovered_entries = {}, {}
        for _, entry in ipairs(entries) do
          if entry.nvim_ue_tier1_receipt then
            local admitted, reason, source
            if originals then admitted, reason = tier1_receipt(entry, original_keys, phase_candidates)
              source = "phase-semantic-cdb"
            else
              reason, source = "tier1-original-semantic-cdb-unavailable", "tier1-receipt-originals"
              local recovered = tier1_recover_originals(entry)
              if not recovered then
                return false, phase .. " Tier 1 has no verifiable original commands; prior publication retained"
              end
              for _, original in ipairs(recovered) do recovered_entries[#recovered_entries + 1] = original end
            end
            if admitted then
              tier1_validated[admitted.key] = admitted
              tier1_proposals[#tier1_proposals + 1] = { owner = admitted, phase = phase, source = source,
                -- Producer recomputes this witness from the entire phase input,
                -- only after canonical cache/receipt checks. It grants no proof.
                ordinary = phase == "full" and entry.nvim_ue_tier == 1
                  and entry.nvim_ue_tier1_recipe == nil and entry.nvim_ue_tier1_ordinary_chunk == true
                  and entry.nvim_ue_tier1_ordinary_source_count == #originals }
            else tier1_fallback(phase, entry, reason, source) end
          else
            frozen_entries[#frozen_entries + 1] = entry
            recovered_entries[#recovered_entries + 1] = entry
          end
          if entry.nvim_ue_batch_receipt and not entry.nvim_ue_tier1_receipt then
            has_batch = true
            local digest = entry.nvim_ue_batch_receipt_sha256
            if type(entry.nvim_ue_batch_receipt) ~= "string" or entry.nvim_ue_batch_receipt == ""
              or type(digest) ~= "string" or digest == ""
              or (receipts[entry.nvim_ue_batch_receipt] and receipts[entry.nvim_ue_batch_receipt] ~= digest) then
              return false, phase .. " batch receipt has no unambiguous content identity"
            end
            local candidate_key = entry_key(entry)
            if not candidate_key then return false, phase .. " batch command is malformed" end
            local receipt, receipt_content = read_cdb(entry.nvim_ue_batch_receipt)
            if not receipt or vim.fn.sha256(receipt_content) ~= digest or receipt.schema ~= 2
              or entry_key(receipt.candidate) ~= candidate_key
              or type(receipt.original_entries) ~= "table" or not vim.islist(receipt.original_entries)
              or #receipt.original_entries == 0 then
              return false, phase .. " batch receipt does not prove its published command"
            end
            if batches[candidate_key] and batches[candidate_key].path ~= entry.nvim_ue_batch_receipt then
              return false, phase .. " batch command has conflicting receipts"
            end
            batches[candidate_key] = { path = entry.nvim_ue_batch_receipt, originals = receipt.original_entries }
            receipts[entry.nvim_ue_batch_receipt] = digest
          end
        end
        if not add_entries(frozen_entries, frozen, frozen_seen) then
          return false, phase .. " controlled background command is malformed"
        end
        if has_batch then
          local strict_originals, strict_content = read_cdb(artifact.semantic_cdb_path)
          if not strict_originals or not artifact.semantic_cdb_hash
            or vim.fn.sha256(strict_content) ~= artifact.semantic_cdb_hash then
            return false, phase .. " verified batches require their original semantic CDB"
          end
          entries = strict_originals
        elseif phase_tier1 then
          -- Qualification was private; only its exact same-phase originals
          -- authorize live replacement. An unavailable authority cannot borrow
          -- commands from another phase or publish an unverified candidate.
          entries = originals or recovered_entries
        end
        local before = #merged
        if not add_entries(entries) then return false, phase .. " original semantic command is malformed" end
        controlled_count = controlled_count + (#merged - before)
      end
    end
    if controlled_count == 0 then
      return false, "no same-generation controlled translation units"
    end

    -- Resolve only fully validated proposals. A CURRENT full-input ordinary
    -- chunk may supersede earlier whole owners, never an arbitrary catalog
    -- subset, a partial receipt, a different recipe, or a nonreducing relabel.
    -- Invalid later candidates cannot erase valid current/hot authorities.
    for _, proposal in ipairs(tier1_proposals) do
      local owner, overlaps, covered = proposal.owner, {}, {}
      if not tier1_batches[owner.key] then
        for original_key in pairs(owner.originals) do
          local prior = tier1_consumed[original_key]
          if prior then overlaps[prior] = true end
        end
        local reason, previous = nil, 0
        for prior in pairs(overlaps) do
          previous = previous + 1
          for original_key in pairs(tier1_batches[prior].originals) do
            if not owner.originals[original_key] then reason = "tier1-partial-owner-replacement" end
            covered[original_key] = true
          end
        end
        for original_key in pairs(owner.originals) do
          if not covered[original_key] then previous = previous + 1 end
        end
        if next(overlaps) then
          if not proposal.ordinary then reason = "tier1-original-covered-more-than-once"
          elseif previous <= 1 then reason = reason or "tier1-replacement-does-not-reduce-tus" end
        end
        if reason then
          tier1_fallback(proposal.phase, owner.entry, reason, proposal.source)
        else
          for prior in pairs(overlaps) do
            for original_key in pairs(tier1_batches[prior].originals) do tier1_consumed[original_key] = nil end
            tier1_batches[prior] = nil
          end
          tier1_batches[owner.key] = owner
          for original_key in pairs(owner.originals) do tier1_consumed[original_key] = owner.key end
        end
      end
    end

    -- A later full phase contains the original UBT rows even when an earlier
    -- phase supplied a batch. Only its exact receipt originals may be consumed.
    local consumed, batch_fallbacks, excluded_batches = {}, {}, {}
    for candidate_key, batch in pairs(batches) do
      if seen[candidate_key] then return false, "batch command aliases an original command" end
      if tier1_batches[candidate_key] then return false, "batch command aliases a Tier 1 command" end
      for _, original in ipairs(batch.originals) do
        local original_key = entry_key(original)
        if not original_key or not seen[original_key] then
          return false, "batch original command is absent or changed"
        end
        if consumed[original_key] then return false, "batch original command is covered more than once" end
        consumed[original_key] = true
        if tier1_consumed[original_key] then excluded_batches[candidate_key] = true end
      end
    end
    -- Keep the admitted live Tier 1 baseline. A strict receipt is indivisible:
    -- any original already replaced by Tier 1 defers that entire strict batch.
    for candidate_key in pairs(excluded_batches) do
      local batch = batches[candidate_key]
      receipts[batch.path] = nil
      for _, original in ipairs(batch.originals) do consumed[entry_key(original)] = nil end
      batch_fallbacks[#batch_fallbacks + 1] = { receipt = batch.path, reason = "tier1-original-overlap" }
    end
    table.sort(batch_fallbacks, function(a, b) return a.receipt < b.receipt end)
    local selected, selected_seen = {}, {}
    for _, entry in ipairs(frozen) do
      local candidate_key = entry_key(entry)
      if not batches[candidate_key] and not seen[candidate_key] then
        return false, "background command is not a proven original or batch"
      end
      if not consumed[candidate_key] and not excluded_batches[candidate_key] then
        selected[#selected + 1] = entry
        selected_seen[candidate_key] = true
      end
    end
    for _, entry in ipairs(merged) do
      local original_key = entry_key(entry)
      if not consumed[original_key] and not selected_seen[original_key] then
        selected[#selected + 1] = entry
        selected_seen[original_key] = true
      end
    end
    frozen = selected

    -- Tier 1 uses the same live wrapper command in both views; strict activation
    -- retains it as an original, never as a frozen receipt. Its receipt binds
    -- wrapper/member source bytes, tool and environment; header changes do not
    -- invalidate it. This is the explicitly accepted Tier 1 tradeoff.
    local function project_tier1(entries)
      local projected, projected_seen = {}, {}
      for _, entry in ipairs(entries) do
        local original_key = entry_key(entry)
        local candidate_key = tier1_consumed[original_key]
        if candidate_key then
          if not projected_seen[candidate_key] then
            projected[#projected + 1] = clangd_cdb_entry(tier1_batches[candidate_key].entry)
            projected_seen[candidate_key] = true
          end
        elseif not projected_seen[original_key] then
          projected[#projected + 1] = entry
          projected_seen[original_key] = true
        end
      end
      return projected
    end
    merged = project_tier1(merged)
    if next(receipts) and next(tier1_batches) then frozen = project_tier1(frozen) end
    controlled_count = #merged

    -- Reordering unique unchanged files only reprioritizes an existing queue.
    -- Keep its bytes/mtime; same-file variants retain order-sensitive comparison.
    local previous = read_cdb(ctx.paths.semantic_cdb)
    local original_changed = not same_publication(previous, merged)
    local original_append_only = original_changed and append_only(previous, merged) or false
    local batch_info_path = fs.join(vim.fs.dirname(ctx.paths.semantic_cdb), "batches.json")
    local ordinary = next(receipts) == nil and require("ue.index.batch_metadata").is_ordinary(batch_info_path)
    if M._defer_append then
      local deferred = original_append_only and ordinary and state.index_selection
        and state.index_selection.generation_id == generation.generation_id or false
      return true, { deferred = deferred, original_append_only = original_append_only, ordinary = ordinary }
    end
    local changed = original_changed
    local context_migrated = empty_migration()
    if changed then
      local ok, err = atomic_write_json(ctx.paths.semantic_cdb, merged)
      if not ok then return false, err end
      -- The live view is committed now. Do not defer invalidation past optional
      -- frozen metadata writes: if one fails, a retry has already lost previous.
      -- Large CDBs run this entire function in the existing publication worker.
      context_migrated = invalidate_migrated_mains(previous, merged, ctx.paths.semantic_cdb)
    end
    -- Strict batches retain their separate CDB/shard environment and input
    -- guard. Tier 1 above is qualified for live source commands and never
    -- contributes a frozen receipt or preseeded shard.
    local receipt_paths = vim.tbl_keys(receipts)
    table.sort(receipt_paths)
    if #receipt_paths > 0 then
      local frozen_path = fs.join(vim.fs.dirname(ctx.paths.semantic_cdb), "verified", "compile_commands.json")
      local frozen_changed = not same_publication(read_cdb(frozen_path), frozen)
      if frozen_changed then
        local ok, err = atomic_write_json(frozen_path, frozen)
        if not ok then return false, err end
      end
      local info = { schema = 1, receipts = receipt_paths, original_cdb = ctx.paths.semantic_cdb,
        receipt_hashes = receipts,
        original_sha256 = vim.fn.sha256(core.deps.read_all(ctx.paths.semantic_cdb)),
        active_cdb = base_path, active_digest = generation.cdb_digest,
        verified_cdb = frozen_path, verified_sha256 = vim.fn.sha256(core.deps.read_all(frozen_path)),
        generation_id = generation.generation_id, watch_bases = {
          fs.join(ctx.engine_root, "Engine", "Source"), fs.join(ctx.engine_root, "Engine", "Plugins"),
          fs.join(ctx.engine_root, "Engine", "Intermediate"),
          fs.join(ctx.project_root, "Source"), fs.join(ctx.project_root, "Plugins"),
          fs.join(ctx.project_root, "Intermediate"),
        } }
      if not vim.deep_equal(read_cdb(batch_info_path), info) then
        local ok, err = atomic_write_json(batch_info_path, info)
        if not ok then return false, err end
        changed = true
      end
      changed = changed or frozen_changed
    elseif _ufs.is_file(batch_info_path) then
      if M._publication_guard then M._publication_guard() end
      -- unlink is the atomic transition to ordinary publication. A failed
      -- removal must not leave a successful/cached publication behind.
      local ok, err = vim.uv.fs_unlink(batch_info_path)
      if not ok then return false, "batch metadata removal failed: " .. tostring(err) end
      changed = true
    end
    ordinary = #receipt_paths == 0
    -- Cache only the last verified publication's small identities/counts.
    -- Phase bytes/argv stay collectible, and any changed input or output stat
    -- takes the full manifest verification path on the next call.
    key.published[2] = file_signature(ctx.paths.semantic_cdb)
    key.batches = file_signature(batch_info_path)
    local shader_count = vim.tbl_count(shader_compatibility)
    RT.publication_cache = { key = key, entry_count = #merged,
      controlled_entry_count = controlled_count, shader_compatibility_count = shader_count, ordinary = ordinary,
      has_tier1 = has_tier1 }
    return true, {
      entry_count = #merged,
      controlled_entry_count = controlled_count,
      shader_compatibility_count = shader_count,
      changed = changed,
      original_changed = original_changed,
      context_migrated = context_migrated,
      ordinary = ordinary,
      tier1_fallbacks = tier1_fallbacks,
      batch_fallbacks = batch_fallbacks,
      -- Frozen activation owns its independent reader/cache and cannot use the
      -- ordinary directory reload path, even if original rows only grew.
      original_append_only = original_append_only and ordinary,
    }
  end
  require("ue.index._publication_async")(M, core)
end
