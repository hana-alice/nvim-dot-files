-- Deterministic encoding and hashing for semantic context evidence.

local M = {}

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for k, _ in pairs(value) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  for i = 1, count do
    if value[i] == nil then
      return false
    end
  end
  return true
end

local function stable_encode(value)
  local ty = type(value)
  if ty == "nil" then
    return "null"
  end
  if ty == "boolean" or ty == "number" then
    return tostring(value)
  end
  if ty == "string" then
    return string.format("%q", value)
  end
  if ty ~= "table" then
    return string.format("%q", tostring(value))
  end

  if is_list(value) then
    local parts = {}
    for i = 1, #value do
      parts[i] = stable_encode(value[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = stable_encode(tostring(key)) .. ":" .. stable_encode(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function sha256(payload)
  return vim.fn.sha256(stable_encode(payload))
end

M.is_list = is_list
M.sha256 = sha256

return M
