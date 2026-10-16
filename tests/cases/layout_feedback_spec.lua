local t = require("tests.harness")
local root = t.bootstrap()
local api = vim.api

local function isolated(body)
  local names = {
    "utils.layout",
    "utils.layout_commands",
    "utils.layout_notice",
    "codediff.ui.lifecycle",
    "snacks",
    "mini.statusline",
    "utils.ue_hub",
  }
  local saved, tabs, buffers, sessions = {}, {}, {}, {}
  for _, name in ipairs(names) do
    saved[name], package.loaded[name] = package.loaded[name], nil
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    tabs[tab] = true
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    buffers[buf] = true
  end
  local initial, notify = api.nvim_get_current_tabpage(), vim.notify
  local messages = {}
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  package.loaded["codediff.ui.lifecycle"] = {
    get_session = function(tab)
      return sessions[tab]
    end,
  }
  vim.cmd.tabnew()
  local ok, err = xpcall(function()
    body(require("utils.layout"), sessions, messages)
  end, debug.traceback)
  vim.wait(30, function()
    return false
  end, 5)
  for _, name in ipairs({ "UELayoutNavigationNotice", "UELayoutReviewLifecycle", "UELayoutGroups" }) do
    pcall(api.nvim_del_augroup_by_name, name)
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if not buffers[buf] then
      vim.bo[buf].modified = false
    end
  end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not tabs[tab] then
      api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose!")
    end
  end
  if api.nvim_tabpage_is_valid(initial) then
    api.nvim_set_current_tabpage(initial)
  end
  vim.notify = notify
  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  if not ok then
    error(err, 0)
  end
end

local function owner(m, sessions, kind, base, target, path)
  local tab, left = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  vim.cmd.vnew()
  local right = api.nvim_get_current_win()
  if kind == "review" then
    sessions[tab] = {
      original_win = left,
      modified_win = right,
      git_root = "fixture-repo",
      original_revision = base or "base",
      modified_revision = target or "topic",
      panel = {
        data = { base_revision = base, target_revision = target },
        view = { data = { current_file_path = path or "Source/Selected.cpp" } },
      },
    }
    m.sync_review(tab)
  else
    m.register(left, "code")
    m.register(right, "panel")
    m.register_group("debug", {
      tab = tab,
      token = {},
      owner = "feedback-debug",
      focus = function()
        api.nvim_set_current_win(left)
        return left
      end,
    })
  end
  api.nvim_set_current_win(left)
  return tab, left
end

local function flush()
  vim.wait(30, function()
    return false
  end, 5)
end

t.describe("layout_feedback source and return guidance", function()
  t.it("closing a review session clears provenance even when its windows survive", function()
    isolated(function(m, sessions)
      require("utils.layout_notice").setup()
      local tab, source = owner(m, sessions, "review")
      assert(m.focus({ source_win = source }))
      flush()
      t.assert_true(vim.t.ue_layout_source ~= "")
      api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", data = { tabpage = tab } })
      sessions[tab] = nil -- native Close is emitted before synchronous owner cleanup
      flush()
      t.assert_true(api.nvim_win_is_valid(source), "only the session was closed")
      t.assert_nil(m.navigation_source())
      t.assert_eq(vim.t.ue_layout_source, "")
    end)
  end)

  for _, kind in ipairs({ "review", "debug" }) do
    t.it(kind .. " external handoff gives one notice and clears cached label on Back", function()
      isolated(function(m, sessions, messages)
        local tab, source = owner(m, sessions, kind)
        local plugin = dofile(root .. "/lua/plugins/statusline.lua")[2]
        plugin.init()
        flush()
        t.assert_eq(#messages, 0)
        local win = assert(m.focus({ source_win = source }))
        flush()
        local name = kind == "review" and "审阅" or "调试"
        local expected = ("编辑 ← %s tab %d · <leader>w[ 返回"):format(name, api.nvim_tabpage_get_number(tab))
        t.assert_eq(vim.t.ue_layout_source, expected)
        t.assert_eq(#messages, 1)
        t.assert_eq(messages[1], expected)
        api.nvim_exec_autocmds("BufEnter", { buffer = api.nvim_win_get_buf(win) })
        flush()
        t.assert_eq(#messages, 1, "buffer events must not repeat a transition toast")
        t.assert_eq(m.back(), source)
        flush()
        t.assert_eq(vim.t.ue_layout_source, "")
        t.assert_nil(m.navigation_source())
        assert(m.focus({ source_win = source }))
        flush()
        t.assert_eq(#messages, 2, "next navigation gets exactly one fresh transition notice")
      end)
    end)
  end

  t.it("source getter reads existing history without discovery or consuming Back", function()
    isolated(function(m, sessions)
      local tab, source = owner(m, sessions, "review")
      assert(m.focus({ source_win = source }))
      local discover, nav = m.discover_groups, m.navigation_owner
      m.discover_groups = function()
        error("read-only getter discovered UI")
      end
      m.navigation_owner = function()
        error("read-only getter queried owner")
      end
      local a, b = m.navigation_source(), m.navigation_source()
      t.assert_eq(a.tab, tab)
      t.assert_eq(a.kind, "review")
      a.tab = -1
      t.assert_eq(b.tab, tab, "returned scalar row must not alias history")
      m.discover_groups, m.navigation_owner = discover, nav
      t.assert_eq(m.back(), source, "getter must not consume history")
    end)
  end)

  t.it("ordinary editing and a destination query have no source label or notice", function()
    isolated(function(m, sessions, messages)
      require("utils.layout_notice").setup()
      flush()
      t.assert_eq(vim.t.ue_layout_source, "")
      t.assert_nil(m.navigation_source())
      local tab, source = owner(m, sessions, "review")
      m.resolve({ tab = tab, source_win = source, create = false, route_to_normal = true })
      flush()
      t.assert_eq(api.nvim_get_current_tabpage(), tab)
      t.assert_eq(#messages, 0)
    end)
  end)

  t.it("closing source tab removes cached provenance", function()
    isolated(function(m, sessions)
      local tab, source = owner(m, sessions, "review")
      require("utils.layout_notice").setup()
      local destination = assert(m.focus({ source_win = source }))
      flush()
      t.assert_true(vim.t.ue_layout_source ~= "")
      api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose!")
      api.nvim_set_current_win(destination)
      flush()
      t.assert_eq(vim.t.ue_layout_source, "")
      t.assert_nil(m.navigation_source())
    end)
  end)

  t.it("statusline only reads cached text on repeated rendering", function()
    isolated(function(m, sessions)
      local _, source = owner(m, sessions, "review")
      local spec = dofile(root .. "/lua/plugins/statusline.lua")[2]
      spec.init()
      assert(m.focus({ source_win = source }))
      flush()
      local expected, reads = vim.t.ue_layout_source, 0
      m.navigation_source = function()
        reads = reads + 1
        error("render queried source history")
      end
      local mini = {
        section_mode = function()
          return "N", "Mode"
        end,
        is_truncated = function()
          return false
        end,
        combine_groups = function(groups)
          local text = {}
          for _, group in ipairs(groups) do
            if type(group) == "table" then
              for _, s in ipairs(group.strings) do
                text[#text + 1] = s
              end
            end
          end
          return table.concat(text, " | ")
        end,
      }
      for _, name in ipairs({ "git", "diff", "diagnostics", "lsp", "filename", "fileinfo", "location", "searchcount" }) do
        mini["section_" .. name] = function()
          return ""
        end
      end
      package.loaded["mini.statusline"] = mini
      package.loaded["utils.ue_hub"] = {
        debug_indicator = function()
          return ""
        end,
      }
      local render = spec.opts().content.active
      for _ = 1, 50 do
        t.assert_contains(render(), expected)
      end
      t.assert_eq(reads, 0)
      m.navigation_source = function()
        return nil
      end
    end)
  end)

  t.it("layout rows and picker show base-to-target revisions and selected path", function()
    isolated(function(m, sessions)
      owner(m, sessions, "review", "base-A", "topic-B", "Source/First.cpp")
      vim.cmd.tabnew()
      owner(m, sessions, "review", "topic-B", "base-A", "Source/Second.cpp")
      local rows = m.list_groups()
      local text = {}
      for _, row in ipairs(rows) do
        if row.kind == "review" then
          text[#text + 1] = row.text
        end
      end
      t.assert_eq(#text, 2)
      t.assert_contains(text[1], "base-A → topic-B")
      t.assert_contains(text[1], "Source/First.cpp")
      t.assert_contains(text[2], "topic-B → base-A")
      t.assert_contains(text[2], "Source/Second.cpp")
      package.loaded["snacks"] = { picker = {
        pick = function(opts)
          return opts
        end,
      } }
      local picker = require("utils.layout_commands").layout()
      t.assert_contains(picker.title, "比较版本")
      t.assert_contains(picker.items[1].text, "base-A → topic-B")
    end)
  end)

  t.it("empty review code view explains editing entry and review return", function()
    isolated(function(m, sessions, messages)
      owner(m, sessions, "review")
      local tab, wins = api.nvim_get_current_tabpage(), #api.nvim_list_wins()
      require("utils.layout_commands").view("code")
      t.assert_eq(messages[#messages], "当前为审阅配对视图；<leader>wN 进入编辑，<leader>wR 回审阅")
      t.assert_eq(api.nvim_get_current_tabpage(), tab)
      t.assert_eq(#api.nvim_list_wins(), wins, "guidance must not create or replace a view")
    end)
  end)

  t.it("range review without an explorer renders its already retained relative file", function()
    isolated(function(m, sessions)
      local tab, left = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
      vim.cmd.vnew()
      sessions[tab] = {
        original_win = left,
        modified_win = api.nvim_get_current_win(),
        original_revision = "base",
        modified_revision = "topic",
        modified = { relative = "Source/Range.cpp" },
      }
      m.sync_review(tab)
      local rows = m.list_groups()
      for _, row in ipairs(rows) do
        if row.tab == tab and row.kind == "review" then
          t.assert_contains(row.text, "base → topic")
          t.assert_contains(row.text, "Source/Range.cpp")
          return
        end
      end
      error("missing range review group")
    end)
  end)
end)
