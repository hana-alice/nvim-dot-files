-- ue.index._clangd — clangd restart / index promote / .clangd sync.
-- Extracted verbatim from lua/ue.lua (F1 split phase-1).
return function(M, core)
  local fs = require("ue.core.fs")
  local _ufs = fs
  local _uplat = require("utils.platform")
  local _uproc = require("ue.core.proc")
  local RT = core.RT
  local unix_now = core.h.unix_now

M.maybe_restart_clangd_for_index = function()
  local now = unix_now()
  if (now - RT.last_restart_at) < RT.restart_debounce_s then
    return
  end
  RT.last_restart_at = now

  -- Snapshot which buffers had clangd attached BEFORE we stop, so we can
  -- explicitly re-attach to each of them. The previous version only ran
  -- `:edit` on the *current* buffer, which silently no-op'd whenever the
  -- user was sitting in a picker / log / non-cpp buffer when the index
  -- finished. clangd then stayed dead until the user noticed `gd` was slow,
  -- by which time goto-def was falling back to treesitter or nothing.
  local clients = vim.lsp.get_clients({ name = "clangd" })
  if #clients == 0 then
    return
  end

  local cpp_bufs = {}
  for _, client in ipairs(clients) do
    for buf, _ in pairs(client.attached_buffers or {}) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        cpp_bufs[buf] = true
      end
    end
    client:stop()
  end

  -- Also include any cpp/c/h buffers that exist but weren't attached (e.g.
  -- a fresh open during the restart window) — better to over-restart than
  -- miss them.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local ft = vim.bo[b].filetype
      if ft == "cpp" or ft == "c" or ft == "h" or ft == "objcpp" or ft == "objc" then
        cpp_bufs[b] = true
      end
    end
  end

  vim.defer_fn(function()
    for buf, _ in pairs(cpp_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("LspStart clangd")
        end)
      end
    end
  end, 500)
end

M.promote_active_index = function(ctx, src_path)
  src_path = fs.norm(src_path)
  if src_path == "" or not _ufs.is_file(src_path) then
    return false
  end
  _ufs.ensure_dir(ctx.paths.active_index_dir)
  local content = core.deps.read_all(src_path)
  if not content or content == "" then
    return false
  end
  return core.deps.write_all(ctx.paths.active_index, content)
end

-- Keep `.clangd`'s `Index.External.File` / `Index.External.MountPoint` lines
-- in sync with the authoritative `cache_paths(engine_root).active_index` path
-- — at the ENGINE root AND, when the project lives outside the engine tree
-- (typical: engine on D:, project on E:), at the PROJECT root too.
--
-- WHY both: clangd discovers `.clangd` by walking UP from each source file.
-- A project file on E: never reaches the engine-root `.clangd` on D:, so it
-- gets NO `Background: Skip` → clangd background-indexes every project TU
-- (~half the CDB) with up to -j=24 workers after every UEPrepare CDB regen.
-- Observed 2026-07-24: 14.5k shards actively written under
-- %LocalAppData%/clangd/index (the fallback shard dir for files outside the
-- compile-commands dir) — the "clangd eats all CPU/RAM after UEPrepare"
-- symptom. The active idx is built from the FULL cdb (engine + project TUs),
-- so mounting the same file at the project root is correct.
--
-- Surgical: only the `Index.External.{File,MountPoint}` keys are touched
-- (or an `Index:` block is appended if absent). All other content
-- (CompileFlags `/vctoolsdir` MSVC pin, Diagnostics, comments, etc.)
-- is preserved byte-for-byte. Idempotent: re-running with the same
-- paths is a no-op (no write, no clangd restart amplification).
--
-- Why this lives here: the v3 cache migration moved idx from
-- `<root>/.clangd-index/` to `<root>/.cache/nvim-ue/clangd/index/`, but
-- nobody rewrote existing `.clangd` files. Result: clangd silently fell
-- back to `--background-index`, burning 17 GB RAM / 32 min CPU per cold
-- open. The hot/full/current pipeline is now responsible for keeping
-- `.clangd` honest.
M.sync_one_dot_clangd = function(clangd_path, want_file, want_mount)
  local existing = ""
  if _ufs.is_file(clangd_path) then
    existing = core.deps.read_all(clangd_path) or ""
  end

  local new_content
  if existing == "" then
    -- No .clangd at all → write a minimal one. Background: Skip is
    -- required since we have an external idx and don't want clangd
    -- redoing the work.
    new_content = table.concat({
      "Index:",
      "  External:",
      "    File: " .. want_file,
      "    MountPoint: " .. want_mount,
      "  Background: Skip",
      "",
    }, "\n")
  else
    -- Find Index: block. If present, edit its External sub-block in place.
    -- If absent, append a fresh Index: block.
    local has_index = existing:match("\n?Index:%s*\n") or existing:match("^Index:%s*\n")
    if has_index then
      -- Replace `    File: ...` / `    MountPoint: ...` lines under
      -- `  External:` if present; inject an External: sub-block if not.
      local has_external = existing:match("\n%s*External:%s*\n") or existing:match("^%s*External:%s*\n")
      if has_external then
        -- gsub a single line at a time: tolerate any leading-whitespace
        -- indent, replace the trailing value.
        local edited = existing
        -- File: ...
        local file_replaced
        edited, file_replaced = edited:gsub("(\n%s*External:[^\n]*\n[^\n]-\n?)(%s*)File:%s*[^\n]*", function(prefix, indent)
          return prefix .. indent .. "File: " .. want_file
        end, 1)
        if file_replaced == 0 then
          -- External: existed but had no File: line; inject after External:
          edited = edited:gsub("(\n)(%s*)External:%s*\n", function(nl, indent)
            return nl .. indent .. "External:\n" .. indent .. "  File: " .. want_file .. "\n" .. indent .. "  MountPoint: " .. want_mount .. "\n"
          end, 1)
        else
          -- MountPoint: ...
          local mp_replaced
          edited, mp_replaced = edited:gsub("(\n%s*External:[^\n]*\n[^\n]-\n?)(%s*)MountPoint:%s*[^\n]*", function(prefix, indent)
            return prefix .. indent .. "MountPoint: " .. want_mount
          end, 1)
          if mp_replaced == 0 then
            -- File: was replaced but no MountPoint: line; inject right after File:
            edited = edited:gsub("(%s*)File:%s*" .. want_file:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), function(indent)
              return indent .. "File: " .. want_file .. "\n" .. indent .. "MountPoint: " .. want_mount
            end, 1)
          end
        end
        new_content = edited
      else
        -- Index: exists but no External: sub-block. Inject one right
        -- after the Index: header line.
        new_content = existing:gsub("(\n?)(Index:%s*\n)", function(nl, hdr)
          return nl .. hdr .. "  External:\n    File: " .. want_file .. "\n    MountPoint: " .. want_mount .. "\n  Background: Skip\n"
        end, 1)
      end
    else
      -- No Index: block at all. Append one at EOF, separated by a blank line.
      local sep = (existing:sub(-1) == "\n") and "" or "\n"
      new_content = existing .. sep .. "\nIndex:\n  External:\n    File: " .. want_file .. "\n    MountPoint: " .. want_mount .. "\n  Background: Skip\n"
    end
  end

  if new_content == existing then
    return true, "unchanged"
  end

  -- Atomic write: tmp + rename. NTFS rename is atomic; clangd never sees
  -- a half-written file mid-read.
  local tmp_path = clangd_path .. ".tmp." .. tostring(vim.uv.hrtime())
  local ok = core.deps.write_all(tmp_path, new_content)
  if not ok then
    pcall(vim.fn.delete, tmp_path)
    return false, "tmp write failed"
  end
  local rn_ok, rn_err = (vim.uv or vim.loop).fs_rename(tmp_path, clangd_path)
  if not rn_ok then
    pcall(vim.fn.delete, tmp_path)
    return false, "rename failed: " .. tostring(rn_err)
  end
  return true, "updated"
end

M.sync_dot_clangd = function(ctx)
  if not ctx or not ctx.engine_root or ctx.engine_root == "" then
    return false, "no engine_root"
  end
  local idx_path = ctx.paths and ctx.paths.active_index
  if not idx_path or idx_path == "" then
    return false, "no active_index path"
  end

  -- Native-slashes on Windows for consistency with how UBT writes paths
  -- elsewhere in the cdb. clangd accepts both, but pinning one form lets
  -- a textual diff stay clean across runs.
  local function native(p)
    if _uplat.is_windows then
      return (p:gsub("/", "\\"))
    end
    return p
  end
  local want_file = native(idx_path)

  -- Engine root: mount = engine root (covers all D:-side engine TUs).
  local ok_e, msg_e = M.sync_one_dot_clangd(
    ctx.engine_root .. "/.clangd", want_file, native(ctx.engine_root))

  -- Project root OUTSIDE the engine tree: needs its own .clangd or clangd
  -- background-indexes the whole project half of the CDB (the post-UEPrepare
  -- CPU/RAM burn). Same idx file; mount = project root. Skip when the
  -- project lives under the engine root (upward search finds the engine
  -- .clangd already).
  local proot = ctx.project_root
  if proot and proot ~= "" then
    local proot_n = fs.norm(proot)
    local eroot_n = fs.norm(ctx.engine_root)
    local under_engine = proot_n:lower():sub(1, #eroot_n + 1) == (eroot_n:lower() .. "/")
      or proot_n:lower() == eroot_n:lower()
    if not under_engine then
      local ok_p, msg_p = M.sync_one_dot_clangd(
        proot_n .. "/.clangd", want_file, native(proot_n))
      if not ok_p then
        return ok_e, (msg_e or "") .. "; project .clangd: " .. tostring(msg_p)
      end
    end
  end
  return ok_e, msg_e
end
end
