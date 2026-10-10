-- Session-local DAP view for native UE summaries. Reads memory and retains
-- adapter references; never compiles expressions or calls target functions.
local M = {}
local array = require('ue.dap._ue_array')
local MAX_STRING_UNITS, MAX_ARRAY_CHILDREN = 256, 128

function M.utf16(data)
  local out, i = {}, 1
  while i + 1 <= #data do
    local code = data:byte(i) + 256 * data:byte(i + 1)
    i = i + 2
    if code == 0 then break end
    if code >= 0xD800 and code <= 0xDBFF then
      local low = i + 1 <= #data and (data:byte(i) + 256 * data:byte(i + 1)) or 0
      if low >= 0xDC00 and low <= 0xDFFF then
        code, i = 0x10000 + (code - 0xD800) * 1024 + low - 0xDC00, i + 2
      else
        code = 0xFFFD
      end
    elseif code >= 0xDC00 and code <= 0xDFFF then
      code = 0xFFFD
    end
    out[#out + 1] = vim.fn.nr2char(code)
  end
  return table.concat(out)
end

function M.array_element(type_name)
  if type_name == 'FString::DataType' then return 'char16_t' end
  local text = type_name:match('^TArray<(.*)>%s*$')
  if not text then return end
  local depth = 0
  for i = 1, #text do
    local char = text:sub(i, i)
    if char == '<' then depth = depth + 1 end
    if char == '>' then depth = depth - 1 end
    if char == ',' and depth == 0 then return vim.trim(text:sub(1, i - 1)) end
  end
  return vim.trim(text)
end

local function null(address)
  return address and address:match('^0x0+$') ~= nil
end

function M.install(session)
  if session._ue_values_installed then return end
  session._ue_values_installed = true
  local request, arrays, generation = session.request, {}, 0
  local function enhance(value, key, finish)
    local text, kind = value[key] or '', (value.type or ''):gsub('^const ', '')
    if text:find('<error:', 1, true) then return finish() end
    if kind:match('%*%s*$') and null(text) then
      value[key], value.variablesReference = 'NULL', 0
      return finish()
    end
    local slots, free = text:match('^slots=(%d+) free=(%d+)$')
    if (kind:match('^TMap<') or kind:match('^TSet<')) and slots then
      if tonumber(slots) >= tonumber(free) then value[key] = 'Num=' .. (tonumber(slots) - tonumber(free)) end
      return finish()
    end
    if kind:match('^TSharedPtr<') or kind:match('^TSharedRef<') then
      local pointer = text:match('^obj=(0x%x+)')
      if pointer then value[key] = (null(pointer) and 'NULL' or 'valid') .. ' ' .. text end
      return finish()
    end
    if kind == 'FWeakObjectPtr' or kind:match('^TWeakObjectPtr<') then
      local index, serial = text:match('^idx=(-?%d+) serial=(%d+)$')
      if not index then return finish() end
      index, serial = tonumber(index), tonumber(serial)
      if index < 0 or serial == 0 then value[key] = 'NULL ' .. text; return finish() end
      value[key] = 'validity unverified ' .. text
      return finish()
    end
    if kind == 'FString' then
      local count, address = text:match('^storage=(%d+) data=(0x%x+)')
      count = tonumber(count)
      if not count then return finish() end
      if count == 0 then value[key] = '"" (empty)'; return finish() end
      if null(address) then value[key] = '<invalid FString: NULL storage>'; return finish() end
      local units = math.min(count, MAX_STRING_UNITS)
      return request(session, 'readMemory', {memoryReference = address, count = units * 2}, function(err, body)
        local ok, data = false, nil
        if not err and body and body.data then ok, data = pcall(vim.base64.decode, body.data) end
        if ok and data and #data == units * 2 and not (body.unreadableBytes and body.unreadableBytes > 0) then
          value[key] = vim.json.encode(M.utf16(data)) .. (count > units and ' (truncated)' or '')
        else
          value[key] = '<unreadable FString> ' .. text
        end
        finish()
      end)
    end
    local element = M.array_element(kind)
    local count, capacity, address = text:match('^size=(%d+) cap=(%d+) data=(0x%x+)')
    count, capacity = tonumber(count), tonumber(capacity)
    if not element or not count or count > capacity then return finish() end
    if count == 0 then value.variablesReference = 0; value.indexedVariables = 0; return finish() end
    if null(address) then value[key] = text .. ' (invalid NULL data)'; return finish() end
    local children = math.min(count, MAX_ARRAY_CHILDREN)
    local size = array.size(element)
    if size and value.variablesReference and value.variablesReference > 0 then
      arrays[value.variablesReference] = {element = element, size = size, address = address, count = children}
      value.indexedVariables = children
      if children < count then value[key] = text .. (' (first %d of %d)'):format(children, count) end
    else
      value[key] = text .. ' (elements unavailable; raw fields retained)'
    end
    finish()
  end

  session.request = function(self, command, args, callback)
    if command == 'continue' or command == 'next' or command == 'stepIn' or command == 'stepOut' or command == 'disconnect' then
      generation, arrays = generation + 1, {}
    end
    if not callback or (command ~= 'variables' and command ~= 'evaluate') then
      return request(self, command, args, callback)
    end
    local revision = generation
    return request(self, command, args, function(err, body)
      if err or not body or generation ~= revision then return callback(err, body) end
      local view = vim.deepcopy(body)
      local values = command == 'variables' and (view.variables or {}) or {view}
      local key, i = command == 'variables' and 'value' or 'result', 0
      local function next_value()
        if generation ~= revision then return callback(err, body) end
        i = i + 1
        if not values[i] then return callback(err, view) end
        return enhance(values[i], key, next_value)
      end
      local storage = command == 'variables' and arrays[args.variablesReference]
      if not storage or args.filter == 'named' then return next_value() end
      local start = math.max(0, math.floor(tonumber(args.start) or 0))
      local count = math.min(storage.count - start, math.max(0, math.floor(tonumber(args.count) or storage.count)))
      if count <= 0 then view.variables = args.filter == 'indexed' and {} or view.variables; return next_value() end
      request(self, 'readMemory', {memoryReference = storage.address, offset = start * storage.size, count = count * storage.size}, function(read_err, memory)
        if generation ~= revision then return callback(err, body) end
        local ok, data = false, nil
        if not read_err and memory and memory.data then ok, data = pcall(vim.base64.decode, memory.data) end
        if not ok or not data or #data ~= count * storage.size or (memory.unreadableBytes or 0) > 0 then
          return callback(err, body)
        end
        local children = {}
        for n = 0, count - 1 do
          local address = array.address(storage.address, (start + n) * storage.size)
          children[#children + 1] = array.child(storage.element, data:sub(n * storage.size + 1, (n + 1) * storage.size), start + n, address)
        end
        if args.filter ~= 'indexed' then vim.list_extend(children, view.variables or {}) end
        view.variables, values = children, children
        next_value()
      end)
    end)
  end
end

return M
