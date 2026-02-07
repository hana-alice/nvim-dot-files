local M = {}

local function _norm(p)
  return (tostring(p or ""):gsub("\\", "/"))
end

local function _buf_symbol()
  local w = vim.fn.expand("<cword>")
  return w ~= "" and w or nil
end

local function _lsp_references_sync(timeout_ms)
  local params = vim.lsp.util.make_position_params(0, "utf-8")
  params.context = { includeDeclaration = true }
  local res = vim.lsp.buf_request_sync(0, "textDocument/references", params, timeout_ms or 800)
  if not res then return nil end

  local items = {}
  for _, r in pairs(res) do
    if r.result and type(r.result) == "table" then
      vim.list_extend(items, r.result)
    end
  end
  return items
end

local function _qf_from_locations(title, locations)
  local items = vim.lsp.util.locations_to_items(locations, "utf-8")
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("copen")
end

local function _global_lines(root, args)
  if vim.fn.executable("global") == 0 then
    return 127, { "global (GNU Global) not found in PATH" }
  end
  local cmd = vim.tbl_flatten({ "global", args })
  if vim.system then
    local r = vim.system(cmd, { text = true, cwd = root }):wait()
    local out = (r.stdout or "") .. (r.stderr or "")
    local lines = {}
    for s in out:gmatch("[^\r\n]+") do
      table.insert(lines, s)
    end
    return r.code or 0, lines
  end
  local joined = table.concat(cmd, " ")
  local lines = vim.fn.systemlist(joined)
  return vim.v.shell_error or 0, lines
end

local function _gtags_ready(root)
  root = _norm(root)
  return vim.fn.filereadable(root .. "/GTAGS") == 1
end

local function _try_gtags_references(root, symbol)
  if not _gtags_ready(root) then
    return false
  end

  -- --result=grep => file:line:...
  local code, lines = _global_lines(root, { "-r", "--result=grep", symbol })
  if code ~= 0 and code ~= 1 then
    return false
  end
  if not lines or #lines == 0 then
    return false
  end

  -- quickfix: file:ln:col:text（补 col=1）
  local qf = {}
  for _, l in ipairs(lines) do
    local f, ln, rest = l:match("^(.-):(%d+):(.*)$")
    if f and ln then
      table.insert(qf, string.format("%s:%s:1:%s", _norm(f), ln, rest or ""))
    end
  end
  if #qf == 0 then
    return false
  end

  vim.fn.setqflist({}, " ", { title = "GTAGS references: " .. symbol, lines = qf })
  vim.cmd("copen")
  return true
end

function M.references()
  local symbol = _buf_symbol()
  if not symbol then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  -- 1) LSP first
  local locs = _lsp_references_sync(800)
  if locs and #locs > 0 then
    _qf_from_locations("LSP references: " .. symbol, locs)
    return
  end

  -- 2) GTAGS: choose DB by current file path; miss => try the other
  local project_root, engine_root, err = _G.ue_roots and _G.ue_roots() or nil
  if err or not project_root or not engine_root then
    vim.notify("No UE roots (cd into .uproject dir first)", vim.log.levels.WARN)
    return
  end
  project_root = _norm(project_root)
  engine_root = _norm(engine_root)

  local file = _norm(vim.api.nvim_buf_get_name(0))
  local first, second = project_root, engine_root
  if file:sub(1, #engine_root) == engine_root then
    first, second = engine_root, project_root
  end

  if _try_gtags_references(first, symbol) then return end
  if _try_gtags_references(second, symbol) then return end

  vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
end

return M
