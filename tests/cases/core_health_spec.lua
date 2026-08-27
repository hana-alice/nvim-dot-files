local t = require("tests.harness")
local config_root = t.bootstrap():gsub("\\", "/")

local health = require("utils.core_health")

local function check(id, stage, status, extra)
  local value = {
    id = id,
    stage = stage,
    status = status,
    duration_ms = 1,
    summary = id .. " is " .. status,
  }
  for key, item in pairs(extra or {}) do
    value[key] = item
  end
  return value
end

local function ids(items)
  local result = {}
  for _, item in ipairs(items or {}) do
    result[#result + 1] = item.id
  end
  table.sort(result)
  return table.concat(result, ",")
end

local function status_by_id(report, id)
  for _, item in ipairs(report.checks or {}) do
    if item.id == id then
      return item.status
    end
  end
end

t.describe("core_health: status aggregation", function()
  t.it("PASS and SKIP remain an overall PASS", function()
    t.assert_eq(
      health.overall_status({
        check("editor.transaction", "editor", "PASS"),
        check("live.workspace", "live", "SKIP"),
      }),
      "PASS"
    )
  end)

  t.it("BLOCKED degrades without becoming a deterministic failure", function()
    t.assert_eq(
      health.overall_status({
        check("search.rg", "search", "PASS"),
        check("search.csearch", "search", "BLOCKED"),
      }),
      "DEGRADED"
    )
  end)

  t.it("FAIL wins over PASS, BLOCKED, and SKIP", function()
    t.assert_eq(
      health.overall_status({
        check("syntax.cpp.parse", "syntax", "FAIL"),
        check("compiler.clangd", "compiler", "BLOCKED"),
        check("live.workspace", "live", "SKIP"),
        check("editor.transaction", "editor", "PASS"),
      }),
      "FAIL"
    )
  end)

  t.it("Tree-sitter and compiler semantics keep independent statuses", function()
    local checks = {
      check("syntax.cpp.parse", "syntax", "PASS"),
      check("compiler.clangd", "compiler", "BLOCKED"),
    }
    t.assert_eq(health.overall_status(checks), "DEGRADED")
    t.assert_eq(checks[1].status, "PASS")
    t.assert_eq(checks[2].status, "BLOCKED")
  end)
end)

t.describe("core_health: report redaction", function()
  t.it("redacts nested path, device, certificate, and environment identities", function()
    local home = "/Users/example-person"
    local project = home .. "/Documents/SecretProject"
    local device = "00008120-0012345E0C91801E"
    local certificate = "Apple Development: Example Person (A1B2C3D4E5)"
    local secret = "super-secret-token"
    local original = {
      summary = "read " .. project .. "/Game.uproject",
      evidence = {
        path = project .. "/Saved/Index",
        devices = { device },
        certificate_identity = certificate,
        environment = { API_TOKEN = secret },
      },
    }

    local redacted = health.redact(original, {
      sensitive_roots = { home, project, device, certificate, secret },
    })
    local encoded = vim.json.encode(redacted)

    t.assert_false(encoded:find(home, 1, true) ~= nil)
    t.assert_false(encoded:find("SecretProject", 1, true) ~= nil)
    t.assert_false(encoded:find(device, 1, true) ~= nil)
    t.assert_false(encoded:find(certificate, 1, true) ~= nil)
    t.assert_false(encoded:find(secret, 1, true) ~= nil)
    t.assert_contains(encoded, "redacted")
    t.assert_contains(original.summary, project, "redaction must not mutate the input report")
    t.assert_eq(original.evidence.devices[1], device)
  end)

  t.it("JSON encoding cannot reintroduce a redacted identity", function()
    local identity = [[C:\Users\Example\Documents\PrivateGame]]
    local report = {
      schema_version = 1,
      mode = "deterministic",
      overall = "PASS",
      checks = {
        check("editor.transaction", "editor", "PASS", {
          evidence = { workspace = identity },
        }),
      },
    }
    local encoded = health.encode_json(health.redact(report, {
      sensitive_roots = { identity },
    }))
    t.assert_false(encoded:find(identity, 1, true) ~= nil)
    t.assert_contains(encoded, "redacted")
  end)
end)

t.describe("core_health: filter selection", function()
  local definitions = {
    { id = "startup.config", stage = "startup" },
    { id = "syntax.c.parse", stage = "syntax" },
    { id = "syntax.cpp.parse", stage = "syntax" },
    { id = "search.rg", stage = "search" },
  }

  t.it("nil filter preserves the complete ordered definition set", function()
    local selected = health.filter_checks(definitions)
    t.assert_eq(ids(selected), "search.rg,startup.config,syntax.c.parse,syntax.cpp.parse")
    t.assert_eq(selected[1].id, "startup.config", "filtering must preserve execution order")
  end)

  t.it("accepts an exact id", function()
    local selected = health.filter_checks(definitions, "syntax.cpp.parse")
    t.assert_eq(#selected, 1)
    t.assert_eq(selected[1].id, "syntax.cpp.parse")
  end)

  t.it("accepts a stage or id prefix without selecting unrelated checks", function()
    t.assert_eq(ids(health.filter_checks(definitions, "syntax")), "syntax.c.parse,syntax.cpp.parse")
    t.assert_eq(ids(health.filter_checks(definitions, "search")), "search.rg")
  end)

  t.it("unknown filters select no checks", function()
    t.assert_eq(#health.filter_checks(definitions, "device.install"), 0)
  end)
end)

t.describe("core_health: external tool classification", function()
  t.it("requires clangd 22.1.x without failing unrelated syntax checks", function()
    local compatible = health.classify_clangd_version("clangd version 22.1.6")
    local old = health.classify_clangd_version("Apple clangd version 17.0.0")
    local unknown = health.classify_clangd_version("not a clangd version banner")

    t.assert_eq(compatible.status, "PASS")
    t.assert_true(compatible.compatible)
    t.assert_eq(compatible.version, "22.1.6")
    t.assert_eq(old.status, "BLOCKED")
    t.assert_false(old.compatible)
    t.assert_eq(unknown.status, "BLOCKED")
  end)

  t.it("reports rg fallback independently from csearch/cindex gates", function()
    local complete = health.classify_search_tools(true, true, true)
    local no_csearch = health.classify_search_tools(true, false, true)
    local no_cindex = health.classify_search_tools(true, true, false)
    local no_search = health.classify_search_tools(false, false, false)

    t.assert_eq(complete.status, "PASS")
    t.assert_eq(complete.backend, "csearch")
    t.assert_eq(no_csearch.status, "BLOCKED")
    t.assert_eq(no_csearch.backend, "rg")
    t.assert_contains(no_csearch.missing, "csearch")
    t.assert_eq(no_cindex.status, "BLOCKED")
    t.assert_contains(no_cindex.missing, "cindex-uefilter")
    t.assert_eq(no_search.status, "FAIL")
  end)
end)

t.describe("core_health: deterministic runner contract", function()
  local clock = 0
  local function run(definitions, opts)
    opts = vim.tbl_extend("force", opts or {}, {
      checks = nil,
      temp_root = "/virtual/core-health-test",
      config_root = "/virtual/config",
      deps = {
        mkdir = function()
          return true
        end,
        now_ms = function()
          clock = clock + 1
          return clock
        end,
      },
    })
    return health.run_checks(definitions, opts)
  end

  local function definition(id, stage, status, callback)
    return {
      id = id,
      stage = stage,
      run = function(context)
        if callback then
          callback(context)
        end
        return {
          status = status,
          summary = id .. " result",
          next_step = status == "PASS" and nil or "repair " .. id,
        }
      end,
    }
  end

  t.it("emits the stable schema and exit code for injected checks", function()
    local report = run({
      definition("startup.config", "startup", "PASS"),
      definition("compiler.clangd", "compiler", "BLOCKED"),
      definition("live.workspace", "live", "SKIP"),
    }, {
      mode = "deterministic",
    })

    t.assert_eq(report.schema_version, 1)
    t.assert_eq(report.mode, "deterministic")
    t.assert_eq(report.overall, "DEGRADED")
    t.assert_eq(#report.checks, 3)
    t.assert_eq(
      health.exit_code(report),
      0,
      "external BLOCKED/SKIP gates are report detail, not deterministic failures"
    )
    for _, item in ipairs(report.checks) do
      t.assert_type(item.id, "string")
      t.assert_type(item.stage, "string")
      t.assert_type(item.status, "string")
      t.assert_type(item.duration_ms, "number")
      t.assert_true(item.duration_ms >= 0)
      t.assert_type(item.summary, "string")
    end
  end)

  t.it("isolates a throwing check, records FAIL, and continues", function()
    local later_ran = false
    local report = run({
      {
        id = "startup.crash",
        stage = "startup",
        run = function()
          error("fixture explosion")
        end,
      },
      definition("editor.transaction", "editor", "PASS", function()
        later_ran = true
      end),
    }, {
      mode = "deterministic",
    })

    t.assert_true(later_ran, "one failed capability must not hide later evidence")
    t.assert_eq(report.overall, "FAIL")
    t.assert_eq(status_by_id(report, "startup.crash"), "FAIL")
    t.assert_eq(status_by_id(report, "editor.transaction"), "PASS")
    t.assert_eq(health.exit_code(report), 1)
  end)

  t.it("applies filter before invoking definitions", function()
    local calls = {}
    local report = run({
      definition("startup.config", "startup", "PASS", function()
        calls[#calls + 1] = "startup.config"
      end),
      definition("syntax.cpp.parse", "syntax", "PASS", function()
        calls[#calls + 1] = "syntax.cpp.parse"
      end),
    }, {
      mode = "deterministic",
      filter = "syntax",
    })

    t.assert_eq(table.concat(calls, ","), "syntax.cpp.parse")
    t.assert_eq(ids(report.checks), "syntax.cpp.parse")
  end)

  t.it("two runs have identical capability ids and status shape", function()
    local definitions = {
      definition("editor.transaction", "editor", "PASS"),
      definition("search.rg", "search", "PASS"),
      definition("search.csearch", "search", "BLOCKED"),
    }
    local first = run(definitions, { mode = "deterministic" })
    local second = run(definitions, { mode = "deterministic" })

    t.assert_eq(ids(first.checks), ids(second.checks))
    for _, item in ipairs(first.checks) do
      t.assert_eq(status_by_id(second, item.id), item.status, item.id)
    end
  end)

  t.it("turns an exceeded deterministic deadline into an explicit FAIL", function()
    local timestamps = { 100, 111 }
    local report = health.run_checks({
      {
        id = "syntax.cpp.parse",
        stage = "syntax",
        timeout_ms = 10,
        run = function()
          return { status = "PASS", summary = "late parser result" }
        end,
      },
    }, {
      temp_root = "/virtual/core-health-deadline",
      config_root = "/virtual/config",
      deps = {
        mkdir = function()
          return true
        end,
        now_ms = function()
          return table.remove(timestamps, 1)
        end,
      },
    })

    t.assert_eq(report.overall, "FAIL")
    t.assert_eq(report.checks[1].status, "FAIL")
    t.assert_eq(report.checks[1].deadline_ms, 10)
    t.assert_contains(report.checks[1].summary, "deadline")
  end)

  t.it("keeps edit writes inside the runner temp root and cleans them", function()
    local observed_root
    local report = health.run_checks({
      {
        id = "editor.transaction",
        stage = "editor",
        run = function(context)
          observed_root = context.temp_root
          local path = context.temp_root .. "/transaction.cpp"
          local buffer = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_name(buffer, path)
          vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
            "int core_health_transaction() {",
            "  return 42;",
            "}",
          })
          vim.api.nvim_buf_call(buffer, function()
            vim.cmd("silent write")
          end)
          local written = table.concat(vim.fn.readfile(path), "\n")
          vim.api.nvim_buf_delete(buffer, { force = true })
          if not written:find("return 42", 1, true) then
            return { status = "FAIL", summary = "temporary edit content was damaged" }
          end
          return { status = "PASS", summary = "temporary edit transaction passed" }
        end,
      },
    }, { filter = "editor", include_cleanup = true })

    t.assert_eq(status_by_id(report, "editor.transaction"), "PASS")
    t.assert_eq(status_by_id(report, "cleanup.temp"), "PASS")
    t.assert_true(observed_root ~= nil)
    t.assert_nil(vim.uv.fs_stat(observed_root), "runner temp root must not survive cleanup")
  end)

  t.it("refuses to reuse or delete a caller-owned existing directory", function()
    local root = vim.fn.tempname() .. "-core-health-owned"
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "keep" }, root .. "/marker.txt")
    local ran = false
    local report = health.run_checks({
      {
        id = "editor.transaction",
        stage = "editor",
        run = function()
          ran = true
          return { status = "PASS", summary = "must not run" }
        end,
      },
    }, { temp_root = root, include_cleanup = true })

    t.assert_false(ran)
    t.assert_eq(status_by_id(report, "editor.transaction"), "FAIL")
    t.assert_eq(status_by_id(report, "cleanup.temp"), "PASS")
    t.assert_true(vim.uv.fs_stat(root .. "/marker.txt") ~= nil)
    vim.fn.delete(root, "rf")
  end)
end)

t.describe("core_health: fixture and mutation safety", function()
  t.it("ships valid non-empty parser and search fixtures", function()
    for _, relative in ipairs({
      "sample.c",
      "sample.cpp",
      "sample.hlsl",
      "invalid.cpp",
      "search/Alpha.cpp",
      "search/Beta.h",
    }) do
      local path = config_root .. "/tests/fixtures/core_health/" .. relative
      local stat = vim.uv.fs_stat(path)
      t.assert_true(stat ~= nil and stat.type == "file" and stat.size > 0, relative)
    end
  end)

  t.it("does not contain direct install, update, build, deploy, launch, or DAP execution", function()
    local forbidden_calls = {
      "vim%.cmd%s*%(%s*['\"]TSInstall",
      "vim%.cmd%s*%(%s*['\"]TSUpdate",
      "vim%.cmd%s*%(%s*['\"]Lazy%s+sync",
      "vim%.cmd%s*%(%s*['\"]MasonInstall",
      "vim%.cmd%s*%(%s*['\"]UEBuild",
      "vim%.cmd%s*%(%s*['\"]UEPrepare",
      "vim%.cmd%s*%(%s*['\"]UEPackage",
      "vim%.cmd%s*%(%s*['\"]UEInstall",
      "vim%.cmd%s*%(%s*['\"]UELaunch",
      "vim%.cmd%s*%(%s*['\"]UEDAP",
      "os%.execute%s*%(",
    }
    for _, relative in ipairs({
      "lua/utils/core_health.lua",
      "lua/utils/core_health_checks.lua",
      "lua/utils/core_health_live.lua",
      "scripts/nvim_core_health.lua",
    }) do
      local file = assert(io.open(config_root .. "/" .. relative, "rb"))
      local source = file:read("*a")
      file:close()
      for _, pattern in ipairs(forbidden_calls) do
        t.assert_false(source:find(pattern) ~= nil, relative .. " contains forbidden mutation pattern: " .. pattern)
      end
    end
  end)

  t.it("health startup mode skips shada cleanup and Lazy background mutation", function()
    local function source(relative)
      local file = assert(io.open(config_root .. "/" .. relative, "rb"))
      local value = file:read("*a")
      file:close()
      return value
    end

    local init_source = source("init.lua")
    local lazy_source = source("lua/config/lazy.lua")
    t.assert_contains(init_source, 'vim.env.NVIM_CORE_HEALTH_NO_MUTATE ~= "1"')
    t.assert_match(init_source, 'NVIM_CORE_HEALTH_NO_MUTATE ~= "1"%s+then%s+cleanup_stale_shada_tmp%(%)')
    t.assert_contains(lazy_source, 'local health_no_mutate = vim.env.NVIM_CORE_HEALTH_NO_MUTATE == "1"')
    t.assert_contains(lazy_source, "missing = not health_no_mutate")

    -- The invariant is "neither background mutator runs under the health probe",
    -- NOT "both are spelled `not health_no_mutate`". Assert each one separately
    -- and accept an unconditional `false` as strictly stronger than gating on
    -- the env var: an always-off mutator cannot mutate in ANY mode.
    --
    -- change_detection became unconditionally false on 2026-08-25 because its
    -- 2000ms/2000ms reloader stats 33 spec files SYNCHRONOUSLY on the main loop
    -- (1.2ms p50 idle, 21ms p50 when it fires) — a standing P6 violation, not
    -- just a health-probe concern. See lua/config/ui_responsiveness.lua.
    local function block(name)
      local body = lazy_source:match(name .. "%s*=%s*{(.-)}")
      t.assert_type(body, "string", name .. " block not found in config/lazy.lua")
      return body
    end
    local function disabled_under_health(name)
      local body = block(name)
      local gated = body:find("enabled = not health_no_mutate", 1, true) ~= nil
      local always_off = body:match("enabled%s*=%s*false") ~= nil
      t.assert_true(gated or always_off,
        name .. " must be disabled under NVIM_CORE_HEALTH_NO_MUTATE (gated) or unconditionally")
      return always_off
    end

    disabled_under_health("checker")
    local cd_always_off = disabled_under_health("change_detection")
    t.assert_true(cd_always_off,
      "change_detection must stay unconditionally false: its 2s main-loop fs_stat poll violates P6")

    t.assert_match(lazy_source, "rocks%s*=%s*{%s*enabled%s*=%s*false", "unused LuaRocks provider must stay disabled")
  end)
end)

t.describe("core_health: real deterministic audit", function()
  local function status_shape(report)
    local shape = {}
    for _, item in ipairs(report.checks or {}) do
      shape[#shape + 1] = item.id .. "=" .. item.status
    end
    return table.concat(shape, ",")
  end

  t.it("startup probe invokes the actual init with -u rather than a -l shortcut", function()
    local checks = require("utils.core_health_checks")
    t.assert_eq(table.concat(checks._startup_argv_contract, " "), "--headless -i NONE -u init.lua")

    local path = config_root .. "/lua/utils/core_health_checks.lua"
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    t.assert_match(source, 'process%(%{%s*nvim,%s*"%-%-headless",%s*"%-i",%s*"NONE",%s*"%-u",%s*init,')
  end)

  t.it("derives mandatory parsers and classifies invalid/missing parser evidence as FAIL", function()
    local checks = require("utils.core_health_checks")
    local parsers = assert(checks._mandatory_parsers_for_test(config_root))
    t.assert_eq(table.concat(parsers, ","), "c,cpp,hlsl")

    local invalid = checks._syntax_check_for_test("cpp", "invalid.cpp")({ config_root = config_root })
    local missing = checks._syntax_check_for_test("core_health_missing_parser", "sample.cpp")({
      config_root = config_root,
    })
    t.assert_eq(invalid.status, "FAIL")
    t.assert_eq(missing.status, "FAIL")
    t.assert_contains(missing.next_step, "Install")
  end)

  t.it("validates live tuple/provenance/freshness without repairing artifacts", function()
    local root = vim.fn.tempname() .. "-core-health-live"
    vim.fn.mkdir(root, "p")
    local cdb = root .. "/compile_commands.json"
    local index = root .. "/semantic.idx"
    local provenance = root .. "/provenance.json"
    local spec = root .. "/live-spec.json"
    local tuple = { target = "FixtureGame", platform = "IOS", configuration = "Development" }
    vim.fn.writefile(
      { vim.json.encode({ { directory = root, file = root .. "/Fixture.cpp", arguments = { "clang++" } } }) },
      cdb
    )
    vim.fn.writefile({ "fixture-index" }, index)
    vim.fn.writefile({ vim.json.encode({ tuple = tuple }) }, provenance)
    vim.fn.writefile({ vim.json.encode({ tuple = tuple, cdb = cdb, index = index, provenance = provenance }) }, spec)
    local original = vim.env.NVIM_CORE_HEALTH_LIVE_SPEC

    local ok, error_message = xpcall(function()
      vim.env.NVIM_CORE_HEALTH_LIVE_SPEC = spec
      local now = os.time()
      vim.uv.fs_utime(cdb, now - 10, now - 10)
      vim.uv.fs_utime(index, now, now)
      local fresh = health.run({ config_root = config_root, live = true, filter = "live.workspace" })
      t.assert_eq(status_by_id(fresh, "live.workspace"), "PASS")

      vim.uv.fs_utime(cdb, now, now)
      vim.uv.fs_utime(index, now - 20, now - 20)
      local stale = health.run({ config_root = config_root, live = true, filter = "live.workspace" })
      t.assert_eq(status_by_id(stale, "live.workspace"), "BLOCKED")
      t.assert_contains(stale.checks[1].summary, "older")
    end, debug.traceback)

    vim.env.NVIM_CORE_HEALTH_LIVE_SPEC = original
    vim.fn.delete(root, "rf")
    t.assert_true(ok, error_message)
  end)

  t.it("two complete runs keep stable ids/statuses and remove both temp roots", function()
    local first_root = vim.fn.tempname() .. "-core-health-first"
    local second_root = vim.fn.tempname() .. "-core-health-second"
    local first = health.run({ config_root = config_root, temp_root = first_root })
    local second = health.run({ config_root = config_root, temp_root = second_root })

    t.assert_eq(first.schema_version, 1)
    t.assert_eq(first.mode, "deterministic")
    t.assert_eq(second.overall, first.overall)
    t.assert_true(
      first.overall == "PASS" or first.overall == "DEGRADED",
      "external tools may pass or block, but deterministic essentials must not fail"
    )
    t.assert_eq(status_shape(second), status_shape(first))
    t.assert_eq(status_by_id(first, "startup.config"), "PASS")
    t.assert_eq(status_by_id(first, "editor.transaction"), "PASS")
    t.assert_eq(status_by_id(first, "syntax.c.parse"), "PASS")
    t.assert_eq(status_by_id(first, "syntax.cpp.parse"), "PASS")
    t.assert_eq(status_by_id(first, "syntax.hlsl.parse"), "PASS")
    t.assert_eq(status_by_id(first, "search.rg"), "PASS")
    t.assert_eq(status_by_id(first, "compiler.cdb.fixture"), "PASS")
    t.assert_eq(status_by_id(first, "ue.target_plans"), "PASS")
    t.assert_eq(status_by_id(first, "live.workspace"), "SKIP")
    t.assert_eq(status_by_id(first, "live.semantic"), "SKIP")
    t.assert_eq(status_by_id(first, "cleanup.temp"), "PASS")
    t.assert_nil(vim.uv.fs_stat(first_root), "first deterministic temp root leaked")
    t.assert_nil(vim.uv.fs_stat(second_root), "second deterministic temp root leaked")
  end)
end)

t.describe("core_health: CLI", function()
  local function run_cli(arguments)
    local argv = {
      vim.v.progpath,
      "--headless",
      "-i",
      "NONE",
      "-l",
      config_root .. "/scripts/nvim_core_health.lua",
    }
    vim.list_extend(argv, arguments)
    return vim
      .system(argv, {
        text = true,
        env = vim.tbl_extend("force", vim.fn.environ(), {
          NVIM_CORE_HEALTH_NO_MUTATE = "1",
        }),
      })
      :wait(40000)
  end

  t.it("parses --json --live --filter and emits only the selected capability", function()
    local completed = run_cli({ "--json", "--live", "--filter", "startup" })
    t.assert_eq(completed.code, 0, completed.stderr)
    local ok, report = pcall(vim.json.decode, completed.stdout or "")
    t.assert_true(ok, "CLI stdout must be one JSON report: " .. tostring(completed.stdout))
    t.assert_eq(report.mode, "live")
    t.assert_eq(ids(report.checks), "cleanup.temp,startup.config")
    t.assert_eq(status_by_id(report, "startup.config"), "PASS")
    t.assert_eq(status_by_id(report, "cleanup.temp"), "PASS")
  end)

  t.it("rejects an unknown flag with the CLI parse error exit code", function()
    local completed = run_cli({ "--not-a-health-option" })
    t.assert_eq(completed.code, 2)
    t.assert_contains(completed.stderr or "", "unknown argument")
  end)
end)
