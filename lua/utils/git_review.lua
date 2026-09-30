-- Git UI routing. CodeDiff owns diff state; Snacks owns cancellable pickers.
-- The v4 handler boundary is pinned and covered by native integration tests.
local M = {}
local api = vim.api
local pending = {}

local function notify(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "Git review" })
end

function M.session()
  local lifecycle = package.loaded["codediff.ui.lifecycle"]
  return lifecycle and lifecycle.get_session(api.nvim_get_current_tabpage()) or nil
end

function M.context(opts)
  opts = opts or {}
  local session = not opts.cwd and not opts.root and M.session() or nil
  local file = opts.path or opts.file
  local root = opts.root or (session and session.git_root)
  if not file and session then
    local ref = session.modified or session.original
    file = ref and ref.absolute ~= "" and ref.absolute or nil
  end
  if not file and not opts.cwd and vim.bo.buftype == "" then
    local name = api.nvim_buf_get_name(0)
    if name ~= "" and not name:find("://", 1, true) then file = name end
  end
  if not root and not opts.cwd and package.loaded["diffview.lib"] then
    local view = package.loaded["diffview.lib"].get_current_view()
    root = view and view.adapter and view.adapter.ctx.toplevel
  end
  root = root or vim.fs.root(opts.cwd and vim.fn.getcwd() or file or vim.fn.getcwd(), ".git")
  root = root or (not opts.cwd and vim.fs.root(vim.fn.getcwd(), ".git"))
  if not root then notify("当前文件和目录不属于 Git 仓库") return nil end
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  file = file and vim.fs.normalize(file) or nil
  if file and not file:match("^/") and not file:match("^%a:/") then file = root .. "/" .. file end
  if file then
    -- Resolve the directory spelling (including Windows 8.3 paths), while
    -- retaining the file itself: Git may be tracking a symlink or deletion.
    local parent = vim.fs.dirname(file)
    file = vim.fs.joinpath(vim.uv.fs_realpath(parent) or parent, vim.fs.basename(file))
  end
  return { root = root, file = file and vim.fs.normalize(file) or nil }
end

function M.ready()
  -- Installation is explicit; opening a view must never download binaries.
  vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
  vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"
  local lazy = package.loaded.lazy
  if lazy then lazy.load({ plugins = { "codediff.nvim" } }) end
  local ok, diff = pcall(require, "codediff.core.diff")
  if not ok then
    notify("CodeDiff 原生库不可用；在 :Lazy 中对 codediff.nvim 执行 build 后重试。\n" .. tostring(diff))
    return false
  end
  if diff.get_version() ~= require("codediff.version").VERSION then
    notify("CodeDiff 原生库版本不匹配；在 :Lazy 中对 codediff.nvim 执行 build 后重试")
    return false
  end
  return true
end

local function valid_revision(rev)
  return type(rev) == "string" and rev ~= "" and not rev:find("^[%-]") and not rev:find("[%s%c]")
end

function M.open(opts)
  opts = opts or {}
  local ctx = M.context(opts)
  if not ctx or not M.ready() then return end
  local lifecycle = require("codediff.ui.lifecycle")
  if opts.staged then
    require("codediff.commands.handlers.explorer_staged").run(nil, { repo = ctx.root },
      ctx.file and { require("codediff.core.git").get_relative_path(ctx.file, ctx.root) } or nil)
    return
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    local sess = lifecycle.get_session(tab)
    if sess and sess.git_root == ctx.root and sess.panel and sess.panel.name == "explorer"
      and not sess.panel.data.base_revision and not sess.panel.data.target_revision
      and not sess.panel.data.pathspec then
      api.nvim_set_current_tabpage(tab)
      if ctx.file and sess.panel.view then
        local relative = require("codediff.core.git").get_relative_path(ctx.file, ctx.root)
        for _, entry in ipairs(require("codediff.ui.explorer").get_all_files(sess.panel.view.tree)) do
          if entry.data.path == relative then sess.panel.view.on_file_select(entry.data); break end
        end
      end
      require("codediff.ui.refresh").request(tab, "manual")
      return
    end
  end
  if pending[ctx.root] then return end
  pending[ctx.root] = true
  local git = require("codediff.core.git")
  git.get_status_with_line_stats(ctx.root, function(err, status)
    vim.schedule(function()
      pending[ctx.root] = nil
      if err then notify(err) return end
      local path = require("codediff.core.path")
      -- Also open clean repositories: the welcome view distinguishes no changes
      -- from failed status, and can refresh when external edits arrive.
      require("codediff.ui.view").create({
        git_root = ctx.root, original = path.empty(), modified = path.empty(),
        panel = { name = "explorer", data = {
          status_result = status,
          focus_file = ctx.file and git.get_relative_path(ctx.file, ctx.root) or nil,
        } },
      }, "")
    end)
  end)
end

function M.compare(first, second, opts)
  opts = opts or {}
  if not valid_revision(first) or (second and not valid_revision(second)) then
    notify("请输入有效的 Git revision（不能以 - 开头或含空白）") return
  end
  local ctx = M.context(opts)
  if not ctx or not M.ready() then return end
  local handler = require("codediff.commands.handlers.explorer")
  local paths = opts.pathspec or ((opts.path or opts.file) and ctx.file
    and { require("codediff.core.git").get_relative_path(ctx.file, ctx.root) } or nil)
  if opts.merge_base then
    handler.run_merge_base(first, second or "HEAD", { repo = ctx.root }, paths)
  else
    handler.run(first, second, { repo = ctx.root }, paths)
  end
end

function M.commit(rev, opts)
  if not valid_revision(rev) then notify("无效的提交 revision") return end
  local ctx = M.context(opts)
  if not ctx or not M.ready() then return end
  local git = require("codediff.core.git")
  local file = opts and (opts.path or opts.file) and ctx.file
  local relative = file and git.get_relative_path(file, ctx.root)
  git.resolve_revision(rev, ctx.root, function(err, hash)
    if err then vim.schedule(function() notify(err) end) return end
    local function resolved(path_err, path)
      if path_err then vim.schedule(function() notify(path_err) end) return end
      git.get_revision_parents(hash, ctx.root, function(parent_err, parents)
        vim.schedule(function()
          if parent_err then notify(parent_err) return end
          local function compare(parent)
            local compare_opts = vim.tbl_extend("force", opts or {}, { root = ctx.root, path = path })
            local function open(old_err, old_path)
              vim.schedule(function()
                if old_err then notify(old_err) return end
                if path then
                  compare_opts.pathspec = { path }
                  if old_path and old_path ~= path then table.insert(compare_opts.pathspec, old_path) end
                end
                M.compare(parent or "4b825dc642cb6eb9a060e54bf8d69288fbee4904", hash, compare_opts)
              end)
            end
            -- Include both rename sides so Git detects R instead of reporting
            -- an added file with an empty left side after a path-limited diff.
            if relative and parent then git.resolve_path_at_revision(parent, ctx.root, relative, open)
            else open(nil, nil) end
          end
          if #parents > 1 then
            vim.ui.select(parents, { prompt = "Merge commit：选择比较的父提交" }, function(parent)
              if parent then compare(parent) end
            end)
          else
            compare(parents[1])
          end
        end)
      end)
    end
    if relative then git.resolve_path_at_revision(hash, ctx.root, relative, resolved)
    else resolved(nil, nil) end
  end)
end

function M.history(current_file)
  local ctx = M.context()
  if not ctx or not M.ready() then return end
  if current_file and not ctx.file then notify("请先选择一个文件") return end
  require("codediff.commands.handlers.history").run(nil, current_file and ctx.file or nil, {}, nil, { repo = ctx.root })
end

function M.prompt_range()
  local ctx = M.context()
  if not ctx then return end
  vim.ui.input({ prompt = "Git range (A..B / A...B): ", default = "HEAD~1..HEAD" }, function(input)
    if not input then return end
    local a, b = input:match("^(.-)%.%.%.(.-)$")
    local merge_base = a ~= nil
    if not a then a, b = input:match("^(.-)%.%.(.-)$") end
    if not a then notify("需要 A..B 或 A...B") return end
    M.compare(a ~= "" and a or "HEAD", b ~= "" and b or "HEAD", { root = ctx.root, merge_base = merge_base })
  end)
end

function M.prompt_commit()
  local ctx = M.context()
  if not ctx then return end
  vim.ui.input({ prompt = "Git commit: ", default = "HEAD" }, function(rev)
    if rev then M.commit(rev, { root = ctx.root }) end
  end)
end

function M.neogit(popup)
  local ctx = M.context()
  if not ctx then return end
  local review = M.session()
  local origin_tab, origin_win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  -- Opening status first establishes Neogit's repository instance, including
  -- when the existing popup was previously attached to a different repository.
  local neogit = require("neogit")
  neogit.open({ cwd = ctx.root, no_expand = true })
  if review then
    local status = require("neogit.buffers.status").instance()
    local manager_tab = api.nvim_get_current_tabpage()
    local buffer = status and status.buffer and status.buffer.handle
    if buffer then
      local group = api.nvim_create_augroup("GitReviewNeogit" .. buffer, { clear = true })
      local returned = false
      local function origin_is_current()
        return api.nvim_tabpage_is_valid(origin_tab)
          and require("codediff.ui.lifecycle").get_session(origin_tab) == review
      end
      local function return_to_review()
        local current_tab = api.nvim_get_current_tabpage()
        if returned or not origin_is_current()
            or (current_tab ~= manager_tab and current_tab ~= origin_tab) then return end
        returned = true
        api.nvim_set_current_tabpage(origin_tab)
        if api.nvim_win_is_valid(origin_win) then api.nvim_set_current_win(origin_win) end
        require("codediff.ui.refresh").request(origin_tab, "manual")
      end
      api.nvim_create_autocmd("BufWipeout", {
        group = group, buffer = buffer, once = true,
        callback = function()
          local return_focus = api.nvim_get_current_tabpage() == manager_tab
          pcall(api.nvim_del_augroup_by_id, group)
          if return_focus then vim.schedule(return_to_review) end
        end,
      })
      api.nvim_create_autocmd("User", {
        group = group, pattern = "NeogitCommitComplete",
        callback = function()
          -- A background commit must not pull the user out of another tab.
          if api.nvim_get_current_tabpage() ~= manager_tab then return end
          vim.schedule(function()
            if api.nvim_get_current_tabpage() == manager_tab and status.buffer and origin_is_current() then
              status:close()
              return_to_review()
            end
          end)
        end,
      })
    end
  end
  if popup == "reflog" then
    -- Neogit exposes reflog as a log action/view, not a standalone popup.
    local manager_tab = api.nvim_get_current_tabpage()
    local function still_managing()
      local cwd = vim.fn.getcwd()
      return api.nvim_get_current_tabpage() == manager_tab
        and vim.fs.normalize(vim.uv.fs_realpath(cwd) or cwd) == ctx.root
    end
    local async = require("plenary.async")
    async.void(function()
      local git = require("neogit.lib.git")
      local head = git.cli["rev-parse"].verify.quiet.args("HEAD").call({ hidden = true, ignore_error = true })
      async.util.scheduler()
      if not still_managing() then return end
      if head.code == 1 then
        vim.notify("当前仓库尚无提交，HEAD reflog 不存在", vim.log.levels.INFO, { title = "Git review" })
        return
      elseif head.code ~= 0 then
        notify("读取 HEAD 失败（Git exit " .. tostring(head.code) .. "）")
        return
      end
      local entries = git.reflog.list("HEAD", {})
      async.util.scheduler()
      if not still_managing() then return end
      if #entries == 0 then
        vim.notify("HEAD reflog 为空", vim.log.levels.INFO, { title = "Git review" })
        return
      end
      require("neogit.buffers.reflog_view").new(entries, "Reflog for HEAD"):open()
    end)()
  elseif popup then
    neogit.open({ popup, cwd = ctx.root, no_expand = true })
  end
end

function M.confirm_commit(picker, item)
  if not item or not item.commit then return end
  local root = item.cwd or picker:cwd()
  local file = (picker.opts and picker.opts.git_review_file) or item.file
  picker:close()
  M.commit(item.commit, { root = root, file = file })
end

function M.confirm_status(picker, item)
  if not item or not item.file then return end
  local root = item.cwd or picker:cwd()
  picker:close()
  M.open({ root = root, path = item.file, staged = item.status and item.status:sub(2, 2) == " " })
end

-- Exposed pure argv construction makes -G/-S and path boundaries testable.
function M.search_args(pattern, file)
  local args = { "--no-pager", "log", "--no-color", "--no-show-signature",
    "--format=%H%x1f%s%x1f%ch%x1f%an", "-G", pattern, "--pickaxe-all" }
  if file then vim.list_extend(args, { "--follow", "--", file }) end
  return args
end

function M.search(current_file)
  local ctx = M.context()
  if not ctx then return end
  if current_file and not ctx.file then notify("请先选择一个文件") return end
  local file = current_file and ctx.file or nil
  require("snacks").picker({
    title = file and "Git：当前文件改动内容 (-G)" or "Git：改动内容 (-G)",
    cwd = ctx.root, live = true, supports_live = true,
    git_review_file = file,
    format = "git_log", preview = "git_show", confirm = M.confirm_commit,
    finder = function(_, filter_ctx)
      if filter_ctx.filter.search == "" then return {} end
      return require("snacks.picker.source.proc").proc({
        cmd = "git", cwd = ctx.root, args = M.search_args(filter_ctx.filter.search, file),
        transform = function(item)
          local fields = vim.split(item.text, "\31", { plain = true })
          if #fields ~= 4 then return false end
          item.commit, item.msg, item.date, item.author = unpack(fields)
          item.cwd = ctx.root
          item.file = file
        end,
      }, filter_ctx)
    end,
  })
end

function M.pick_file_ref(branch)
  local ctx = M.context()
  if not ctx or not ctx.file then notify("请先选择一个文件") return end
  local picker = require("snacks").picker
  picker[branch and "git_branches" or "git_log"]({
    cwd = ctx.root,
    confirm = function(p, item)
      if not item then return end
      local revision = item.branch or item.commit
      p:close()
      if not valid_revision(revision) or not M.ready() then return end
      local git = require("codediff.core.git")
      local relative = git.get_relative_path(ctx.file, ctx.root)
      git.resolve_path_at_revision(revision, ctx.root, relative, function(err, old_path)
        vim.schedule(function()
          if err then notify(err) return end
          local paths = { relative }
          if old_path and old_path ~= relative then paths[#paths + 1] = old_path end
          M.compare(revision, nil, { root = ctx.root, file = ctx.file, pathspec = paths })
        end)
      end)
    end,
  })
end

function M.palette()
  local choices = { "审阅改动", "暂存区", "提交 / 分支 / stash", "提交历史", "改动内容搜索", "Reflog", "Diffview" }
  vim.ui.select(choices, { prompt = "Git" }, function(_, index)
    local actions = {
      M.open, function() M.open({ staged = true }) end, M.neogit,
      function() M.history(false) end, function() M.search(false) end,
      function() M.neogit("reflog") end, function() vim.cmd("DiffviewOpen") end,
    }
    if index then actions[index]() end
  end)
end

function M.setup()
  local group = api.nvim_create_augroup("GitReview", { clear = true })
  api.nvim_create_autocmd("User", {
    group = group, pattern = { "CodeDiffOpen", "CodeDiffFileSelect" },
    callback = function(ev)
      local tab = ev.data and ev.data.tabpage or api.nvim_get_current_tabpage()
      require("codediff.ui.lifecycle").set_tab_keymap(tab, "n", "<localleader>c", function()
        M.neogit("commit")
      end, { desc = "Git: commit reviewed changes" })
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = group, callback = function()
      if M.session() then require("codediff.ui.refresh").request(api.nvim_get_current_tabpage(), { worktree = true }) end
    end,
  })
end

function M.setup_keymaps()
  local mappings = {
    gg = { M.open, "CodeDiff: review changes" },
    gG = { function() M.open({ cwd = true }) end, "CodeDiff: cwd repository" },
    gm = { function() M.history(true) end, "CodeDiff: file history" },
    gM = { function() M.history(false) end, "CodeDiff: repository history" },
    gr = { M.prompt_range, "CodeDiff: revision range" },
    gk = { M.prompt_commit, "CodeDiff: single commit" },
    gh = { function() M.search(false) end, "Git: search changed content" },
    gH = { function() M.search(true) end, "Git: search changed content (file)" },
    gx = { function() M.pick_file_ref(true) end, "CodeDiff: file vs branch" },
    gX = { function() M.pick_file_ref(false) end, "CodeDiff: file vs commit" },
    gC = { function() M.neogit("reflog") end, "Neogit: reflog" },
    gA = { M.palette, "Git: actions" },
    gc = { function() local ctx = M.context(); if ctx then require("snacks").picker.git_log({ cwd = ctx.root, confirm = M.confirm_commit }) end end, "Git: commits" },
    gs = { function() local ctx = M.context(); if ctx then require("snacks").picker.git_status({ cwd = ctx.root, confirm = M.confirm_status }) end end, "Git: changed files" },
  }
  for key, mapping in pairs(mappings) do
    vim.keymap.set("n", "<leader>" .. key, mapping[1], { desc = mapping[2], silent = true })
  end
end

return M
