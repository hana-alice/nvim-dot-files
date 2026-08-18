-- Real probes used by utils.core_health in its dedicated headless process.
-- Every write is scoped to ctx.temp_root; workspace-facing checks are read-only.

local M = {}

local uv = vim.uv or vim.loop

local function result(status, summary, evidence, next_step)
  return {
    status = status,
    summary = summary,
    evidence = evidence,
    next_step = next_step,
  }
end

local function join(...)
  return table.concat({ ... }, "/"):gsub("/+", "/")
end

local function basename(path)
  return tostring(path or ""):gsub("\\", "/"):match("([^/]+)$") or tostring(path or "")
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local value = file:read("*a")
  file:close()
  return value
end

local function write_file(path, value)
  local file, err = io.open(path, "wb")
  if not file then
    return false, err
  end
  file:write(value)
  file:close()
  return true
end

local function copy_file(source, destination)
  local value, read_err = read_file(source)
  if not value then
    return false, read_err
  end
  return write_file(destination, value)
end

local function process(argv, opts)
  opts = opts or {}
  local ok, handle = pcall(vim.system, argv, {
    cwd = opts.cwd,
    env = opts.env,
    text = true,
  })
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(handle), spawn_failed = true }
  end
  pcall(require("utils.task_registry").register, {
    name = "Neovim core health probe",
    group = "health",
    kind = "system",
    handle = handle,
  })
  local wait_ok, completed = pcall(handle.wait, handle, opts.timeout_ms or 10000)
  if not wait_ok then
    pcall(handle.kill, handle, 15)
    return { code = 124, stdout = "", stderr = tostring(completed), timed_out = true }
  end
  completed = completed or {}
  if completed.code == 124 then
    pcall(handle.kill, handle, 15)
    completed.timed_out = true
  end
  return completed
end

local function wait_for(done, timeout_ms, stop)
  local ok = vim.wait(timeout_ms, function()
    return done()
  end, 10, false)
  if not ok and stop then
    pcall(stop)
  end
  return ok
end

local function executable(candidates)
  for _, candidate in ipairs(candidates or {}) do
    if candidate and candidate ~= "" and vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

local function startup_check(ctx)
  local lazy_path = join(vim.fn.stdpath("data"), "lazy", "lazy.nvim")
  if not uv.fs_stat(lazy_path) then
    return result(
      "BLOCKED",
      "lazy.nvim is not already installed, so the non-mutating startup probe was not launched",
      nil,
      "Install the configured plugins normally, then rerun the audit."
    )
  end

  local nvim = vim.v.progpath ~= "" and vim.v.progpath or vim.fn.exepath("nvim")
  local init = join(ctx.config_root, "init.lua")
  local marker = "NVIM_CORE_HEALTH_STARTUP_OK"
  local command = table.concat({
    "lua vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' }); ",
    "require('utils.core_health').setup(); require('utils.core_health').setup(); ",
    "vim.api.nvim_out_write('",
    marker,
    " lazy=' .. vim.fn.exists(':Lazy') .. ' ue=' .. vim.fn.exists(':UEBuild') ",
    ".. ' health=' .. vim.fn.exists(':NvimCoreHealth') ",
    ".. ' map=' .. (vim.fn.maparg('<leader>ub', 'n') ~= '' and '1' or '0') .. '\\n')",
  })
  local completed = process({
    nvim,
    "--headless",
    "-i",
    "NONE",
    "-u",
    init,
    "-c",
    command,
    "-c",
    "qa!",
  }, {
    timeout_ms = 20000,
    env = vim.tbl_extend("force", vim.fn.environ(), {
      NVIM_CORE_HEALTH_NO_MUTATE = "1",
      XDG_CACHE_HOME = join(ctx.temp_root, "xdg-cache"),
      XDG_STATE_HOME = join(ctx.temp_root, "xdg-state"),
    }),
  })

  if completed.timed_out then
    return result(
      "FAIL",
      "real configuration startup exceeded its 20000ms deadline",
      nil,
      "Run the startup check by id and inspect plugin initialization."
    )
  end
  local output = tostring(completed.stdout or "") .. tostring(completed.stderr or "")
  local startup_error = output:find("Error detected while processing", 1, true) or output:match("E%d%d%d%d?:")
  local registrations_ok = output:match("lazy=(%d)") == "2"
    and output:match("ue=(%d)") == "2"
    and output:match("health=(%d)") == "2"
    and output:match("map=(%d)") == "1"
  if completed.code ~= 0 or not output:find(marker, 1, true) or startup_error or not registrations_ok then
    return result("FAIL", "real configuration startup failed", {
      exit_code = completed.code,
      marker_seen = output:find(marker, 1, true) ~= nil,
      startup_error = startup_error ~= nil,
      registrations = registrations_ok,
    }, "Run nvim --headless -u init.lua -i NONE and inspect the startup error.")
  end

  return result("PASS", "real init.lua loaded in non-mutating mode", {
    exit_code = completed.code,
    lazy_command = output:match("lazy=(%d)") == "2",
    ue_build_command = output:match("ue=(%d)") == "2",
    health_command = output:match("health=(%d)") == "2",
    ue_build_keymap = output:match("map=(%d)") == "1",
    repeated_health_setup = true,
  })
end

local function editor_check(ctx)
  local path = join(ctx.temp_root, "editor-transaction.cpp")
  local expected = {
    "namespace core_health {",
    "int transaction() { return 42; }",
    "}",
  }
  local wrote = false
  local group = vim.api.nvim_create_augroup("NvimCoreHealthEditor", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.cpp",
    callback = function(args)
      if args.file == path then
        wrote = true
      end
    end,
  })

  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, path)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, expected)
  vim.bo[buffer].filetype = vim.filetype.match({ filename = path }) or ""
  local option_ok = vim.bo[buffer].modifiable and vim.bo[buffer].buftype == ""
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("silent write")
  end)
  vim.api.nvim_buf_delete(buffer, { force = true })

  local reopened = vim.fn.bufadd(path)
  vim.fn.bufload(reopened)
  local actual = vim.api.nvim_buf_get_lines(reopened, 0, -1, false)
  local filetype = vim.filetype.match({ filename = path }) or ""
  vim.api.nvim_buf_delete(reopened, { force = true })
  vim.api.nvim_del_augroup_by_id(group)

  local content_ok = table.concat(actual, "\n") == table.concat(expected, "\n")
  if not (content_ok and filetype == "cpp" and option_ok and wrote) then
    return result("FAIL", "temporary create/edit/write/reopen transaction was inconsistent", {
      content = content_ok,
      filetype = filetype,
      options = option_ok,
      autocmd = wrote,
    }, "Run the editor check by id and inspect filetype/options/autocmd behavior.")
  end
  return result("PASS", "temporary create/edit/write/reopen transaction passed", {
    filetype = filetype,
    options = true,
    autocmd = true,
  })
end

local function mandatory_parsers(config_root)
  local ok, specs = pcall(dofile, join(config_root, "lua", "plugins", "treesitter.lua"))
  if not ok or type(specs) ~= "table" then
    return nil, tostring(specs)
  end
  local parsers = {}
  for _, spec in ipairs(specs) do
    local installed = type(spec) == "table" and spec.opts and spec.opts.ensure_installed or nil
    for _, language in ipairs(installed or {}) do
      parsers[#parsers + 1] = language
    end
  end
  table.sort(parsers)
  return parsers
end

local function node_has_problem(node)
  if node:has_error() or (node.missing and node:missing()) then
    return true
  end
  for child in node:iter_children() do
    if node_has_problem(child) then
      return true
    end
  end
  return false
end

local function syntax_check(language, fixture)
  return function(ctx)
    local path = join(ctx.config_root, "tests", "fixtures", "core_health", fixture)
    local buffer = vim.api.nvim_create_buf(false, true)
    local lines = vim.fn.readfile(path)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    local ok, parser = pcall(vim.treesitter.get_parser, buffer, language)
    if not ok or not parser then
      vim.api.nvim_buf_delete(buffer, { force = true })
      return result(
        "FAIL",
        language .. " parser could not be loaded",
        nil,
        "Install the mandatory " .. language .. " Tree-sitter parser outside the audit."
      )
    end
    local parsed_ok, trees = pcall(parser.parse, parser)
    local root = parsed_ok and trees and trees[1] and trees[1]:root() or nil
    local valid = root and root:named_child_count() > 0 and not node_has_problem(root)
    local evidence = root
        and {
          language = language,
          root_type = root:type(),
          named_children = root:named_child_count(),
          error_free = valid == true,
        }
      or { language = language }
    vim.api.nvim_buf_delete(buffer, { force = true })
    if not valid then
      return result(
        "FAIL",
        language .. " fixture did not produce a complete syntax tree",
        evidence,
        "Repair or reinstall the mandatory " .. language .. " parser outside the audit."
      )
    end
    return result("PASS", language .. " fixture produced a complete syntax tree", evidence)
  end
end

local function prepare_search_fixture(ctx)
  local root = join(ctx.temp_root, "search")
  vim.fn.mkdir(root, "p")
  local files = { "Alpha.cpp", "Beta.h" }
  for _, name in ipairs(files) do
    local ok, err =
      copy_file(join(ctx.config_root, "tests", "fixtures", "core_health", "search", name), join(root, name))
    if not ok then
      return nil, err
    end
  end
  return root, files
end

local function collect_search(code_search, context, search_root, timeout_ms)
  local matches, done, exit_code, error_message = {}, false, nil, nil
  local stop = code_search.stream(context, "MixedCaseNeedle", {
    regex = false,
    case = true,
    code_only = true,
    search_dirs = { search_root },
  }, {
    on_line = function(file, line, column, text)
      matches[#matches + 1] = { file = basename(file), line = line, column = column, text = text }
    end,
    on_done = function(code, err)
      exit_code, error_message, done = code, err, true
    end,
  })
  local completed = wait_for(function()
    return done
  end, timeout_ms, stop)
  return completed, matches, exit_code, error_message
end

local function rg_check(ctx)
  if vim.fn.executable("rg") ~= 1 then
    return result("FAIL", "rg fallback is unavailable", nil, "Install ripgrep and rerun the audit.")
  end
  local root, fixture_error = prepare_search_fixture(ctx)
  if not root then
    return result("FAIL", "search fixture could not be prepared: " .. tostring(fixture_error))
  end
  local code_search = require("utils.code_search")
  local context = { workspace_root = root, csearch_idx = join(ctx.temp_root, "missing-csearch.idx") }
  local completed, matches, exit_code, error_message = collect_search(code_search, context, root, 5000)
  if not completed then
    return result(
      "FAIL",
      "rg dispatcher query exceeded its 5000ms deadline",
      nil,
      "Run the search check by id and inspect rg process completion."
    )
  end
  if exit_code ~= 0 or #matches ~= 2 then
    return result("FAIL", "rg dispatcher did not return the two expected fixture hits", {
      backend = code_search.current_backend(context),
      exit_code = exit_code,
      hit_count = #matches,
      error = error_message,
    }, "Verify ripgrep and the public code_search dispatcher.")
  end
  table.sort(matches, function(a, b)
    return a.file < b.file
  end)
  return result("PASS", "rg fallback returned exact fixture hits before completion", {
    backend = code_search.current_backend(context),
    hits = matches,
  })
end

local function csearch_check(ctx)
  local code_search = require("utils.code_search")
  local csearch = code_search.csearch_exe()
  local cindex = code_search.cindex_uefilter_exe()
  local classified =
    require("utils.core_health").classify_search_tools(vim.fn.executable("rg") == 1, csearch ~= nil, cindex ~= nil)
  if classified.status ~= "PASS" then
    return result("BLOCKED", classified.summary, {
      backend = classified.backend,
      missing = classified.missing,
    }, "Install the indexed-search tools via: " .. code_search.install_hint())
  end

  local root, files = prepare_search_fixture(ctx)
  if not root then
    return result("FAIL", "csearch fixture could not be prepared")
  end
  local list_path = join(ctx.temp_root, "csearch-files.txt")
  local absolute = {}
  for _, name in ipairs(files) do
    absolute[#absolute + 1] = join(root, name)
  end
  vim.fn.writefile(absolute, list_path)
  local original_index = vim.env.CSEARCHINDEX
  local context = { workspace_root = root, csearch_idx = join(ctx.temp_root, "csearch.idx") }
  local done, build_ok, build_error = false, false, nil
  local stop_build = code_search.build_index(context, list_path, function(ok, err)
    build_ok, build_error, done = ok, err, true
  end, { mode = "reset" })
  if not wait_for(function()
    return done
  end, 10000, stop_build) then
    return result("FAIL", "temporary csearch index build exceeded its 10000ms deadline")
  end
  if not build_ok then
    return result(
      "FAIL",
      "temporary csearch index build failed",
      { error = build_error },
      "Verify cindex-uefilter against a temporary file list."
    )
  end
  local completed, matches, exit_code, error_message = collect_search(code_search, context, root, 5000)
  local environment_unchanged = vim.env.CSEARCHINDEX == original_index
  if not completed or exit_code ~= 0 or #matches ~= 2 or not environment_unchanged then
    return result("FAIL", "temporary csearch round trip was inconsistent", {
      backend = code_search.current_backend(context),
      completed = completed,
      exit_code = exit_code,
      hit_count = #matches,
      parent_environment_unchanged = environment_unchanged,
      error = error_message,
    }, "Verify cindex/csearch without changing the parent CSEARCHINDEX.")
  end
  return result("PASS", "temporary cindex/csearch round trip returned exact fixture hits", {
    backend = code_search.current_backend(context),
    index_scope = "runner-temporary",
    hit_count = #matches,
    parent_environment_unchanged = true,
  })
end

local function clangd_check()
  local ok, command = pcall(function()
    return require("ue").clangd_cmd()
  end)
  local clangd = ok and type(command) == "table" and command[1] or nil
  if not clangd or vim.fn.executable(clangd) ~= 1 then
    return result(
      "BLOCKED",
      "configured clangd executable is unavailable",
      nil,
      "Install clangd 22.1.x or configure the UE clangd executable."
    )
  end
  local completed = process({ clangd, "--version" }, { timeout_ms = 5000 })
  if completed.timed_out then
    return result(
      "BLOCKED",
      "configured clangd version probe timed out",
      nil,
      "Verify the configured clangd executable outside the audit."
    )
  end
  local classified = require("utils.core_health").classify_clangd_version(
    tostring(completed.stdout or "") .. tostring(completed.stderr or "")
  )
  return result(classified.status, classified.summary, {
    executable = basename(clangd),
    version = classified.version,
    compatible = classified.compatible,
  }, classified.compatible and nil or "Install or select clangd 22.1.x for UE compiler semantics.")
end

local function cdb_fixture_check(ctx)
  local source = join(ctx.config_root, "tests", "fixtures", "core_health", "sample.cpp")
  local copied = join(ctx.temp_root, "sample.cpp")
  local ok, err = copy_file(source, copied)
  if not ok then
    return result("FAIL", "CDB fixture could not be copied: " .. tostring(err))
  end
  local payload = {
    {
      directory = ctx.temp_root,
      file = copied,
      arguments = { "clang++", "-std=c++20", "-c", copied },
      provenance = { source = "core-health-fixture", tuple = "deterministic" },
    },
  }
  local path = join(ctx.temp_root, "compile_commands.json")
  local written, write_error = write_file(path, vim.json.encode(payload))
  if not written then
    return result("FAIL", "CDB fixture could not be written: " .. tostring(write_error))
  end
  local encoded = read_file(path)
  local decoded_ok, entries = pcall(vim.json.decode, encoded or "")
  local template = decoded_ok and require("ue.cdb.json").template_entry(entries) or {}
  local valid = template.directory == ctx.temp_root
    and template.file == copied
    and type(template.arguments) == "table"
    and template.arguments[1] == "clang++"
    and template.provenance
    and template.provenance.source == "core-health-fixture"
  if not valid then
    return result("FAIL", "fixture compilation database schema/provenance was invalid")
  end
  return result("PASS", "fixture compilation database schema and provenance passed", {
    entry_count = #entries,
    argument_form = true,
    provenance = template.provenance.source,
  })
end

local function target_plan_check()
  local targets = require("ue.targets")
  local expected = { "Android", "IOS", "Linux", "Mac", "Win64" }
  local ids = targets.known_ids()
  if table.concat(ids, ",") ~= table.concat(expected, ",") then
    return result("FAIL", "target registry does not expose the expected platform identities", { ids = ids })
  end
  local hosts = {
    windows = {
      id = "windows",
      ue_build_entry = function() return "/fixture/windows/Build.bat" end,
    },
    macos = {
      id = "macos",
      ue_build_entry = function() return "/fixture/macos/Build.sh" end,
    },
    linux = {
      id = "linux",
      ue_build_entry = function() return "/fixture/linux/Build.sh" end,
    },
  }
  local host_for_target = {
    Android = hosts.windows,
    IOS = hosts.macos,
    Linux = hosts.linux,
    Mac = hosts.macos,
    Win64 = hosts.windows,
  }
  local platforms = {}
  for _, id in ipairs(ids) do
    local plan = targets.build_plan(id, {
      engine_root = "/fixture/Engine",
      uproject = "/fixture/Game.uproject",
      target = "Game",
      configuration = "Development",
      cwd = "/fixture",
    }, host_for_target[id])
    local args = type(plan) == "table" and plan.args or {}
    local valid = plan
      and plan.executable == host_for_target[id].ue_build_entry()
      and args[2] == id
    if not valid then
      return result("FAIL", id .. " target did not produce an isolated structured build plan", {
        platform = id,
        status = plan and plan.status,
      })
    end
    platforms[#platforms + 1] = args[2]
  end
  local _, mac_android = targets.resolve("Android", "build", hosts.macos)
  local _, windows_ios = targets.resolve("IOS", "build", hosts.windows)
  if mac_android.status ~= "unavailable" or windows_ios.status ~= "unavailable" then
    return result("FAIL", "target matrix did not reject incompatible fixture hosts")
  end
  return result("PASS", "all compatible host-target pairs produced isolated plans; foreign pairs were rejected", {
    platforms = platforms,
    ios_mac_distinct = platforms[2] == "IOS" and platforms[4] == "Mac",
    incompatible_pairs_rejected = true,
  })
end

function M.definitions(opts)
  opts = opts or {}
  local definitions = {
    { id = "startup.config", stage = "startup", timeout_ms = 22000, run = startup_check },
    { id = "editor.transaction", stage = "editor", timeout_ms = 3000, run = editor_check },
  }
  local parsers, parser_error = mandatory_parsers(opts.config_root or vim.fn.stdpath("config"))
  local fixtures = { c = "sample.c", cpp = "sample.cpp", hlsl = "sample.hlsl" }
  if not parsers then
    definitions[#definitions + 1] = {
      id = "syntax.config",
      stage = "syntax",
      run = function()
        return result("FAIL", "mandatory parser configuration could not be loaded", { error = parser_error })
      end,
    }
  else
    for _, language in ipairs(parsers) do
      local fixture = fixtures[language]
      definitions[#definitions + 1] = {
        id = "syntax." .. language .. ".parse",
        stage = "syntax",
        timeout_ms = 3000,
        run = fixture and syntax_check(language, fixture) or function()
          return result("FAIL", "mandatory parser has no deterministic fixture", { language = language })
        end,
      }
    end
  end
  vim.list_extend(definitions, {
    { id = "search.rg", stage = "search", timeout_ms = 6000, run = rg_check },
    { id = "search.csearch", stage = "search", timeout_ms = 16000, run = csearch_check },
    { id = "compiler.clangd", stage = "compiler", timeout_ms = 6000, run = clangd_check },
    { id = "compiler.cdb.fixture", stage = "compiler", timeout_ms = 3000, run = cdb_fixture_check },
    { id = "ue.target_plans", stage = "ue", timeout_ms = 3000, run = target_plan_check },
  })
  vim.list_extend(
    definitions,
    require("utils.core_health_live").definitions({
      result = result,
      uv = uv,
      read_file = read_file,
      process = process,
      wait_for = wait_for,
      executable = executable,
      join = join,
    })
  )
  return definitions
end

M._startup_argv_contract = {
  "--headless",
  "-i",
  "NONE",
  "-u",
  "init.lua",
}
M._mandatory_parsers_for_test = mandatory_parsers
M._syntax_check_for_test = syntax_check

return M
