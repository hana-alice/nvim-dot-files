-- WORKAROUND
-- name: clangd.non_file_uri_detach
-- scope: clangd
-- issue: clangd hard-rejects every textDocument/* request whose URI scheme is not file://. nvim's lsp client doesn't filter by scheme, so when clangd auto-attaches to a buffer with a synthetic URI (fugitive://, diffview://, gitsigns://, oil://, etc.) every CursorHold fires textDocument/documentHighlight and clangd answers with -32602 "clangd only supports file:// URIs". The screen fills with red.
-- symptom: After opening diffview / Neogit diff / fugitive history / gitsigns blame on a C++ file, the lower-right notify area scrolls "clangd: -32602: failed to decode textDocument/documentHighlight request: clangd only supports file:// URIs" repeatedly. Worse on Neovide because each notify forces a redraw.
-- introduced: 2026-05-07
-- removal_condition: nvim core gains a per-client URI-scheme filter (see https://github.com/neovim/neovim/issues/22338-style discussions) OR clangd starts ignoring unknown-scheme buffers gracefully instead of erroring.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- WHY
-- ---
-- clangd's compile-database lookup keys on filesystem paths. A buffer
-- backed by `fugitive:///D:/foo//<sha>/bar.cpp` has no on-disk path,
-- so clangd cannot honour any LSP request scoped to that URI and
-- replies with -32602 InvalidParams. The autocmd `LspAttach` is the
-- right hook: clangd has just attached, but **no requests have flown
-- yet**, so a single buf_detach_client call removes it cleanly with
-- zero error spam.
--
-- We check by URI scheme rather than buffer name because:
--   * scheme is always lowercased and stable (`fugitive`, `diffview`,
--     `gitsigns`, `oil`, `octo`, `neogit`, ...)
--   * future plugins that introduce new schemes will be caught
--     without a code change here, since we WHITELIST file:// rather
--     than blacklist known offenders
--   * empty-name scratch buffers also get caught (uri = "buffer://N")
--     and they have no business holding a clangd session anyway
--
-- We deliberately do NOT prevent clangd from attaching in the first
-- place via the lspconfig `root_dir` callback: that path doesn't see
-- the URI scheme reliably, and turning attach off plugin-wide would
-- regress the normal `file://` flow if a synthetic URI buffer is open
-- when nvim starts. Detaching post-attach is one extra LSP frame but
-- has no observable cost.

local M = {}

local applied = false
local AUGROUP_NAME = "workaround_clangd_non_file_uri_detach"
local detached_count = 0

-- Returns true if this buffer's URI is anything other than file://.
-- Empty-name buffers also count as non-file (they get "buffer://N").
local function is_non_file_uri(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return true end
  -- Cheap prefix check first; vim.uri_from_fname handles edge cases
  -- but is more expensive. The "://" sentinel matches every URI scheme.
  -- Real on-disk paths never contain "://" before a path separator.
  --
  -- IMPORTANT: on Windows, plain paths look like `D:/foo/bar.cpp` and a
  -- naive `^(%w[%w+.-]*):/` match would treat the drive letter `D` as a
  -- URI scheme and detach clangd from EVERY real file. Real URI schemes
  -- are always >=2 chars (file/http/oil/fugitive/gitsigns/diffview/...),
  -- and Windows drive letters are exactly 1 char, so requiring length>=2
  -- cleanly disambiguates. We additionally require `://` (two slashes)
  -- because that's the actual URI grammar, while `D:/` only has one.
  local scheme = name:match("^(%a[%w+.-]+)://")
  if not scheme then
    -- Plain path (incl. Windows `D:/...`) — treat as file://
    return false
  end
  if scheme == "file" then
    return false
  end
  return true, scheme
end

local function on_attach(args)
  local buf       = args.buf
  local client_id = args.data and args.data.client_id
  if not client_id then return end

  local client = vim.lsp.get_client_by_id(client_id)
  if not client or client.name ~= "clangd" then return end

  local non_file, scheme = is_non_file_uri(buf)
  if not non_file then return end

  -- Detach. Use the modern API when available (vim.lsp.buf_detach_client
  -- was deprecated for 0.10+ in favor of client:detach), but fall back
  -- so this works across the version range we support.
  local ok
  if type(client.detach) == "function" then
    ok = pcall(function() client:detach(buf) end)
  end
  if not ok then
    pcall(vim.lsp.buf_detach_client, buf, client_id)
  end

  detached_count = detached_count + 1
  -- Single quiet log line per detach, scoped so it doesn't notify.
  -- Use the project's scoped logger if available; fall back to the
  -- default vim.lsp.log to be safe in early-load scenarios.
  local ok_log, log = pcall(require, "utils.log")
  if ok_log and log.scoped then
    local L = log.scoped("workarounds.clangd")
    L.debug(string.format(
      "detached clangd from buf %d (scheme=%s, name=%s)",
      buf, scheme or "?", vim.api.nvim_buf_get_name(buf)))
  end
end

function M.apply()
  if applied then return end
  applied = true

  local group = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group    = group,
    callback = on_attach,
    desc     = "Detach clangd from non-file:// buffers (workarounds.clangd.non_file_uri_detach)",
  })
end

function M.disable()
  applied = false
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP_NAME)
end

function M.status()
  return { applied = applied, detached_count = detached_count }
end

return M
