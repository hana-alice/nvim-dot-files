if _G.arg and _G.arg[1] == "--file-inventory-native" then
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  vim.opt.runtimepath:prepend(root)
  package.path = root
    .. "/?.lua;"
    .. root
    .. "/?/init.lua;"
    .. root
    .. "/lua/?.lua;"
    .. root
    .. "/lua/?/init.lua;"
    .. package.path
end

local t = require("tests.harness")
local cfg = t.bootstrap()

local names = {
  "cold and hot preserve all-file coverage",
  "scopes do not borrow another project inventory",
  "hidden ignored and excludes have separate identities",
  "extension filters preserve cold and hot code coverage",
  "cancelled native scan never publishes a complete cache",
  "native finder errors never publish a complete cache",
  "file budget does not truncate displayed results",
  "path-byte budget does not truncate displayed results",
  "refresh reflects added and deleted files",
  "scope cache is bounded and evicts its oldest entry",
  "invalidation prevents an active scan republishing stale paths",
  "real files source keeps configured hooks and refresh action",
}

local function fixture(root)
  local files = {
    "Project/Source/Alpha.cpp",
    "Project/Source/Alpha.h",
    "Project/Source/Space Name.cpp",
    "Project/README.md",
    "Project/notes.txt",
    "Project/scripts/run.ps1",
    "Project/scripts/boot.sh",
    "Project/scripts/prepare.bat",
    "Project/Game.uproject",
    "Project/Config/DefaultEngine.ini",
    "Engine/Source/Beta.cpp",
    "Engine/Config/Engine.ini",
    "Engine/Docs/Guide.md",
    "Project/Binaries/app.exe",
    "Project/Intermediate/cache.cpp",
    "Project/Saved/log.txt",
    "Project/Content/asset.uasset",
    "Project/.hidden.cfg",
    "Project/ignored.txt",
  }
  for _, file in ipairs(files) do
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. file), "p")
    vim.fn.writefile({ "fixture" }, root .. "/" .. file)
  end
  vim.fn.writefile({ "ignored.txt" }, root .. "/Project/.ignore")
  return {
    cwd = root,
    dirs = { root .. "/Project", root .. "/Engine" },
    exclude = { "Binaries", "Intermediate", "Saved", "Content" },
    hidden = false,
    ignored = false,
    follow = false,
  }
end

local function native_case(number, root, plugin)
  root = vim.fs.normalize((vim.uv or vim.loop).fs_realpath(root) or root)
  vim.opt.runtimepath:prepend(plugin)
  require("snacks")
  local Async = require("snacks.picker.util.async")
  local inventory = require("utils.file_inventory")
  local opts = fixture(root)
  local function collect(options, on_item)
    local ctx = { filter = { search = "" }, meta = {} }
    local found, finished, failure = {}, false, nil
    local finder = inventory.find(options, ctx)
    local task
    task = Async.new(function()
      finder(function(item)
        found[#found + 1] = item.file
        if on_item then
          on_item(item, task, #found)
        end
      end)
    end)
      :on("error", function(err)
        failure = err
      end)
      :on("done", function()
        finished = true
      end)
    t.assert_true(
      vim.wait(10000, function()
        return finished
      end, 5),
      "real fd finder must finish"
    )
    if failure then
      error(failure)
    end
    table.sort(found)
    return found, ctx.meta.file_inventory
  end
  local function has(paths, file)
    return vim.tbl_contains(paths, vim.fs.normalize(root .. "/" .. file))
  end
  local function same(a, b)
    t.assert_eq(vim.json.encode(a), vim.json.encode(b))
  end

  if number == 1 then
    local registry = require("utils.task_registry")
    local before = #registry.list()
    local cold, cold_meta = collect(opts)
    local after_scan = #registry.list()
    local hot, hot_meta = collect(opts)
    same(cold, hot)
    t.assert_eq(cold_meta.state, "complete")
    t.assert_eq(hot_meta.state, "cached")
    t.assert_eq(after_scan, before + 1, "cold finder owns one actual native task")
    t.assert_eq(#registry.list(), after_scan, "hot finder must not spawn another native task")
    t.assert_eq(#cold, 13)
    for _, file in ipairs({
      "Project/README.md",
      "Project/notes.txt",
      "Project/scripts/run.ps1",
      "Project/scripts/boot.sh",
      "Project/scripts/prepare.bat",
      "Project/Game.uproject",
      "Project/Config/DefaultEngine.ini",
      "Project/Source/Alpha.cpp",
      "Engine/Docs/Guide.md",
    }) do
      t.assert_true(has(cold, file), "missing all-file item " .. file)
    end
    t.assert_false(has(cold, "Project/Intermediate/cache.cpp"))
  elseif number == 2 then
    collect(opts)
    local project = vim.deepcopy(opts)
    project.dirs = { root .. "/Project" }
    local paths, meta = collect(project)
    t.assert_eq(meta.state, "complete")
    t.assert_true(has(paths, "Project/Game.uproject"))
    t.assert_false(has(paths, "Engine/Source/Beta.cpp"))
    local original, warm = collect(opts)
    t.assert_eq(warm.state, "cached")
    t.assert_true(has(original, "Engine/Source/Beta.cpp"))
  elseif number == 3 then
    local original = collect(opts)
    local hidden = vim.deepcopy(opts)
    hidden.hidden = true
    local hidden_files, hidden_meta = collect(hidden)
    t.assert_eq(hidden_meta.state, "complete")
    t.assert_false(has(original, "Project/.hidden.cfg"))
    t.assert_true(has(hidden_files, "Project/.hidden.cfg"))
    local ignored = vim.deepcopy(opts)
    ignored.ignored = true
    local ignored_files = collect(ignored)
    t.assert_false(has(original, "Project/ignored.txt"))
    t.assert_true(has(ignored_files, "Project/ignored.txt"))
    t.assert_false(has(ignored_files, "Project/Content/asset.uasset"))
    local expanded = vim.deepcopy(opts)
    expanded.exclude = { "Binaries", "Intermediate", "Saved" }
    t.assert_true(has(collect(expanded), "Project/Content/asset.uasset"))
  elseif number == 4 then
    collect(opts)
    local code = vim.deepcopy(opts)
    code.ft = { "cpp", "h" }
    local cold, meta = collect(code)
    local hot, hot_meta = collect(code)
    same(cold, hot)
    t.assert_eq(meta.state, "complete")
    t.assert_eq(hot_meta.state, "cached")
    t.assert_eq(#cold, 4)
    t.assert_true(has(cold, "Engine/Source/Beta.cpp"))
    t.assert_false(has(cold, "Project/README.md"))
  elseif number == 5 then
    local partial, meta = collect(opts, function(_, task)
      task:abort()
    end)
    t.assert_eq(#partial, 1)
    t.assert_eq(meta.state, "cancelled")
    t.assert_false(meta.complete)
    t.assert_nil(inventory.cache_info(opts))
    local full, full_meta = collect(opts)
    t.assert_eq(full_meta.state, "complete")
    t.assert_eq(#full, 13)
  elseif number == 6 then
    local absent = vim.deepcopy(opts)
    absent.dirs = { root .. "/absent-directory" }
    local paths, meta = collect(absent)
    t.assert_eq(#paths, 0)
    t.assert_eq(meta.state, "error")
    t.assert_false(meta.complete)
    t.assert_nil(inventory.cache_info(absent))
  elseif number == 7 or number == 8 then
    local bounded = vim.deepcopy(opts)
    if number == 7 then
      bounded.inventory_max_files = 3
    else
      bounded.inventory_max_bytes = 10
    end
    local all, meta = collect(bounded)
    t.assert_eq(#all, 13)
    t.assert_eq(meta.state, "uncached")
    t.assert_true(meta.complete)
    t.assert_true(meta.over_budget)
    t.assert_nil(inventory.cache_info(bounded))
    local repeated, again = collect(bounded)
    same(all, repeated)
    t.assert_eq(again.state, "uncached")
  elseif number == 9 then
    local before = collect(opts)
    vim.fn.writefile({ "new" }, root .. "/Project/new.md")
    vim.fn.delete(root .. "/Project/README.md")
    local snapshot, meta = collect(opts)
    same(before, snapshot)
    t.assert_eq(meta.state, "cached")
    inventory.invalidate(opts)
    local current, current_meta = collect(opts)
    t.assert_eq(current_meta.state, "complete")
    t.assert_true(has(current, "Project/new.md"))
    t.assert_false(has(current, "Project/README.md"))
  elseif number == 10 then
    local scopes = {}
    for i = 1, inventory.MAX_SCOPES + 1 do
      local dir = root .. "/scope" .. i
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({ "x" }, dir .. "/one.txt")
      scopes[i] = { cwd = root, dirs = { dir } }
      t.assert_eq(#collect(scopes[i]), 1)
    end
    t.assert_nil(inventory.cache_info(scopes[1]))
    t.assert_eq(inventory.cache_info(scopes[#scopes]).count, 1)
  elseif number == 11 then
    local all, meta = collect(opts, function(_, _, count)
      if count == 1 then
        inventory.invalidate(opts)
      end
    end)
    t.assert_eq(#all, 13)
    t.assert_eq(meta.state, "uncached")
    t.assert_true(meta.complete)
    t.assert_false(meta.over_budget)
    t.assert_nil(inventory.cache_info(opts))
  elseif number == 12 then
    local source = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { "original unsaved content" })
    local normalized = 0
    local confirm = function() end
    Snacks.setup({
      picker = {
        sources = {
          files = {
            confirm = confirm,
            filter = {
              transform = function()
                normalized = normalized + 1
                return false
              end,
            },
          },
        },
      },
    })
    local picker = inventory.open(opts)
    t.assert_eq(picker.opts.source, "files")
    t.assert_eq(picker.opts.confirm, confirm)
    t.assert_true(vim.wait(10000, function()
      return not picker.finder:running()
    end, 5))
    t.assert_eq(picker:count(), 13)
    t.assert_true(normalized > 0)
    t.assert_eq(picker.opts.win.input.keys["<F5>"][1], "file_inventory_refresh")
    vim.fn.writefile({ "new" }, root .. "/Project/new.md")
    picker:action("file_inventory_refresh")
    t.assert_true(vim.wait(10000, function()
      return not picker.finder:running()
    end, 5))
    t.assert_eq(picker:count(), 14)
    picker:close()
    t.assert_true(vim.bo[source].modified)
    t.assert_eq(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1], "original unsaved content")
  end
end

if _G.arg and _G.arg[1] == "--file-inventory-native" then
  t.describe("file inventory native", function()
    local number = tonumber(_G.arg[2])
    t.it(names[number], function()
      native_case(number, _G.arg[3], _G.arg[4])
    end)
  end)
  t.run({ exit = false })
  for _, result in ipairs(t.results()) do
    if not result.ok and not result.skipped then
      vim.cmd("cquit 1")
      return
    end
  end
  vim.cmd("qall!")
  return
end

t.describe("file inventory native", function()
  local plugin = vim.fn.stdpath("data") .. "/lazy/snacks.nvim"
  local fd = require("ue.core.proc").first_executable({ "fd", "fdfind" })
  if not fd or vim.fn.filereadable(plugin .. "/lua/snacks/init.lua") ~= 1 then
    t.skip("real fd and Snacks finder contract", "installed fd/fdfind and snacks.nvim are required", { native = true })
    return
  end
  for number, name in ipairs(names) do
    t.it(name, function()
      local root = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(root, "p")
      local ok, err = xpcall(function()
        local result = vim
          .system({
            vim.v.progpath,
            "--headless",
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-l",
            cfg .. "/tests/cases/file_inventory_spec.lua",
            "--file-inventory-native",
            tostring(number),
            root,
            plugin,
          }, { text = true })
          :wait(15000)
        t.assert_eq(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
      end, debug.traceback)
      vim.fn.delete(root, "rf")
      if not ok then
        error(err)
      end
    end)
  end
end)
