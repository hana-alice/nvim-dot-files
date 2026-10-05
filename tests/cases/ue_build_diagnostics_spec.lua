local t = require("tests.harness")
t.bootstrap()
local diagnostics = require("ue.build_diagnostics")

local function fixture(run)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/Build.cpp"
  vim.fn.writefile({ "one", "two", "three", "four" }, file)
  local ok, err = xpcall(function() run(file) end, debug.traceback)
  vim.cmd("cclose")
  diagnostics.clear()
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_buf(win, buf)
  end
  local source = vim.fn.bufnr(file)
  if source > 0 then pcall(vim.api.nvim_buf_delete, source, { force = true }) end
  vim.fn.delete(dir, "rf")
  if not ok then error(err) end
end

t.describe("build diagnostics", function()
  t.it("stable errors-first partition preserves warnings and input", function()
    local entries = {
      { text = "warning C1234: first", type = "" },
      { text = "note: error was declared here" },
      { text = "fatal error: first" },
      { text = "error C123: second" },
      { text = "warning: second" },
    }
    local result = diagnostics.ordered(entries)
    t.assert_eq(#result, #entries)
    t.assert_eq(result[1].text, entries[3].text)
    t.assert_eq(result[2].text, entries[4].text)
    t.assert_eq(result[3].text, entries[1].text)
    t.assert_eq(result[4].text, entries[5].text)
    t.assert_eq(result[5].text, entries[2].text)
    t.assert_nil(entries[3].type)
    t.assert_eq(entries[1].type, "")
  end)

  t.it("location summary and direct jump survive a different quickfix search", function()
    fixture(function(file)
      diagnostics.publish("Build failed", {
        { filename = file, lnum = 1, text = "warning: retained" },
        { text = "error: no source" },
        { filename = file, lnum = 3, col = 2, text = "error: first source error" },
        { filename = file, lnum = 4, text = "error: second source error" },
      })
      local items = vim.fn.getqflist()
      t.assert_eq(#items, 4)
      t.assert_eq(items[4].type, "W")
      t.assert_contains(diagnostics.summary(), "Build.cpp:3")
      t.assert_contains(diagnostics.summary(), "<leader>uE")
      vim.cmd("cclose")
      vim.fn.setqflist({}, " ", { title = "Search", items = { { filename = file, lnum = 1, text = "search" } } })
      t.assert_true(diagnostics.jump_first())
      t.assert_eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "Build.cpp")
      local cursor = vim.api.nvim_win_get_cursor(0)
      t.assert_eq(cursor[1], 3)
      t.assert_eq(cursor[2], 1)
      t.assert_eq(vim.fn.getqflist()[1].text, "search", "direct jump must not overwrite a search")
    end)
  end)

  t.it("a failure with no source does not reuse the previous build's location", function()
    fixture(function(file)
      diagnostics.publish("Old build", { { filename = file, lnum = 3, text = "error: old" } })
      diagnostics.publish("New build", { { text = "error: linker failed" } })
      t.assert_eq(diagnostics.summary(), "未解析到错误源码位置")
      t.assert_false(diagnostics.jump_first())
      t.assert_eq(#vim.fn.getqflist(), 1)
    end)
  end)

  t.it("warnings alone are retained without masquerading as a first error", function()
    fixture(function(file)
      diagnostics.publish("Build", { { filename = file, lnum = 2, text = "warning: unused" } })
      t.assert_eq(vim.fn.getqflist()[1].type, "W")
      t.assert_false(diagnostics.jump_first())
      diagnostics.clear()
      t.assert_false(diagnostics.publish("Empty", {}))
    end)
  end)
end)

local function upvalue(fn, name)
  for index = 1, 255 do
    local key, value = debug.getupvalue(fn, index)
    if not key then
      break
    end
    if key == name then
      return value
    end
  end
  error("missing build output owner: " .. name)
end

t.describe("build output terminal controls", function()
  local build = upvalue(require("ue").setup, "build_target")
  local terminal = upvalue(build, "open_terminal_command")
  local parse = upvalue(terminal, "diagnostic_entries_from_output")

  t.it("OSC titles cannot become part of a compiler filename", function()
    fixture(function(file)
      for _, ending in ipairs({ "\7", "\27\\" }) do
        local title = "\27]0;native compiler" .. ending
        local rows = parse({ title .. file .. title .. ":3:2: error: original message" })
        t.assert_eq(#rows, 1)
        t.assert_eq(vim.fs.normalize(rows[1].filename), vim.fs.normalize(file))
        t.assert_eq(rows[1].lnum, 3)
        t.assert_eq(rows[1].col, 2)
        t.assert_eq(rows[1].text, "error: original message")
      end
    end)
  end)

  t.it("OSC links and CSI colour leave the displayed source and diagnostic intact", function()
    fixture(function(file)
      local line = "\27]8;;file://metadata\27\\"
        .. file
        .. "\27]8;;\27\\"
        .. ":2:1: \27[31merror: plain diagnostic\27[0m"
      local rows = parse({ line })
      t.assert_eq(#rows, 1)
      t.assert_eq(vim.fs.normalize(rows[1].filename), vim.fs.normalize(file))
      t.assert_eq(rows[1].lnum, 2)
      t.assert_eq(rows[1].text, "error: plain diagnostic")
    end)
  end)
end)
