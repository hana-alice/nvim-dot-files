-- Track recently visited project roots so snacks projects picker can show
-- them without doing the slow oldfiles → git_root walk that hangs Neovide.
--
-- Strategy: on DirChanged + on first BufRead, walk parents of cwd / file and
-- find the first directory containing one of the marker patterns
-- (.git, .uproject, package.json). If found, record it in a small JSON-ish
-- list file. Bounded size, deduped, MRU-ordered.
--
-- Read by lua/plugins/snacks.lua → opts.picker.sources.projects.projects
-- (snacks accepts a static list, no fd scan, no git spawn — instant).

local M = {}

local MAX_ENTRIES = 50
local MARKERS = { ".git", ".uproject", ".uplugin", "package.json", "Cargo.toml", "go.mod" }

local function state_path()
  return vim.fn.stdpath("state") .. "/recent_projects.txt"
end

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

local function write_lines(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function normalize(p)
  if not p or p == "" then
    return nil
  end
  p = vim.fs.normalize(p)
  -- strip trailing slash
  if #p > 1 and p:sub(-1) == "/" then
    p = p:sub(1, -2)
  end
  return p
end

local function find_root(start_dir)
  if not start_dir or start_dir == "" then
    return nil
  end
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(start_dir)
  if not stat then
    return nil
  end
  if stat.type ~= "directory" then
    start_dir = vim.fs.dirname(start_dir)
  end

  -- vim.fs.find walks up from start_dir
  local found = vim.fs.find(MARKERS, { upward = true, path = start_dir, limit = 1 })
  if not found or #found == 0 then
    return nil
  end
  return normalize(vim.fs.dirname(found[1]))
end

function M.list()
  local out = {}
  local seen = {}
  for _, line in ipairs(read_lines(state_path())) do
    local p = normalize(vim.trim(line))
    if p and not seen[p] and vim.fn.isdirectory(p) == 1 then
      seen[p] = true
      table.insert(out, p)
    end
  end
  return out
end

-- Bootstrap from v:oldfiles when our state file is empty/short. Bounded
-- (default 30 oldfiles → ~30 vim.fs.find calls, all sync stat, no git
-- spawn). Keeps results deduped & in oldfiles MRU order.
function M.bootstrap_from_oldfiles(max_files)
  max_files = max_files or 30
  local existing = M.list()
  local seen = {}
  for _, p in ipairs(existing) do
    seen[p] = true
  end
  local oldfiles = vim.v.oldfiles or {}
  local added = 0
  for i = 1, math.min(#oldfiles, max_files) do
    local f = oldfiles[i]
    local root = find_root(f)
    if root and not seen[root] and vim.fn.isdirectory(root) == 1 then
      seen[root] = true
      table.insert(existing, root)
      added = added + 1
    end
  end
  if added > 0 then
    -- Truncate before write
    local trimmed = {}
    for i = 1, math.min(#existing, MAX_ENTRIES) do
      trimmed[i] = existing[i]
    end
    write_lines(state_path(), trimmed)
  end
  return added
end

function M.record(path)
  local root = find_root(path)
  if not root then
    return
  end
  local current = M.list()
  local new = { root }
  for _, p in ipairs(current) do
    if p ~= root and #new < MAX_ENTRIES then
      table.insert(new, p)
    end
  end
  write_lines(state_path(), new)
end

local function record_current()
  local cwd = vim.uv and vim.uv.cwd() or vim.loop.cwd()
  M.record(cwd)
  local buf_name = vim.api.nvim_buf_get_name(0)
  if buf_name and buf_name ~= "" then
    M.record(buf_name)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("RecentProjects", { clear = true })
  vim.api.nvim_create_autocmd({ "DirChanged", "VimEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        record_current()
        -- One-shot bootstrap on first launch when our state is empty.
        -- DEFERRED off the startup critical path: the original 30-oldfile
        -- walk does ~1800 sync stat calls on cold NTFS (Defender-scanned),
        -- which freezes the dashboard for several seconds if it runs
        -- during VimEnter. defer_fn(500) runs after the dashboard is
        -- painted and the user can already see the UI.
        if #M.list() < 5 then
          vim.defer_fn(function()
            M.bootstrap_from_oldfiles(30)
          end, 500)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      vim.schedule(function()
        M.record(vim.api.nvim_buf_get_name(args.buf))
      end)
    end,
  })
end

return M
