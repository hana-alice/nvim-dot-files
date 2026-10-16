-- Presentation data only: no compiler requests, editor mutation, or lineage writes.
local M = {}
M.OBSERVATIONS = {
  ["cpp-semantic-navigation"] = "navigation-failure-reporting-2026-10-14-x3",
  ["cpp-semantic-performance"] = "header-warm-alias-2026-10-08-F",
}
local location_mod = require("utils.ue_goto.location")
local transaction = require("utils.ue_goto.semantic_transaction")

local function safe_text(value)
  local text = tostring(value or "-"):sub(1, 4096):gsub("\\", "/")
  text = text:gsub("file://.-(:%d+:%d+:)", "<path>%1")
    :gsub("[%a]:/.-(:%d+:%d+:)", "<path>%1")
    :gsub("^/.-(:%d+:%d+:)", "<path>%1")
    :gsub("([%s%(=:\"'])(/.-)(:%d+:%d+:)", "%1<path>%3")
    :gsub("file://[^%c\"']+", "<path>")
    :gsub("[%a]:/[^%c\"']+", "<path>")
    :gsub("^/[^%c\"']+", "<path>")
    :gsub("([%s%(=:\"'])(/[^%c\"']+)", "%1<path>")
    :gsub("[%w_]*[Tt][Oo][Kk][Ee][Nn]%s*[:=]%s*[^%s,;]+", "token=<redacted>")
    :gsub("[%w_]*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*[^%s,;]+", "password=<redacted>")
    :gsub("[Bb]earer%s+[^%s,;]+", "Bearer <redacted>")
    :gsub("%c", " ")
  return vim.fn.strcharpart(text, 0, 240)
end

function M.safe_text(value) return safe_text(value) end

local preparation_labels = {
  ["base-compile-database-missing"] = "基础编译数据库不可读",
  ["compile-command-ambiguous"] = "当前文件的编译命令不唯一",
  ["frozen-cdb-unverified"] = "冻结编译数据库未获授权",
  ["compile-command-tool-missing"] = "编译命令查询工具不可用",
  ["compile-command-missing"] = "当前构建没有该文件的编译命令",
  ["header-command-compiler-session-stale"] = "头文件编译命令的编译器会话已过期",
}

function M.provider_lines(provider, label)
  local lines = {}
  provider = provider or {}
  for _, client in ipairs(provider.client_results or {}) do
    local err = client.error
    lines[#lines + 1] = string.format("%s client: id=%s method=%s status=%s error_code=%s error_message=%s",
      label or "provider", safe_text(client.client_id), safe_text(client.method or provider.method), safe_text(client.status),
      safe_text(type(err) == "table" and err.code or nil), safe_text(type(err) == "table" and err.message or err))
    if client.status == "preparation-error" then
      lines[#lines + 1] = (label or "provider") .. " preparation reason: " .. safe_text(client.preparation_reason or err or provider.reason)
    end
  end
  if provider.preparation_reason then
    lines[#lines + 1] = (label or "provider") .. " preparation reason: " .. safe_text(provider.preparation_reason)
  end
  return lines
end

function M.terminal_notice(sym, result, tx)
  if not result or result.stage == "stale" then return end
  local status = result.state or "unavailable"
  local reason = result.reason or "unknown"
  local label = ({
    ["active-compile-command-missing"] = "当前构建没有该文件的编译命令；核对目标与模块参与",
    ["already-at-definition"] = "已经在定义位置，无需跳转",
    ["context-not-member"] = "无法证明该文件属于当前编译上下文",
    ["context-resolution-failed"] = "编译上下文求值失败；查看逐 TU 诊断",
    ["declaration-resolved"] = "已定位声明（实体类型允许）",
    ["definition-not-found"] = "没有获得同一实体的唯一已证明定义",
    ["definition-resolved"] = "已定位定义",
    ["macro-no-source-definition"] = "该宏没有可打开的源码定义",
    ["definition-absent-in-complete-index"] = "当前已验证覆盖中未找到该实体定义",
    ["identity-conflict"] = "编译器返回多个未消歧实体；核验上下文与展开",
    ["identity-missing"] = "编译器在当前构建（平台/配置）未提供该位置实体；可能是未启用分支、宏消去或未实例化的依赖名",
    ["index-incomplete"] = "当前部分覆盖尚未找到定义；查看覆盖阶段",
    ["index-provider-not-ready"] = "当前构建语义覆盖尚未就绪",
    ["index-stale-for-module"] = "该模块语义覆盖已过期；查看变更与交付状态",
    ["jump-failed"] = "语义目标已求得，但打开或交接失败",
    ["multiple-definitions"] = "该实体有多个候选定义，尚不能证明唯一目标",
    ["provider-error"] = "语义服务请求失败",
    ["provider-method-unsupported"] = "当前服务不支持所需方法",
    ["provider-timeout"] = "服务超过本次请求期限",
    ["provider-unavailable"] = "当前 buffer 没有可用 clangd；查看启动或过滤原因",
    ["query-file-not-in-tu"] = "该文件未被所选编译 TU 证明包含",
    ["semantic-cursor-invalid"] = "编译器无法在该精确位置提供可导航实体",
    ["semantic-sidecar-unavailable"] = "语义解析服务不可用",
    ["semantic-tu-unavailable"] = "当前编译 TU 不可提供可靠语义",
    ["target-is-current-declaration"] = "当前仅有声明，尚未证明可导航的实现",
    ["stale-request"] = "旧请求已取消，不覆盖新动作",
    ["unknown"] = "未能分类该次失败；查看阶段与原始错误",
  })[reason] or "未能分类该次失败"
  local provider = result.provider_result or {}
  local evidence = result.compiler_evidence or provider.compiler_evidence or (result.identity_result or {}).compiler_evidence
  if reason == "identity-missing" and type(evidence) == "table" then
    label = ({
      ["inactive-branch"] = "编译器证据表明此位置属于当前构建未启用的分支；请在启用该分支的构建中阅读",
      ["dependent-name"] = "编译器 AST 表明此位置是尚未实例化的依赖名；请在具体实例化处阅读",
      ["macro-argument-elided"] = "编译器证据表明该宏参数已被当前构建的展开消去；此位置没有可导航实体",
    })[evidence.kind] or label
  end
  local preparation = result.preparation_reason or provider.preparation_reason
  if preparation then label = "编译命令准备失败：" .. (preparation_labels[preparation] or safe_text(preparation)) end
  local detail = result.detail
  if not detail then
    for _, client in ipairs(provider.client_results or {}) do
      if client.error and client.status ~= "preparation-error" then
        detail = type(client.error) == "table" and client.error.message or client.error
        break
      end
    end
  end
  if detail then label = label .. "：" .. safe_text(detail) end
  if reason == "provider-method-unsupported" then label = label .. " " .. safe_text(provider.method) end
  if reason == "provider-timeout" then label = label .. string.format("（阶段 %s，已耗时 %s ms）", safe_text(result.stage), safe_text(result.elapsed_ms)) end
  local remedy = ({
    ["index-provider-not-ready"] =
      "查看当前交付门禁；若 :UEPrepare 刚完成，关注正在运行的覆盖构建；准备失败时查看 :NvimLog",
    ["index-stale-for-module"] =
      "核对已确认的失效输入与交付状态，再对该构建运行 :UEPrepare",
    ["index-incomplete"] =
      "等待正在运行的覆盖构建完成；此结果不能证明整个工作区没有定义",
    ["active-compile-command-missing"] =
      "核对所选平台、目标及模块参与，再对该构建运行 :UEPrepare",
    ["provider-unavailable"] =
      "查看 :LspInfo 的客户端启动状态及 :UEDefExplain 的提供者证据",
  })[reason]
  if reason == "identity-missing" then
    local build = tx and tx.build or result.build or {}
    remedy = string.format("当前构建：platform=%s target=%s config=%s；详见 :UEDefExplain",
      safe_text(build.platform), safe_text(build.target), safe_text(build.configuration))
  elseif not remedy and status ~= "resolved" then remedy = "详见 :UEDefExplain" end

  return string.format("C++ definition %s%s%s%s",
    tostring(status),
    sym and sym ~= "" and (" for `" .. safe_text(sym) .. "`") or "",
    label ~= "" and (": " .. tostring(label)) or "",
    remedy and ("\n" .. remedy) or ""),
    status == "unavailable" and vim.log.levels.WARN or vim.log.levels.INFO,
    { title = "C++ definition", timeout = 5000 }
end

function M.probes(result, tx)
  local events = {}
  if not result then return events end
  local function record(topic, key, data)
    events[#events + 1] = { topic = topic, key = key, data = data, revision = M.OBSERVATIONS[topic] }
  end
  local index = tx and tx.index or {}
  local generation_class = index.readiness ~= "ready" and tostring(index.readiness or "missing")
    or (index.complete and "complete" or "partial")
  if result.state ~= "resolved" then
    record("cpp-semantic-navigation",
      string.format("%s|%s|%s|%s",
        tostring(result.state or "?"),
        tostring(result.stage or "?"),
        tostring(result.reason or "?"), generation_class), {
      state = result.state,
      stage = result.stage,
      reason = result.reason,
      provider = result.provider,
      generation_class = generation_class,
    })
  end
  local metrics = result.metrics or {}
  local query_kind = metrics.query_kinds and metrics.query_kinds[1]
    and metrics.query_kinds[1].kind or "provider"
  record("cpp-semantic-performance",
    string.format("%s|%s", query_kind, generation_class), {
      elapsed_ms = tonumber(result.elapsed_ms) or 0,
      state = result.state,
      stage = result.stage,
      provider = result.provider,
      index_wait_ms = tonumber(result.index_wait_ms) or 0,
      tu_count = tonumber(metrics.tu_count),
      process_rss_bytes = tonumber(metrics.process_rss_bytes),
      generation_class = generation_class,
    })
  return events
end

local function short_hash(value)
  value = tostring(value or "")
  return value ~= "" and vim.fn.sha256(value):sub(1, 12) or "-"
end

local function display_path(tx, path)
  path = location_mod.normalize_path(path or "")
  for _, item in ipairs({
    { label = "project", root = (tx.build or {}).project_root },
    { label = "engine", root = (tx.build or {}).engine_root },
  }) do
    local root = location_mod.normalize_path(item.root or ""):gsub("/$", "")
    if root ~= "" and (path:lower() == root:lower()
        or path:lower():sub(1, #root + 1) == root:lower() .. "/") then
      local relative = path:sub(#root + 1):gsub("^/", "")
      return item.label .. "/" .. relative
    end
  end
  return vim.fn.fnamemodify(path, ":t")
end

function M.explain_lines(tx)
  if not tx then return { "(no C++ semantic transaction yet)" } end
  local result = transaction.last_result(tx) or {}
  local index = tx.index or {}
  local provider_result = result.provider_result or {}
  local lines = {
    "=== UEDefExplain ===",
    string.format("symbol: %s", tostring(tx.symbol or "?")),
    string.format("subject: %s:%d:%d", display_path(tx, tx.subject.path),
      tonumber(tx.subject.line or 0), tonumber(tx.subject.column0 or 0)),
    string.format("document_version: %s", tostring(tx.subject.document_version or "?")),
    string.format("build: %s", short_hash((tx.build or {}).build_fingerprint)),
    string.format("build selection: platform=%s target=%s config=%s", safe_text((tx.build or {}).platform),
      safe_text((tx.build or {}).target), safe_text((tx.build or {}).configuration)),
    string.format("generation: %s", tostring(index.generation_short or "-")),
    string.format("index: coverage=%s readiness=%s freshness=%s base=%s modules=%s",
      tostring(index.coverage_level or "-"), tostring(index.readiness or "-"),
      tostring(index.freshness or "-"), tostring(index.phase or "-"),
      tostring(index.module_count or 0)),
    string.format("state: %s", tostring(result.state or "?")),
    string.format("stage: %s", tostring(result.stage or "?")),
    string.format("reason: %s", tostring(result.reason or "?")),
    string.format("destination_role: %s", tostring(result.destination_role or "?")),
    string.format("provider: %s", tostring(result.provider or "?")),
    string.format("provider_method: %s", safe_text(provider_result.method)),
    string.format("provider_reason: %s", safe_text(provider_result.reason)),
    string.format("identity_hash: %s", short_hash(result.identity)),
    string.format("provider_clients: %d", #(provider_result.client_results or {})),
    string.format("provider_locations: %d", #(provider_result.locations or {})),
    string.format("elapsed_ms: %s", tostring(result.elapsed_ms or "?")),
  }
  vim.list_extend(lines, M.provider_lines(provider_result))
  if result.identity_result ~= provider_result then vim.list_extend(lines, M.provider_lines(result.identity_result, "identity")) end
  local identity = result.identity_result or provider_result
  vim.list_extend(lines, M.provider_lines(identity.referent_ast, "referent AST"))
  if result.preparation_reason then lines[#lines + 1] = "preparation reason: " .. safe_text(result.preparation_reason) end
  if identity.compiler_evidence then lines[#lines + 1] = "compiler evidence: " .. safe_text(identity.compiler_evidence.kind) end
  if result.detail then lines[#lines + 1] = "detail: " .. safe_text(result.detail) end
  local diagnostics = result.diagnostics or {}
  for i = 1, math.min(#diagnostics, 8) do
    local diag = diagnostics[i]
    lines[#lines + 1] = "diagnostic: " .. safe_text(type(diag) == "table"
      and (diag.message or diag.spelling or diag.reason) or diag)
  end
  if #diagnostics > 8 then lines[#lines + 1] = "diagnostics omitted: " .. (#diagnostics - 8) end
  local contexts = result.context_evidence or result.contexts or {}
  for i = 1, math.min(#contexts, 8) do
    local ctx = contexts[i]
    lines[#lines + 1] = string.format("context: %s tu=%s state=%s reason=%s definitions=%s",
      short_hash(ctx.context_id or ctx.id), display_path(tx, ctx.origin_tu),
      safe_text(ctx.state), safe_text(ctx.reason), tostring(tonumber(ctx.definition_count) or "-"))
    if ctx.diagnostics and ctx.diagnostics[1] then
      lines[#lines + 1] = "context diagnostic: " .. safe_text(ctx.diagnostics[1])
    end
  end
  if #contexts > 8 then lines[#lines + 1] = "contexts omitted: " .. (#contexts - 8) end
  local metrics = result.metrics or {}
  local values = {}
  for _, key in ipairs({ "cold_parse_ms", "reparse_ms", "tu_count", "process_rss_bytes", "max_tus",
    "lookup_cache_entries", "shim_abi_version" }) do
    if tonumber(metrics[key]) then values[#values + 1] = key .. "=" .. tonumber(metrics[key]) end
  end
  if #values > 0 then lines[#lines + 1] = "metrics: " .. table.concat(values, " ") end
  for i = 1, math.min(#(metrics.query_kinds or {}), 4) do
    local query = metrics.query_kinds[i]
    lines[#lines + 1] = "query: " .. short_hash(query.context_id) .. " kind=" .. safe_text(query.kind)
  end
  local identity_result = result.identity_result or {}
  if identity_result.elapsed_ms or provider_result.elapsed_ms then
    lines[#lines + 1] = string.format("provider timing: identity_ms=%s destination_ms=%s",
      tostring(tonumber(identity_result.elapsed_ms) or "-"), tostring(tonumber(provider_result.elapsed_ms) or "-"))
  end
  if identity_result.declarations or identity_result.definitions then
    lines[#lines + 1] = string.format("compiler roles: declarations=%d definitions=%d",
      #(identity_result.declarations or {}), #(identity_result.definitions or {}))
  end
  if identity_result.entity_kind then
    lines[#lines + 1] = "compiler referent: " .. safe_text(identity_result.entity_kind)
  end
  local target_identity = result.target_identity_result
  if target_identity then
    vim.list_extend(lines, M.provider_lines(target_identity, "destination"))
    vim.list_extend(lines, M.provider_lines(target_identity.referent_ast, "destination AST"))
    lines[#lines + 1] = string.format("destination proof: reason=%s identity_hash=%s definitions=%d",
      safe_text(target_identity.reason), short_hash(target_identity.usr), #(target_identity.definitions or {}))
  end
  return lines
end


return M
