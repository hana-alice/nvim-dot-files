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
    _ufs.ensure_dir(vim.fs.dirname(path))
    local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
    if not core.deps.write_all(tmp, vim.json.encode(value)) then
      pcall(vim.fn.delete, tmp)
      return false, "temporary write failed"
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

  M.publish_semantic_cdb = function(ctx, state, generation)
    local base_path = M.base_compile_commands_path(ctx)
    if not base_path or not _ufs.is_file(base_path) then
      return false, "base compile_commands.json is unreadable"
    end
    local key = publication_key(ctx, state, generation, base_path)
    local cached = RT.publication_cache
    if cached and vim.deep_equal(cached.key, key) then
      return true, { entry_count = cached.entry_count,
        controlled_entry_count = cached.controlled_entry_count,
        shader_compatibility_count = cached.shader_compatibility_count, changed = false }
    end
    RT.publication_cache = nil

    local merged, seen, frozen, frozen_seen, receipts, batches = {}, {}, {}, {}, {}, {}
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
        local has_batch = false
        for _, entry in ipairs(entries) do
          if entry.nvim_ue_batch_receipt then
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
        if not add_entries(entries, frozen, frozen_seen) then
          return false, phase .. " controlled background command is malformed"
        end
        if has_batch then
          local originals, semantic_content = read_cdb(artifact.semantic_cdb_path)
          if not originals or not artifact.semantic_cdb_hash
            or vim.fn.sha256(semantic_content) ~= artifact.semantic_cdb_hash then
            return false, phase .. " verified batches require their original semantic CDB"
          end
          entries = originals
        end
        local before = #merged
        if not add_entries(entries) then return false, phase .. " original semantic command is malformed" end
        controlled_count = controlled_count + (#merged - before)
      end
    end
    if controlled_count == 0 then
      return false, "no same-generation controlled translation units"
    end

    -- A later full phase contains the original UBT rows even when an earlier
    -- phase supplied a batch. Only its exact receipt originals may be consumed.
    local consumed = {}
    for candidate_key, batch in pairs(batches) do
      if seen[candidate_key] then return false, "batch command aliases an original command" end
      for _, original in ipairs(batch.originals) do
        local original_key = entry_key(original)
        if not original_key or not seen[original_key] then
          return false, "batch original command is absent or changed"
        end
        if consumed[original_key] then return false, "batch original command is covered more than once" end
        consumed[original_key] = true
      end
    end
    local selected, selected_seen = {}, {}
    for _, entry in ipairs(frozen) do
      local candidate_key = entry_key(entry)
      if not batches[candidate_key] and not seen[candidate_key] then
        return false, "background command is not a proven original or batch"
      end
      if not consumed[candidate_key] then
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

    -- Reordering unique unchanged files only reprioritizes an existing queue.
    -- Keep its bytes/mtime; same-file variants retain order-sensitive comparison.
    local changed = not same_publication(read_cdb(ctx.paths.semantic_cdb), merged)
    if changed then
      local ok, err = atomic_write_json(ctx.paths.semantic_cdb, merged)
      if not ok then return false, err end
    end
    -- The normal path ALWAYS remains the live original-UBT database. Frozen
    -- batches have their own CDB and shard environment; only the asynchronous
    -- input/watch guard may select them. A partial publication cannot make an
    -- unguarded client silently consume snapshots.
    local batch_info_path = fs.join(vim.fs.dirname(ctx.paths.semantic_cdb), "batches.json")
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
      local empty = { schema = 1, receipts = {} }
      if not vim.deep_equal(read_cdb(batch_info_path), empty) then
        local ok, err = atomic_write_json(batch_info_path, empty)
        if not ok then return false, err end
        changed = true
      end
    end
    -- Cache only the last verified publication's small identities/counts.
    -- Phase bytes/argv stay collectible, and any changed input or output stat
    -- takes the full manifest verification path on the next call.
    key.published[2] = file_signature(ctx.paths.semantic_cdb)
    local shader_count = vim.tbl_count(shader_compatibility)
    RT.publication_cache = { key = key, entry_count = #merged,
      controlled_entry_count = controlled_count, shader_compatibility_count = shader_count }
    return true, {
      entry_count = #merged,
      controlled_entry_count = controlled_count,
      shader_compatibility_count = shader_count,
      changed = changed,
    }
  end
end
