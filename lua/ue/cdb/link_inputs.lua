-- Read-only selection from an existing UBT receipt and its direct link inputs.
local fs = require("ue.core.fs")
local origin = require("ue.cdb.unity_origin")
local shards = require("ue.cdb.shards")
local M = {}

local function absolute(path, cwd)
  if type(path) ~= "string" or path == "" then return nil end
  return vim.fs.normalize(fs.is_absolute_path(path) and path or fs.join(cwd, path))
end

local function key(path)
  path = vim.fs.normalize(path)
  return package.config:sub(1, 1) == "\\" and path:lower() or path
end

local function target_arg(args)
  local target
  for i, value in ipairs(args) do
    local next_target = value:match("^%-%-target=(.+)$")
      or ((value == "-target" or value == "--target") and args[i + 1])
    if next_target then
      if target and target ~= next_target then return nil end
      target = next_target
    end
  end
  return target
end

local function disabled(plan, reason)
  plan.enabled, plan.reason = false, reason
  return plan
end

function M.plan(ctx, rsp_paths, callbacks)
  local plan = { enabled = false, excluded = {}, gaps = {}, retained_reasons = {},
    objects = {}, families = {}, dependencies = {} }
  local state = ctx.state or {}
  local platform = state.target_platform
  local config = (state.target_configuration or ""):gsub(" Editor$", ""):gsub(" Client$", ""):gsub(" Server$", "")
  if not platform or config == "" or not ctx.uproject then return disabled(plan, "tuple-unavailable") end
  local project = vim.fs.dirname(vim.fs.normalize(ctx.uproject))
  local explicit = state.target or state.target_name
  local scopes, paths = {}, {}
  for _, path in ipairs(rsp_paths) do
    paths[key(path)] = path
    local p, target, c = shards.classify_rsp_path(path)
    if p == platform and c == config and (not explicit or explicit == "" or target == explicit)
        and fs.path_has_prefix(key(path), key(project .. "/Intermediate/Build")) then
      local dir = vim.fs.dirname(vim.fs.normalize(path))
      while dir and fs.path_has_prefix(key(dir), key(project)) do
        if vim.fs.basename(dir) == config and vim.fs.basename(vim.fs.dirname(dir)) == target then
          scopes[dir] = target
          break
        end
        dir = vim.fs.dirname(dir)
      end
    end
  end
  local roots = vim.tbl_keys(scopes)
  if #roots ~= 1 then return disabled(plan, "link-scope-ambiguous") end
  local root, target = roots[1], scopes[roots[1]]
  local binaries = fs.join(project, "Binaries", platform)
  local receipts = {}
  for _, name in ipairs({ target .. "-" .. platform .. "-" .. config, target }) do
    local path = fs.join(binaries, name .. ".target")
    local text = callbacks.read(path)
    if text then
      local ok, doc = pcall(vim.json.decode, text)
      if not ok or type(doc) ~= "table" then return disabled(plan, "receipt-unreadable") end
      if doc.TargetName == target and doc.Platform == platform and doc.Configuration == config then
        if key(absolute(doc.Project, binaries) or "") ~= key(ctx.uproject) then
          return disabled(plan, "receipt-project-mismatch")
        end
        receipts[#receipts + 1] = { path = path, text = text, doc = doc }
      end
    end
  end
  if #receipts ~= 1 then return disabled(plan, "receipt-not-unique") end
  local receipt = receipts[1]
  local products = {}
  for _, product in ipairs(receipt.doc.BuildProducts or {}) do
    if type(product) == "table" and product.Type == "Executable" then
      if type(product.Path) ~= "string" then return disabled(plan, "product-unavailable") end
      products[#products + 1] = product.Path
    end
  end
  if #products ~= 1 or receipt.doc.Launch ~= products[1] then
    return disabled(plan, "product-or-architecture-ambiguous")
  end
  local suffix = products[1]:match("^%$%(ProjectDir%)/(.*)$")
  local product = suffix and absolute(suffix, project)
  if not product or not fs.path_has_prefix(key(product), key(binaries)) or not fs.is_file(product) then
    return disabled(plan, "product-unavailable")
  end
  -- UBT writes this response beside the object directories. Every family below
  -- is additionally checked against the linked object's real compiler -o.
  local response = fs.join(root, vim.fs.basename(product) .. ".response")
  local text = callbacks.read(response)
  if not text then return disabled(plan, "link-response-unavailable") end
  origin.add_dependency(plan.dependencies, receipt.path, receipt.text)
  origin.add_dependency(plan.dependencies, response, text)
  local tokens = callbacks.tokenize(text, root, nil, plan.dependencies)
  if plan.dependencies.invalid then return disabled(plan, "link-response-incomplete") end
  local library_search, named_libraries = false, false
  for i, token in ipairs(tokens) do
    if token:lower():match("%.a$") or token:lower():match("%.lib$") then
      return disabled(plan, "archive-inputs-unresolved")
    end
    local search = token == "-L" and tokens[i + 1] or token:match("^%-L(.+)$")
    if search then
      if not fs.is_absolute_path(search) or fs.path_has_prefix(key(search), key(root)) or not fs.is_dir(search) then
        return disabled(plan, "archive-search-unresolved")
      end
      library_search = true
    end
    if token:match("^%-l") then named_libraries = true end
    if token:sub(1, 1) ~= "-" and (token:match("%.o$") or token:match("%.obj$")) then
      local output = absolute(token, root)
      if fs.path_has_prefix(key(output), key(root)) then plan.objects[key(output)] = output end
    end
  end
  if named_libraries and not library_search then return disabled(plan, "archive-search-unresolved") end
  if not next(plan.objects) then return disabled(plan, "no-direct-objects") end
  local all_targets = {}
  for object_key, output in pairs(plan.objects) do
    local directory = key(vim.fs.dirname(output))
    local family = plan.families[directory] or { dependencies = {} }
    plan.families[directory] = family
    local rsp = paths[key(output .. ".rsp")]
    local content = rsp and callbacks.read(rsp)
    if not content then
      family.reason = "consumed-rsp-unavailable"
      plan.gaps[#plan.gaps + 1] = { object = output, rsp = output .. ".rsp", reason = family.reason }
    else
      origin.add_dependency(family.dependencies, rsp, content)
      local args, source, outputs = callbacks.parse(callbacks.tokenize(content,
        fs.join(ctx.engine_root, "Engine/Source"), nil, family.dependencies))
      local compiler_target = target_arg(args)
      local parsed_output = #outputs == 1 and absolute(outputs[1], fs.join(ctx.engine_root, "Engine/Source"))
      if family.dependencies.invalid or not source or not parsed_output or key(parsed_output) ~= object_key
          or not compiler_target then
        family.reason = "consumed-command-unresolved"
        plan.gaps[#plan.gaps + 1] = { object = output, rsp = rsp, reason = family.reason }
      elseif family.target and family.target ~= compiler_target then
        family.reason = "multiple-compiler-targets"
      else
        family.target = compiler_target
        all_targets[compiler_target] = true
      end
    end
  end
  if vim.tbl_count(all_targets) > 1 then return disabled(plan, "multiple-compiler-targets") end
  plan.root, plan.response, plan.compiler_cwd = root, response, fs.join(ctx.engine_root, "Engine/Source")
  plan.enabled = true
  return plan
end

function M.keep(plan, rsp_path, args, outputs, dependencies)
  local function retain(reason)
    plan.retained_reasons[reason] = (plan.retained_reasons[reason] or 0) + 1
    return true, reason
  end
  if not plan.enabled then return retain(plan.reason) end
  if type(outputs) ~= "table" or #outputs ~= 1 then return retain("compile-output-unresolved") end
  local output = absolute(outputs[1], plan.compiler_cwd)
  if not output or not fs.path_has_prefix(key(output), key(plan.root)) then return retain("outside-link-scope") end
  local family = plan.families[key(vim.fs.dirname(output))]
  if not family then return retain("no-current-direct-object-family") end
  if dependencies then
    for path, hash in pairs(plan.dependencies) do dependencies[path] = hash end
  end
  if plan.objects[key(output)] then return retain("consumed-object") end
  if family.reason then return retain(family.reason) end
  if not family.target or target_arg(args) ~= family.target then return retain("compiler-target-unresolved") end
  if dependencies and dependencies.invalid then return retain("compile-response-incomplete") end
  plan.excluded[#plan.excluded + 1] = { rsp = rsp_path, output = output, response = plan.response }
  return false, "not-consumed-by-current-link"
end

return M
