local t = require("tests.harness")
t.bootstrap()
local process = require("utils.document_find_process")
local find = require("utils.document_find")

local function native(lines, query, modes, limits)
  if vim.fn.executable("rg") ~= 1 then
    error("native rg is required")
  end
  local rows, result = {}, nil
  local job = process.start(
    { lines = lines, text = table.concat(lines, "\n") .. "\n", query = query, modes = modes, limits = limits },
    {
      on_items = function(batch)
        vim.list_extend(rows, batch)
      end,
      on_done = function(done)
        result = done
      end,
    }
  )
  t.assert_true(
    vim.wait(8000, function()
      return result ~= nil
    end, 2),
    "native rg completion"
  )
  t.assert_true(job.finished)
  return rows, assert(result, "native rg completed without a result")
end

local function owner()
  return {
    win = vim.api.nvim_get_current_win(),
    tab = vim.api.nvim_get_current_tabpage(),
    buf = vim.api.nvim_get_current_buf(),
    path = vim.api.nvim_buf_get_name(0),
  }
end

local function buffer(lines, fn)
  local original = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ok, err = pcall(fn, buf)
  vim.api.nvim_set_current_buf(original)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then
    error(err)
  end
end

t.describe("current document find memory and protocol", function()
  t.it("captures dirty unnamed rows and keeps the final blank logical line", function()
    buffer({ "alpha", "" }, function(buf)
      vim.bo[buf].endofline = false
      vim.bo[buf].fileformat = "dos"
      local snapshot = assert(find.snapshot(owner()))
      t.assert_eq(snapshot.text, "alpha\n\n")
      t.assert_eq(#snapshot.lines, 2)
      t.assert_true(vim.bo[buf].modified)
      t.assert_eq(vim.api.nvim_buf_get_name(buf), "")
    end)
    buffer({ "" }, function()
      t.assert_eq(assert(find.snapshot(owner())).text, "\n")
    end)
  end)

  t.it("checks source byte budget before copying buffer rows", function()
    buffer({ string.rep("a", 1024) }, function()
      local old, reads = vim.api.nvim_buf_get_lines, 0
      local function counted(...)
        reads = reads + 1
        return old(...)
      end
      vim.api.nvim_buf_get_lines = counted
      local ok, snapshot, reason = pcall(find.snapshot, owner(), { source_bytes = 100 })
      vim.api.nvim_buf_get_lines = old
      t.assert_true(ok)
      t.assert_nil(snapshot)
      t.assert_eq(reason, "source-too-large")
      t.assert_eq(reads, 0)
    end)
  end)

  t.it("rejects line-internal NUL representation rather than changing row positions", function()
    buffer({ "alpha\0beta" }, function()
      local snapshot, reason = find.snapshot(owner())
      t.assert_nil(snapshot)
      t.assert_eq(reason, "source-nul")
    end)
  end)

  t.it("returns every same-line hit using UTF8 byte offsets", function()
    local rows, result = native({ "α Needle Needle", "你 Needle" }, "Needle")
    t.assert_eq(result.state, "ready")
    t.assert_eq(#rows, 3)
    t.assert_eq(rows[1].col, 3)
    t.assert_eq(rows[2].col, 10)
    t.assert_eq(rows[3].col, 4)
    t.assert_eq(rows[1].end_col, 9)
    t.assert_eq(rows[3].lnum, 2)
  end)

  t.it("literal punctuation, explicit case, word, and Rust regex use actual rg", function()
    local rows = native({ "a.b axb A.B a.bx" }, "a.b")
    t.assert_eq(#rows, 3)
    rows = native({ "a.b axb A.B a.bx" }, "a.b", { case_sensitive = true })
    t.assert_eq(#rows, 2)
    rows = native({ "cat cats scat Cat" }, "cat", { whole_word = true })
    t.assert_eq(#rows, 2)
    rows = native({ "a.b axb A.B a.bx" }, "a.b", { regex = true, case_sensitive = true })
    t.assert_eq(#rows, 3)
  end)

  t.it("keeps initial dash queries as literal regexp arguments", function()
    for _, query in ipairs({ "-hello", "--" }) do
      local rows, result = native({ query .. " " .. query }, query)
      t.assert_eq(result.state, "ready")
      t.assert_eq(#rows, 2)
    end
  end)

  t.it("retains genuine CR bytes without introducing CRLF transformations", function()
    local rows, result = native({ "x\rNeedle Needle\r" }, "Needle")
    t.assert_eq(result.state, "ready")
    t.assert_eq(rows[1].col, 2)
    t.assert_eq(rows[2].col, 9)
  end)

  t.it("invalid regex and zero-width are explicit errors, including blank final rows", function()
    local _, invalid = native({ "alpha" }, "(", { regex = true })
    t.assert_eq(invalid.state, "error")
    t.assert_eq(invalid.reason, "rg-error")
    t.assert_match(invalid.stderr, "unclosed group")
    for _, lines in ipairs({ { "" }, { "a", "" }, { "α abc" } }) do
      local _, zero = native(lines, "^", { regex = true })
      t.assert_eq(zero.state, "error")
      t.assert_eq(zero.reason, "unsupported-zero-width")
    end
    local _, empty = native({ "α abc" }, "a*", { regex = true })
    t.assert_eq(empty.reason, "unsupported-zero-width")
  end)

  t.it("invalid UTF8 output is an explicit unsupported error", function()
    local _, result = native({ "a" .. string.char(255) .. "a" }, "a")
    t.assert_eq(result.state, "error")
    t.assert_eq(result.reason, "unsupported-binary-text")
  end)

  t.it("caps a dense JSON record before decode and reports a partial state", function()
    local rows, result = native({ string.rep("a", 128 * 1024) }, "a")
    t.assert_eq(result.state, "truncated")
    t.assert_eq(result.reason, "record-limit")
    t.assert_eq(#rows, 0)
    -- The huge match record has not reached the decoder.
    t.assert_true(result.records <= 1)
  end)

  t.it("counts submatches for result caps and distinguishes exact capacity", function()
    local rows, result = native({ "a a a a" }, "a", nil, { results = 3 })
    t.assert_eq(#rows, 3)
    t.assert_eq(result.state, "truncated")
    t.assert_eq(result.reason, "result-limit")
    rows, result = native({ "a a a" }, "a", nil, { results = 3 })
    t.assert_eq(#rows, 3)
    t.assert_eq(result.state, "ready")
  end)

  t.it("bounds display copies when many hits share a long source line", function()
    local text, from, to = process.snippet(string.rep("你", 50000), 90000, 90003)
    t.assert_true(#text < 300)
    t.assert_eq(to - from, 3)
    t.assert_eq(text:sub(from + 1, to), "你")
  end)

  t.it("empty and oversize query states never spawn a process", function()
    local original, spawned = vim.system, 0
    local function counted(...)
      spawned = spawned + 1
      return original(...)
    end
    vim.system = counted
    local ok, err = pcall(function()
      local _, result = native({ "alpha" }, "")
      t.assert_eq(result.state, "idle")
      _, result = native({ "alpha" }, string.rep("a", 100), nil, { query_bytes = 10 })
      t.assert_eq(result.reason, "query-too-large")
    end)
    vim.system = original
    t.assert_eq(spawned, 0)
    if not ok then
      error(err)
    end
  end)
end)

t.describe("current document find process lifecycle", function()
  t.it("post-spawn native closed-stdin failure reaps the registered child", function()
    local original, system = vim.system, nil
    local function close_stdin(...)
      system = original(...)
      local state = assert(rawget(system, "_state"))
      assert(state.stdin):close()
      return system
    end
    vim.system = close_stdin
    local ok, err = pcall(function()
      local _, result = native({ "alpha" }, "alpha")
      t.assert_eq(result.state, "error")
      t.assert_eq(result.reason, "stdin-incomplete")
      ---@type vim.SystemState
      local state = assert(rawget(assert(system), "_state"))
      for _, name in ipairs({ "stdin", "stdout", "stderr", "handle" }) do
        local pipe = state[name]
        t.assert_true(not pipe or pipe:is_closing(), name)
      end
    end)
    vim.system = original
    if not ok then
      error(err)
    end
  end)

  t.it("native deadline stops output and resolves the error after pipe EOF", function()
    local _, result = native({ string.rep("a", 128 * 1024) }, "a", nil, { deadline_ms = 1 })
    t.assert_eq(result.state, "error")
    t.assert_eq(result.reason, "deadline")
  end)

  t.it("actual exit waits for all scheduled result batches before completion", function()
    local rows, result = native({ string.rep("a ", 1000) }, "a")
    t.assert_eq(result.state, "ready")
    t.assert_eq(#rows, 1000)
    t.assert_eq(rows[1000].col, 1998)
    t.assert_eq(result.count, #rows)
  end)

  t.it("actual immediate cancellation closes all pipes and releases foreground once", function()
    local original = vim.system
    local admission = require("utils.host_admission")
    local original_done, released, system = admission.foreground_done, 0, nil
    admission.foreground_done = function(token)
      released = released + 1
      return original_done(token)
    end
    local function captured(...)
      system = original(...)
      return system
    end
    vim.system = captured
    local result, rows = nil, 0
    local ok, err = pcall(function()
      local line = string.rep("a", 1024 * 1024)
      local job = process.start({ lines = { line }, text = line .. "\n", query = "a" }, {
        on_items = function(batch)
          rows = rows + #batch
        end,
        on_done = function(done)
          result = done
        end,
      })
      job.cancel("native-close")
      job.cancel("again")
      t.assert_true(vim.wait(8000, function()
        return job.finished
      end, 2))
      local done = assert(result, "cancelled process completed without a result")
      t.assert_eq(done.state, "cancelled")
      t.assert_eq(done.reason, "native-close")
      t.assert_eq(rows, 0)
      ---@type vim.SystemState
      local state = assert(rawget(assert(system), "_state"))
      for _, name in ipairs({ "stdin", "stdout", "stderr", "handle" }) do
        local pipe = state[name]
        t.assert_true(not pipe or pipe:is_closing(), name)
      end
      t.assert_eq(released, 1)
    end)
    vim.system, admission.foreground_done = original, original_done
    if not ok then
      error(err)
    end
  end)

  t.it("spawn or stdin-write exception still resolves and releases admission", function()
    local original = vim.system
    local admission = require("utils.host_admission")
    local original_done, released = admission.foreground_done, 0
    local function failed()
      error("controlled stdin write failure")
    end
    vim.system = failed
    admission.foreground_done = function(token)
      released = released + 1
      return original_done(token)
    end
    local result
    local ok, err = pcall(function()
      local job = process.start({ lines = { "a" }, text = "a\n", query = "a" }, {
        on_done = function(done)
          result = done
        end,
      })
      t.assert_true(vim.wait(500, function()
        return job.finished
      end, 2))
      t.assert_eq(assert(result, "spawn failure completed without a result").reason, "spawn-failed")
      t.assert_eq(released, 1)
    end)
    vim.system, admission.foreground_done = original, original_done
    if not ok then
      error(err)
    end
  end)
end)
