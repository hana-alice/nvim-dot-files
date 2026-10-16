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
-- replies with -32602 InvalidParams. The autocmd `LspAttach` is already
-- too late to prevent didOpen. In Neovim 0.11.5, synchronously detaching
-- inside LspAttach also lets Client:on_attach restore attached_buffers after
-- changetracking was reset, so a later buffer deletion resets missing state.
--
-- We check the buffer name's URI scheme rather than its filetype because:
--   * schemes are compared case-insensitively (`fugitive`, `diffview`,
--     `gitsigns`, `oil`, `octo`, `neogit`, ...)
--   * future plugins that introduce new schemes will be caught
--     without a code change here, since we WHITELIST file:// rather
--     than blacklist known offenders
--   * empty-name scratch buffers also get caught
--     and they have no business holding a clangd session anyway
--
-- Guard the public attach entry and each clangd's deferred on_attach before
-- didOpen. A scheduled event fallback handles callers holding the old entry;
-- it must run after Client:on_attach has finished setting its attached flag.

local M = {}

local applied = false
local AUGROUP_NAME = "workaround_clangd_non_file_uri_detach"
local detached_count = 0
local blocked_count = 0
local original_attach, guarded_attach
local guarded_clients = setmetatable({}, { __mode = "k" })
local uri = require("utils.buffer_uri")

-- Returns true if this buffer's URI is anything other than file://.
-- Empty-name scratch buffers also count as non-file.
local function is_non_file_uri(buf)
  return not uri.is_file_buffer(buf)
end

local function guard_client(client)
  if guarded_clients[client] or type(client.on_attach) ~= "function" then return end
  local original, previous = client.on_attach, rawget(client, "on_attach")
  local guarded = function(self, buf)
    if not applied then return original(self, buf) end
    if not vim.api.nvim_buf_is_valid(buf) or is_non_file_uri(buf) then
      -- Deferred initialization has not entered changetracking/didOpen.
      self.attached_buffers[buf] = nil
      blocked_count = blocked_count + 1
      return
    end
    return original(self, buf)
  end
  guarded_clients[client] = { previous = previous, guarded = guarded }
  client.on_attach = guarded
end

local function on_attach(args)
  local buf       = args.buf
  local client_id = args.data and args.data.client_id
  if not client_id then return end

  local client = vim.lsp.get_client_by_id(client_id)
  if not client or client.name ~= "clangd" then return end

  if not is_non_file_uri(buf) then return end
  vim.schedule(function()
    if not applied or not vim.api.nvim_buf_is_valid(buf) or not is_non_file_uri(buf)
      or vim.lsp.get_client_by_id(client_id) ~= client
      or not vim.lsp.buf_is_attached(buf, client_id) then return end
    if pcall(vim.lsp.buf_detach_client, buf, client_id) then detached_count = detached_count + 1 end
  end)
end

function M.apply()
  if applied then return end
  applied = true

  local attach = vim.lsp.buf_attach_client
  original_attach = attach
  guarded_attach = function(buf, id)
    if not applied then return attach(buf, id) end
    local resolved = buf == 0 and vim.api.nvim_get_current_buf() or buf
    local client = vim.lsp.get_client_by_id(id)
    if client and client.name == "clangd" then
      if vim.api.nvim_buf_is_valid(resolved) and is_non_file_uri(resolved) then
        blocked_count = blocked_count + 1
        return false
      end
      guard_client(client)
    end
    return attach(buf, id)
  end
  vim.lsp.buf_attach_client = guarded_attach

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
  if vim.lsp.buf_attach_client == guarded_attach then vim.lsp.buf_attach_client = original_attach end
  for client, saved in pairs(guarded_clients) do
    if client.on_attach == saved.guarded then client.on_attach = saved.previous end
  end
  guarded_clients = setmetatable({}, { __mode = "k" })
end

function M.status()
  return { applied = applied, detached_count = detached_count, blocked_count = blocked_count }
end

return M
