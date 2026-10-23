local t = require("tests.harness")
t.bootstrap()
local uri = require("utils.buffer_uri")

t.describe("non-file URI consumer boundaries", function()
  for _, name in ipairs({ "codediff:///D:/UE///a1b/Source/A.cpp", "codediff:/D:/UE/a1b/A.cpp",
    "fugitive://repo/A.cpp", "x://revision/A.cpp", "jdt:source/A.cpp" }) do
    t.it("rejects virtual identity " .. name, function()
      t.assert_false(uri.is_file_name(name))
      t.assert_nil(require("ue")._foreign_buffer_key_for_test(name, "C:/Project", "D:/UE"))
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, name)
      if name:find(":/", 1, true) and not uri.is_file_name(vim.api.nvim_buf_get_name(buf)) then
        t.assert_nil(require("ue").clangd_start_root(buf))
      else
        -- Neovim expands non-hierarchical names to ordinary absolute filenames; on
        -- POSIX a one-letter scheme ("x:") is not a URL to Neovim either.
        t.assert_true(uri.is_file_name(vim.api.nvim_buf_get_name(buf)))
      end
    end)
  end
  for _, name in ipairs({ "D:/UE/Source/A.cpp", [[D:\UE\Source\A.cpp]], "/workspace/A.cpp",
    [[\\server\share\A.cpp]], "file:///workspace/A.cpp", "FILE:///workspace/A.cpp" }) do
    t.it("retains file identity " .. name, function() t.assert_true(uri.is_file_name(name)) end)
  end
  t.it("unnamed buffers are not clangd documents", function()
    t.assert_false(uri.is_file_name(""))
    t.assert_false(uri.is_file_name(nil))
  end)
  t.it("lazy session inspection filters URI before relative path expansion", function()
    local root = assert(vim.env.NVIM_TEST_RUN_ROOT):gsub("\\", "/")
    local path = root .. "/uri-policy-session.vim"
    vim.fn.writefile({ "badd +1 codediff:///D:/UE///a1b/Source/A.cpp", "badd +2 fugitive://repo/B.cpp",
      "badd +3 Real.cpp", "edit codediff:///D:/UE///a1b/Source/A.cpp" }, path)
    local info = assert(require("utils.session_restore").inspect(path))
    t.assert_eq(#info.files, 1)
    t.assert_eq(info.files[1].line, 3)
    t.assert_contains(info.active.path, "Real.cpp")
    t.assert_false(info.active.path:find("codediff", 1, true))
  end)
  t.it("real foreign checkout warnings remain classified", function()
    t.assert_true(require("ue")._foreign_buffer_key_for_test("E:/Other/Source/A.cpp", "C:/Project", "D:/UE") ~= nil)
  end)
end)

t.describe("clangd attach guard lifecycle", function()
  t.it("guard is client-specific, idempotent and reversibly restores owned hooks", function()
    local guard = require("workarounds.clangd.non_file_uri_detach")
    guard.disable()
    local saved_attach, saved_get = vim.lsp.buf_attach_client, vim.lsp.get_client_by_id
    local calls, opens = 0, 0
    local on_attach = function() opens = opens + 1 end
    local clangd = { name = "clangd", attached_buffers = {}, on_attach = on_attach }
    local other = { name = "other", attached_buffers = {}, on_attach = on_attach }
    local delegate = function() calls = calls + 1; return true end
    vim.lsp.buf_attach_client = delegate
    vim.lsp.get_client_by_id = function(id) return id == 1 and clangd or other end
    local ok, err = pcall(function()
      guard.apply()
      local first = vim.lsp.buf_attach_client
      guard.apply()
      t.assert_true(first == vim.lsp.buf_attach_client)
      local virtual = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(virtual, "codediff:///D:/UE///a1b/Test.cpp")
      t.assert_false(vim.lsp.buf_attach_client(virtual, 1))
      t.assert_eq(calls, 0)
      t.assert_true(vim.lsp.buf_attach_client(virtual, 2))
      t.assert_eq(calls, 1)
      local file = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(file, assert(vim.env.NVIM_TEST_RUN_ROOT) .. "/real-policy.cpp")
      t.assert_true(vim.lsp.buf_attach_client(file, 1))
      clangd:on_attach(file)
      t.assert_eq(opens, 1)
      clangd.attached_buffers[virtual] = true
      clangd:on_attach(virtual)
      t.assert_nil(clangd.attached_buffers[virtual])
      t.assert_eq(opens, 1)
      guard.disable()
      t.assert_true(vim.lsp.buf_attach_client == delegate)
      t.assert_true(clangd.on_attach == on_attach)
    end)
    guard.disable()
    vim.lsp.buf_attach_client, vim.lsp.get_client_by_id = saved_attach, saved_get
    if not ok then error(err, 0) end
  end)
end)
