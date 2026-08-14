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
local file_lock = require("ue.file_lock")

local MAX_ENTRIES = 50
local MAX_UPDATE_ATTEMPTS = 20
local MARKERS = { ".git", ".uproject", ".uplugin", "package.json", "Cargo.toml", "go.mod" }

local function state_path()
  return vim.env.NVIM_RECENT_PROJECTS_PATH
    or (vim.fn.stdpath("state") .. "/recent_projects.txt")
end

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

local function write_lines(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local temp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local ok, err = pcall(vim.fn.writefile, lines, temp)
  if not ok then return false, err end
  local renamed, rename_err = vim.uv.fs_rename(temp, path)
  if not renamed then pcall(os.remove, temp); return false, rename_err end
  return true
end

local function update_file(transform, attempt)
  local path = state_path()
  local lease = file_lock.acquire(path .. ".lock")
  if not lease then
    attempt = (attempt or 0) + 1
    if attempt <= MAX_UPDATE_ATTEMPTS then
      -- Keep this asynchronous: several Neovim instances can discover a
      -- project at once, and a short PID-skewed retry avoids a thundering herd
      -- without ever blocking the UI thread.
      local delay_ms = math.min(25, attempt * 3) + (vim.fn.getpid() % 5)
      vim.defer_fn(function() update_file(transform, attempt) end, delay_ms)
    end
    return false
  end
  local ok, result = pcall(transform, read_lines(path))
  if ok and type(result) == "table" then ok = write_lines(path, result) end
  file_lock.release(lease)
  return ok
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
    local discovered = vim.deepcopy(existing)
    update_file(function(latest)
      local merged, merged_seen = {}, {}
      for _, source in ipairs({ latest, discovered }) do
        for _, p in ipairs(source) do
          p = normalize(vim.trim(p))
          if p and not merged_seen[p] and #merged < MAX_ENTRIES then
            merged_seen[p] = true
            merged[#merged + 1] = p
          end
        end
      end
      return merged
    end)
  end
  return added
end

function M.record(path)
  local root = find_root(path)
  if not root then
    return
  end
  update_file(function(current)
    local new = { root }
    for _, p in ipairs(current) do
      p = normalize(vim.trim(p))
      if p and p ~= root and #new < MAX_ENTRIES then table.insert(new, p) end
    end
    return new
  end)
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
