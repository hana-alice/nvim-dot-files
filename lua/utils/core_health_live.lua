-- Explicit, read-only live workspace probes for utils.core_health_checks.

local M = {}

function M.definitions(deps)
  local result = assert(deps.result)
  local uv = assert(deps.uv)
  local read_file = assert(deps.read_file)
  local process = assert(deps.process)
  local wait_for = assert(deps.wait_for)
  local executable = assert(deps.executable)
  local join = assert(deps.join)

  local function live_spec()
    local raw = vim.env.NVIM_CORE_HEALTH_LIVE_SPEC
    if not raw or raw == "" then
      return nil, "NVIM_CORE_HEALTH_LIVE_SPEC is not set"
    end
    local file = read_file(raw)
    if file then
      raw = file
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
      return nil, "NVIM_CORE_HEALTH_LIVE_SPEC is not valid JSON or a readable JSON file"
    end
    return decoded
  end

  local function workspace(ctx)
    if not ctx.opts.live then
      return result(
        "SKIP",
        "live workspace audit was not requested",
        nil,
        "Pass --live with NVIM_CORE_HEALTH_LIVE_SPEC to inspect existing artifacts read-only."
      )
    end
    local spec, spec_error = live_spec()
    if not spec then
      return result(
        "SKIP",
        spec_error,
        nil,
        "Set NVIM_CORE_HEALTH_LIVE_SPEC to JSON describing existing cdb/index/provenance paths."
      )
    end
    local evidence, stats, missing = {}, {}, {}
    for _, key in ipairs({ "cdb", "index", "provenance" }) do
      local path = spec[key]
      local stat = type(path) == "string" and uv.fs_stat(path) or nil
      stats[key] = stat
      evidence[key] = stat and { exists = true, size = stat.size, mtime = stat.mtime and stat.mtime.sec }
        or { exists = false }
      if not stat then
        missing[#missing + 1] = key
      end
    end
    if #missing > 0 then
      return result("BLOCKED", "live workspace artifacts are incomplete", {
        artifacts = evidence,
        missing = missing,
      }, "Generate or select the missing artifacts outside the audit, then rerun --live.")
    end

    local cdb_content = read_file(spec.cdb)
    local cdb_ok, cdb = pcall(vim.json.decode, cdb_content or "")
    if not cdb_ok or type(cdb) ~= "table" or #cdb == 0 then
      return result("BLOCKED", "live compilation database is not a non-empty JSON array", {
        artifacts = evidence,
      }, "Regenerate the active compile_commands.json outside the audit.")
    end

    local provenance_content = read_file(spec.provenance)
    local provenance_ok, provenance = pcall(vim.json.decode, provenance_content or "")
    local expected_tuple = type(spec.tuple) == "table" and spec.tuple or nil
    local actual_tuple = provenance_ok
        and type(provenance) == "table"
        and (provenance.tuple or provenance.active_tuple or provenance.context or provenance)
      or nil
    local tuple_match = expected_tuple ~= nil and type(actual_tuple) == "table"
    for _, key in ipairs({ "target", "platform", "configuration" }) do
      local expected = expected_tuple and expected_tuple[key]
      if
        type(expected) ~= "string"
        or expected == ""
        or tostring(actual_tuple and actual_tuple[key] or "") ~= expected
      then
        tuple_match = false
      end
    end
    if not provenance_ok or not tuple_match then
      return result("BLOCKED", "live provenance does not match the explicitly supplied active tuple", {
        artifacts = evidence,
        tuple_match = false,
      }, "Select matching active tuple/CDB/index provenance outside the audit and rerun --live.")
    end

    local cdb_mtime = stats.cdb.mtime and stats.cdb.mtime.sec or 0
    local index_mtime = stats.index.mtime and stats.index.mtime.sec or 0
    if cdb_mtime > 0 and index_mtime < cdb_mtime then
      return result("BLOCKED", "live semantic index is older than the active compilation database", {
        artifacts = evidence,
        tuple_match = true,
        index_fresh = false,
      }, "Refresh the semantic index outside the audit and rerun --live.")
    end
    return result("PASS", "live tuple, CDB, index and provenance passed read-only validation", {
      artifacts = evidence,
      cdb_entries = #cdb,
      tuple_match = true,
      index_fresh = true,
    })
  end

  local function search(ctx)
    if not ctx.opts.live then
      return result("SKIP", "live indexed search was not requested")
    end
    local spec, spec_error = live_spec()
    if not spec then
      return result("SKIP", spec_error)
    end
    if
      type(spec.csearch_index) ~= "string"
      or type(spec.workspace_root) ~= "string"
      or type(spec.query) ~= "string"
      or spec.query == ""
    then
      return result(
        "SKIP",
        "live csearch index/root/query were not supplied",
        nil,
        "Add csearch_index, workspace_root and a harmless query to NVIM_CORE_HEALTH_LIVE_SPEC."
      )
    end
    local index_stat = uv.fs_stat(spec.csearch_index)
    if not index_stat or not index_stat.size or index_stat.size <= 1024 then
      return result(
        "BLOCKED",
        "supplied live csearch index is missing or unusable",
        nil,
        "Build or select a usable index outside the audit and rerun --live."
      )
    end
    local home = vim.env.HOME or ""
    local csearch = executable({
      vim.fn.exepath("csearch"),
      home ~= "" and join(home, "go", "bin", "csearch") or nil,
    })
    if not csearch then
      return result(
        "BLOCKED",
        "csearch is unavailable for the read-only live query",
        nil,
        "Install csearch outside the audit or omit the live indexed-search context."
      )
    end
    local code_search = require("utils.code_search")
    local context = { workspace_root = spec.workspace_root, csearch_idx = spec.csearch_index }
    if code_search.current_backend(context) ~= "csearch" then
      return result("BLOCKED", "public search dispatcher rejected the supplied live csearch index")
    end
    local matches, done, exit_code, error_message = {}, false, nil, nil
    local stop = code_search.stream(context, spec.query, {
      regex = false,
      case = true,
      code_only = true,
      max_count = tonumber(spec.max_count) or 20,
    }, {
      on_line = function()
        matches[#matches + 1] = true
      end,
      on_done = function(code, err)
        exit_code, error_message, done = code, err, true
      end,
    })
    if not wait_for(function()
      return done
    end, 5000, stop) then
      return result("FAIL", "read-only live csearch query exceeded its 5000ms deadline")
    end
    local minimum = math.max(1, tonumber(spec.expected_hits) or 1)
    if exit_code ~= 0 or #matches < minimum then
      return result("BLOCKED", "live csearch query did not return the expected evidence", {
        backend = "csearch",
        exit_code = exit_code,
        hit_count = #matches,
        expected_minimum = minimum,
        error = error_message,
      }, "Verify the supplied harmless query and existing csearch index outside the audit.")
    end
    return result("PASS", "existing csearch index answered the supplied read-only query", {
      backend = "csearch",
      hit_count = #matches,
    })
  end

  local function semantic(ctx)
    if not ctx.opts.live then
      return result("SKIP", "live semantic smoke was not requested")
    end
    if not vim.env.UE_CPP_SEMANTIC_SMOKE_SPEC or vim.env.UE_CPP_SEMANTIC_SMOKE_SPEC == "" then
      return result(
        "SKIP",
        "UE_CPP_SEMANTIC_SMOKE_SPEC is not set",
        nil,
        "Set the existing semantic smoke spec and rerun with --live."
      )
    end
    local nvim = vim.v.progpath ~= "" and vim.v.progpath or vim.fn.exepath("nvim")
    local completed = process({
      nvim,
      "--headless",
      "-i",
      "NONE",
      "-l",
      join(ctx.config_root, "scripts", "ue_cpp_semantic_smoke.lua"),
    }, { timeout_ms = 30000, env = vim.fn.environ() })
    local output = tostring(completed.stdout or "") .. tostring(completed.stderr or "")
    if completed.code ~= 0 or not output:find("PASS", 1, true) then
      return result(
        "FAIL",
        "live C++ semantic smoke did not pass",
        { exit_code = completed.code },
        "Run the semantic smoke runner directly and inspect its redacted report."
      )
    end
    return result("PASS", "live C++ semantic smoke passed", { exit_code = completed.code })
  end

  return {
    { id = "live.workspace", stage = "live", timeout_ms = 3000, run = workspace },
    { id = "live.search", stage = "live", timeout_ms = 6000, run = search },
    { id = "live.semantic", stage = "live", timeout_ms = 32000, run = semantic },
  }
end

return M
