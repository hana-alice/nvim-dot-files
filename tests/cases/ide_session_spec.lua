local t = require("tests.harness")
t.bootstrap()

t.describe("ide_session: bounded session recovery", function()
  t.it("reports the existing heavy-session limit without silently raising it", function()
    local session = require("utils.session_restore")
    local path = vim.fn.tempname() .. ".vim"
    local lines = {}
    for i = 1, 25 do
      lines[#lines + 1] = "badd +1 " .. vim.fn.fnameescape("C:/Fixture/File" .. i .. ".cpp")
    end
    vim.fn.writefile(lines, path)
    local info = session.inspect(path)
    t.assert_true(info.heavy)
    t.assert_eq(#info.files, 25)
    t.assert_contains(info.reason, "25")
    vim.fn.delete(path)
  end)
  t.it("uses native command parsing and preserves spaces and escaped special characters", function()
    local session = require("utils.session_restore")
    local path = vim.fn.tempname() .. ".vim"
    local file = vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/A B#C[1].cpp"
    vim.fn.writefile({ "badd +42 " .. vim.fn.fnameescape(file), "edit " .. vim.fn.fnameescape(file) }, path)
    local info = session.inspect(path)
    t.assert_eq(#info.files, 1)
    t.assert_eq(info.files[1].path:gsub("\\", "/"), file:gsub("\\", "/"))
    t.assert_eq(info.files[1].line, 42)
    vim.fn.delete(path)
  end)
  t.it("lazy recovery adds names without loading and parsing the remaining source files", function()
    local session = require("utils.session_restore")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local a, b, path = dir .. "/A.cpp", dir .. "/B.cpp", dir .. "/session.vim"
    vim.fn.writefile({ "int a;" }, a)
    vim.fn.writefile({ "int b;" }, b)
    vim.fn.writefile(
      { "badd +1 " .. vim.fn.fnameescape(a), "badd +1 " .. vim.fn.fnameescape(b), "edit " .. vim.fn.fnameescape(a) },
      path
    )
    local ok = session.restore_lazy(path)
    t.assert_true(ok)
    t.assert_true(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(a)))
    t.assert_false(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(b)))
    for _, name in ipairs({ a, b }) do
      local buf = vim.fn.bufnr(name)
      if buf ~= -1 then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)
  t.it("refuses replacing unsaved work and never executes arbitrary session statements in lazy mode", function()
    local session = require("utils.session_restore")
    local path = vim.fn.tempname() .. ".vim"
    vim.fn.writefile(
      { "let g:ide_session_injected = 1", "badd +1 C:/Fixture/A.cpp | let g:ide_session_injected = 2" },
      path
    )
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "keep this" })
    vim.bo[buf].modified = true
    t.assert_false(session.restore_lazy(path))
    t.assert_nil(vim.g.ide_session_injected)
    t.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "keep this")
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(path)
  end)
  t.it("resolves saved relative paths without changing cwd or executing extra statements", function()
    local session = require("utils.session_restore")
    local dir, cwd = vim.fn.tempname(), vim.fn.getcwd()
    vim.fn.mkdir(dir, "p")
    local path, file = dir .. "/session.vim", dir .. "/Relative.cpp"
    vim.fn.writefile({ "int relative;" }, file)
    vim.fn.writefile({
      "cd " .. vim.fn.fnameescape(dir),
      "let g:ide_session_injected = 1",
      "badd +1 Relative.cpp",
      "badd +1 Other.cpp | let g:ide_session_injected = 2",
      "edit Relative.cpp",
    }, path)
    local source = vim.api.nvim_get_current_buf()
    local ok, err = session.restore_lazy(path)
    local loaded = vim.fn.bufnr(file)
    local passed = ok and loaded ~= -1 and vim.api.nvim_buf_is_loaded(loaded)
    local injected, after_cwd = vim.g.ide_session_injected, vim.fn.getcwd()
    vim.api.nvim_set_current_buf(source)
    if loaded ~= -1 then
      vim.api.nvim_buf_delete(loaded, { force = true })
    end
    vim.fn.delete(dir, "rf")
    t.assert_true(passed, err)
    t.assert_nil(injected)
    t.assert_eq(after_cwd, cwd)
  end)
  t.it("bounds manual lazy metadata before creating hundreds of source buffers", function()
    local session = require("utils.session_restore")
    local path, entries = vim.fn.tempname() .. ".vim", {}
    for i = 1, 257 do
      entries[#entries + 1] = "badd +1 /fixture/source-" .. i .. ".cpp"
    end
    vim.fn.writefile(entries, path)
    local info, err = session.inspect(path)
    vim.fn.delete(path)
    t.assert_nil(info)
    t.assert_contains(err, "256")
  end)
end)
