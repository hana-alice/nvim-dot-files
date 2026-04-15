-- Regression test for mixed-EOL reload preserving filetype/highlighting.
-- Run:
--   nvim --headless --cmd "lua vim.g.started_with_stdin = true" -u init.lua +"luafile tools/test_mixed_eol_filetype.lua"

local function p(...)
  local args = { ... }
  for i, v in ipairs(args) do
    args[i] = tostring(v)
  end
  io.write(table.concat(args, "\t") .. "\n")
  io.flush()
end

local function fail(msg)
  p("FAIL", msg)
  vim.cmd("cquit 1")
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    fail(("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
  end
end

local function assert_true(value, label)
  if not value then
    fail(label)
  end
end

local function write_mixed_eol_file(path)
  local file, err = io.open(path, "wb")
  if not file then
    fail("open temp file: " .. tostring(err))
  end
  file:write("int main() {\r\n")
  file:write("  return 0;\n")
  file:write("}\r\n")
  file:close()
end

pcall(function()
  require("persistence").stop()
end)

local function wait_for_highlighting(label)
  local ok = vim.wait(3000, function()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].filetype == "cpp" and vim.treesitter.highlighter.active[buf] ~= nil
  end, 50)
  assert_true(ok, label .. ": timed out waiting for filetype/treesitter")
end

local function assert_cpp_buffer(label)
  local buf = vim.api.nvim_get_current_buf()
  wait_for_highlighting(label)
  assert_eq(vim.bo[buf].fileformat, "dos", label .. ": fileformat")
  assert_eq(vim.bo[buf].filetype, "cpp", label .. ": filetype")
  assert_true(vim.treesitter.highlighter.active[buf] ~= nil, label .. ": treesitter inactive")
end

local function wipe_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.cmd("enew")
end

local function source_session(session_path)
  vim.cmd("silent! source " .. vim.fn.fnameescape(session_path))
end

local base = vim.fs.joinpath(vim.fn.stdpath("cache"), "tests")
vim.fn.mkdir(base, "p")

local mixed_path = vim.fs.joinpath(base, "mixed-eol.cpp")
local session_path = vim.fs.joinpath(base, "mixed-eol-session.vim")

write_mixed_eol_file(mixed_path)
vim.fn.writefile({
  "let SessionLoad = 1",
  "edit " .. vim.fn.fnameescape(mixed_path),
  "doautoall SessionLoadPost",
  "unlet SessionLoad",
}, session_path)

wipe_all()
vim.cmd("edit " .. vim.fn.fnameescape(mixed_path))
assert_cpp_buffer("direct edit")

wipe_all()
source_session(session_path)
assert_cpp_buffer("session source")

p("PASS", "mixed EOL reload preserves filetype and treesitter")
vim.cmd("qall!")
