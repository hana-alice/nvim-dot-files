-- Little-endian Android arm64 primitive/FString array storage. Unsupported
-- element layouts retain LLDB's raw fields rather than guessing sizeof(T).
local M = {}
local sizes = {char = 1, ANSICHAR = 1, bool = 1, int8 = 1, uint8 = 1, int8_t = 1, uint8_t = 1,
  char16_t = 2, TCHAR = 2, WIDECHAR = 2, short = 2, ['unsigned short'] = 2, int16 = 2, uint16 = 2,
  int = 4, ['unsigned int'] = 4, int32 = 4, uint32 = 4, int32_t = 4, uint32_t = 4,
  int64 = 8, uint64 = 8, int64_t = 8, uint64_t = 8, ['long long'] = 8, ['unsigned long long'] = 8, FString = 16}

function M.size(kind)
  return kind:match('%*%s*$') and 8 or sizes[kind]
end

function M.hex(data)
  local digits = {}
  for i = #data, 1, -1 do digits[#digits + 1] = ('%02x'):format(data:byte(i)) end -- byte, never a 64-bit Lua number
  return '0x' .. table.concat(digits)
end

function M.address(base, offset)
  local text = base:gsub('^0x', ''):lower()
  local digits, carry = {}, offset
  for i = #text, 1, -1 do
    local value = tonumber(text:sub(i, i), 16) + carry
    digits[i], carry = ('0123456789abcdef'):sub(value % 16 + 1, value % 16 + 1), math.floor(value / 16)
  end
  if carry > 0 then return nil end
  return '0x' .. table.concat(digits)
end

local function unsigned(data)
  local value = 0
  for i = #data, 1, -1 do value = value * 256 + data:byte(i) end
  return value
end

function M.child(kind, data, index, address)
  local value
  if kind == 'FString' then
    local count, capacity = unsigned(data:sub(9, 12)), unsigned(data:sub(13, 16))
    value = count <= capacity and ('storage=%d data=%s'):format(count, M.hex(data:sub(1, 8))) or '<invalid FString storage>'
  elseif kind == 'bool' then
    value = data:byte(1) == 0 and 'false' or 'true'
  elseif kind == 'char16_t' or kind == 'TCHAR' or kind == 'WIDECHAR' then
    local code = unsigned(data)
    if code == 0 then value = "'\\0'"
    elseif code >= 0xD800 and code <= 0xDFFF then value = tostring(code) .. ' (surrogate)'
    else value = vim.json.encode(vim.fn.nr2char(code)) end
  elseif kind:match('%*%s*$') or #data == 8 then
    value = M.hex(data)
    if kind:match('%*%s*$') and value:match('^0x0+$') then value = 'NULL' end
  else
    local number = unsigned(data)
    if not kind:match('^u') and kind ~= 'char16_t' and kind ~= 'TCHAR' and kind ~= 'WIDECHAR' and number >= 2 ^ (#data * 8 - 1) then
      number = number - 2 ^ (#data * 8)
    end
    value = tostring(number)
  end
  return {name = ('[%d]'):format(index), type = kind, value = value, variablesReference = 0,
    memoryReference = address, presentationHint = {attributes = {'readOnly'}}}
end

return M
