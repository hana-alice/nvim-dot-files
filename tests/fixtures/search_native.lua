local M = {}

function M.with_index(t, callback)
  local search = require("utils.code_search")
  local cindex, csearch = search.cindex_uefilter_exe(), search.csearch_exe()
  if not cindex or not csearch then
    return t.skip("native csearch", "requires installed csearch and cindex-uefilter", { native = true })
  end
  local parent = assert(vim.env.NVIM_TEST_RUN_ROOT, "native fixture requires isolated runner root")
  local directory = parent .. "/search-" .. tostring(vim.uv.hrtime())
  vim.fn.mkdir(directory, "p")
  local source = directory .. "/Source Space.cpp"
  local lines = {
    "// alpha then Alpha",
    "// AlphaBeta then Alpha",
    "// 你好 alpha then Alpha",
    "// pre Axxa tail",
    "// literal . / [ ] ( %",
    "// ä Unicode case",
    "// K Unicode fold",
    "// Alpha Alpha Alpha",
  }
  vim.fn.writefile(lines, source)
  local index = directory .. "/csearch.idx"
  local list = directory .. "/input.files"
  vim.fn.writefile({ source }, list)
  local built = vim
    .system({ cindex, "-reset", "-files-from", list }, {
      text = true,
      timeout = 10000,
      env = { CSEARCHINDEX = index },
    })
    :wait()
  local ok, err = xpcall(function()
    t.assert_eq(built.code, 0, built.stderr or "native cindex failed")
    t.assert_true(search.is_indexed({ csearch_idx = index }))
    callback({ directory = directory, source = source, lines = lines, index = index })
  end, debug.traceback)
  local normalized = vim.fs.normalize(directory)
  local normalized_parent = vim.fs.normalize(parent):gsub("/+$", "")
  assert(normalized:sub(1, #normalized_parent + 1) == normalized_parent .. "/", "fixture cleanup escaped its owner")
  vim.fn.delete(directory, "rf")
  if not ok then
    error(err)
  end
end

function M.query(t, fixture, pattern, opts)
  local hits, result, done, done_count = {}, nil, false, 0
  local stop = require("utils.code_search").stream(
    {
      workspace_root = fixture.directory,
      csearch_idx = fixture.index,
    },
    pattern,
    opts or {},
    {
      on_line = function(file, line, column, text, location)
        t.assert_false(done, "line delivered after done")
        hits[#hits + 1] = { file = file, line = line, column = column, text = text, location = location }
      end,
      on_done = function(code, err, meta)
        done_count = done_count + 1
        done, result = true, { code = code, err = err, meta = meta, at = #hits }
      end,
    }
  )
  local completed = vim.wait(10000, function()
    return done
  end, 5)
  if not completed then
    stop("test-timeout")
  end
  t.assert_true(completed, "native query did not complete")
  t.assert_eq(done_count, 1)
  t.assert_eq(result.at, #hits, "done precedes tail delivery")
  return hits, result
end

return M
