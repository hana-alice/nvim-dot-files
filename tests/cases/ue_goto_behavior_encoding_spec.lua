local t = require("tests.harness")
t.bootstrap()

t.describe("jumper: invalid destinations", function()
  for _, kind in ipairs({ "missing-file", "directory", "loaded-directory", "invalid-uri", "invalid-line" }) do
    t.it("rejects " .. kind .. " before changing the source or jumplist", function()
      local source = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local jumps = vim.deepcopy(vim.fn.getjumplist())
      local target = vim.fn.tempname()
      local directory_buffer
      if kind == "directory" or kind == "loaded-directory" then vim.fn.mkdir(target, "p") end
      if kind == "loaded-directory" then
        directory_buffer = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(directory_buffer, target)
      end
      local buffers = vim.api.nvim_list_bufs()
      local loc = {
        uri = kind == "invalid-uri" and 123 or vim.uri_from_fname(target),
        range = { start = { line = kind == "invalid-line" and "bad" or 40, character = 0 } },
      }
      local ok, err = xpcall(function()
        t.assert_false(require("utils.ue_goto.jumper").jump(loc))
        t.assert_eq(vim.api.nvim_get_current_buf(), source)
        t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor))
        t.assert_true(vim.deep_equal(vim.fn.getjumplist(), jumps))
        t.assert_true(vim.deep_equal(vim.api.nvim_list_bufs(), buffers))
      end, debug.traceback)
      vim.api.nvim_set_current_buf(source)
      if directory_buffer then vim.api.nvim_buf_delete(directory_buffer, { force = true }) end
      if kind == "directory" or kind == "loaded-directory" then vim.fn.delete(target, "d") end
      if not ok then error(err) end
    end)
  end
end)

t.describe("jumper: protocol destination encoding", function()
  for _, encoding in ipairs({ "utf-8", "utf-16", "utf-32" }) do
    t.it(encoding .. " lands on the target byte after multibyte text", function()
      local source = vim.api.nvim_get_current_buf()
      local target = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(target, vim.fn.tempname() .. ".cpp")
      local line = "/*中文😀*/ int target;"
      vim.api.nvim_buf_set_lines(target, 0, -1, false, { line })
      local byte = line:find("target", 1, true) - 1
      local ok, err = xpcall(function()
        local character = vim.str_utfindex(line, encoding, byte, false)
        t.assert_true(require("utils.ue_goto.jumper").jump({
          uri = vim.uri_from_bufnr(target),
          _position_encoding = encoding,
          range = { start = { line = 0, character = character } },
        }))
        t.assert_eq(vim.api.nvim_win_get_cursor(0)[2], byte)
      end, debug.traceback)
      vim.api.nvim_set_current_buf(source)
      vim.api.nvim_buf_delete(target, { force = true })
      if not ok then error(err) end
    end)
  end
end)

t.describe("non-C++ locations retain destination encoding", function()
  t.it("csearch byte columns carry UTF-8 metadata", function()
    local loc = require("utils.ue_goto.csearch_fallback")._make_location_for_test("/tmp/target.hlsl", 1, 19)
    t.assert_eq(loc._position_encoding, "utf-8")
  end)

  t.it("cache roundtrip preserves encoding and rejects legacy untyped locations", function()
    local names = { "ue", "ue.project_state", "utils.ue_goto.cache" }
    local saved = {}
    for _, name in ipairs(names) do saved[name] = package.loaded[name] end
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local path = root .. "/target.hlsl"
    vim.fn.writefile({ "/*中文*/ int target;" }, path)
    package.loaded["ue"] = { clangd_root = function() return root end }
    package.loaded["ue.project_state"] = {
      current = function() return { project_root = root } end,
      project_cache_root = function() return root .. "/cache" end,
    }
    package.loaded["utils.ue_goto.cache"] = nil
    local cache = require("utils.ue_goto.cache")
    local ok, err = xpcall(function()
      for _, encoding in ipairs({ "utf-8", "utf-16", "utf-32" }) do
        local loc = { uri = vim.uri_from_fname(path), _position_encoding = encoding,
          range = { start = { line = 0, character = 0 } } }
        cache.put("target", encoding, { loc }, "lsp", 0)
      end
      cache.put("target", "legacy", { { uri = vim.uri_from_fname(path),
        range = { start = { line = 0, character = 15 } } } }, "lsp", 0)
      t.assert_true(cache._flush_for_test(0))
      -- Simulate pre-encoding persisted records, including the secondary key.
      local files = {}
      local entries = cache.stats(0).cache_dir .. "/entries"
      for name, kind in vim.fs.dir(entries) do
        if kind == "file" and name:match("%.json$") then files[#files + 1] = entries .. "/" .. name end
      end
      t.assert_true(#files > 0, "cache roundtrip must inspect persisted entries")
      for _, file in ipairs(files) do
        local data = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
        if data.entry.locations[1].range.start.character == 15 then
          data.entry.locations[1]._position_encoding = nil
          vim.fn.writefile({ vim.json.encode(data) }, file)
        end
      end
      package.loaded["utils.ue_goto.cache"] = nil
      cache = require("utils.ue_goto.cache")
      for _, encoding in ipairs({ "utf-8", "utf-16", "utf-32" }) do
        local result = cache.get("target", encoding, 0)
        t.assert_eq(result and result[1]._position_encoding, encoding)
      end
      t.assert_eq(cache.get("target", "legacy", 0), nil)
    end, debug.traceback)
    cache._flush_for_test(0)
    for _, name in ipairs(names) do package.loaded[name] = saved[name] end
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)
