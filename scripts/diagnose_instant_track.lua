-- diagnose_instant_track.lua
-- 完整模拟 M.definition() 的 instant track，每一步打印中间结果。
-- 用法：光标停在出问题的 symbol 上，:luafile <这个文件>，看 :messages

local lsp_fb_path = "utils.lsp_fallback"
package.loaded[lsp_fb_path] = nil  -- 强制重新加载
local fb = require(lsp_fb_path)

local bufnr = vim.api.nvim_get_current_buf()
local cur = vim.api.nvim_win_get_cursor(0)
local symbol = vim.fn.expand("<cword>")
local ref_file = vim.api.nvim_buf_get_name(bufnr):gsub("\\", "/")
local ref_line = cur[1]

print("=== instant track trace ===")
print(string.format("buf=%d line=%d symbol=%q", bufnr, ref_line, symbol))
print(string.format("ref_file=%s", ref_file))

-- We can't easily reach into the local async_lsp_workspace_symbol from here,
-- so re-fire the raw clangd request and replicate the helper's filtering
-- inline, then walk through every gate in the instant track.

local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" })
print(string.format("[step] %d ws/symbol clients", #clients))

local DEFINITION_KINDS = {
  [5]=true,[6]=true,[7]=true,[8]=true,[9]=true,[10]=true,[11]=true,
  [12]=true,[13]=true,[14]=true,[22]=true,[23]=true,[24]=true,[25]=true,
}

local t0 = vim.uv.hrtime()
for _, c in ipairs(clients) do
  c:request("workspace/symbol", { query = symbol }, function(err, result)
    local dt = (vim.uv.hrtime() - t0) / 1e6
    print(string.format("[step] %s reply in %.0fms err=%s n_raw=%d",
      c.name, dt, tostring(err), result and #result or 0))
    if not result then return end

    -- replicate filter
    local merged = {}
    for _, sym in ipairs(result) do
      local keep = true
      local why = ""
      if sym.name ~= symbol then keep = false; why = "name~="..tostring(sym.name) end
      if keep and sym.kind and not DEFINITION_KINDS[sym.kind] then
        keep = false; why = "kind="..tostring(sym.kind).." not in DEFINITION_KINDS"
      end
      if keep and not (sym.location and sym.location.uri and sym.location.range) then
        keep = false; why = "missing location/uri/range"
      end
      print(string.format("[step]   sym name=%q kind=%s keep=%s %s",
        sym.name or "?", tostring(sym.kind), tostring(keep), why))
      if keep then
        table.insert(merged, {
          uri = sym.location.uri,
          range = sym.location.range,
          _ws_kind = sym.kind,
        })
      end
    end
    print(string.format("[step] after filter: %d kept", #merged))
    if #merged == 0 then return end

    -- INSTANT_MAX_CANDIDATES gate (50)
    if #merged > 50 then
      print("[step] BAILED: > 50 candidates")
      return
    end

    -- filter_self_locations replication: a Location is "self" if it points to
    -- ref_file at ref_line ± 1 (rough — we don't have the exact local function)
    local kept = {}
    for _, loc in ipairs(merged) do
      local p = (loc.uri or ""):gsub("^file://", ""):gsub("^/", ""):gsub("\\", "/")
      local rline = loc.range and loc.range.start and loc.range.start.line or -1
      local self_match = (p:lower() == ref_file:lower()) and math.abs(rline + 1 - ref_line) <= 1
      print(string.format("[step]   loc uri=%s line=%d self=%s",
        p:sub(-60), rline, tostring(self_match)))
      if not self_match then table.insert(kept, loc) end
    end
    print(string.format("[step] after self-filter: %d", #kept))

    if #kept == 0 then
      print("[step] BAILED: all filtered as self-references")
      return
    end

    -- Try to call jump_to_location via the public API:
    -- The location is in the right shape. Let's just try vim.lsp.util.show_document.
    local first = kept[1]
    print(string.format("[step] would jump to: uri=%s line=%d",
      first.uri, first.range.start.line))
    print("[step] (not actually jumping — diagnostic only)")
    print("[step] === expected behavior: M.definition() should jump here ===")
  end, bufnr)
end
