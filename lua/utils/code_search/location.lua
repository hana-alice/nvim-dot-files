-- csearch returns a matching line, not a regex span. Never turn uncertainty
-- into a guessed column; a proved literal candidate can carry byte offsets.
local M = {}

local function word(byte)
  return byte ~= nil
    and ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95)
end

function M.ignore_case(pattern, opts)
  opts = opts or {}
  if opts.case == true then
    return false
  end
  if opts.ignore_case == true then
    return true
  end
  return opts.smart_case ~= false and not pattern:find("%u")
end

function M.literal(text, pattern, opts)
  opts = opts or {}
  if opts.regex ~= false then
    return nil, { precision = "line", reason = "csearch-regex-span-unavailable" }
  end
  if pattern == "" then
    return nil, { precision = "line", reason = "literal-span-unavailable" }
  end
  local haystack, needle = text, pattern
  if M.ignore_case(pattern, opts) then
    -- Lua's ASCII lower preserves UTF-8 byte lengths. Every candidate found
    -- this way is an actual RE2 literal match; additional Unicode folds may
    -- exist but are never guessed using a different regex engine.
    haystack, needle = text:lower(), pattern:lower()
  end
  local from = 1
  while from <= #haystack do
    local first, last = haystack:find(needle, from, true)
    if not first then
      break
    end
    -- RE2 \b is an ASCII word boundary, unlike Vim's configurable iskeyword.
    if
      not opts.word
      or (word(text:byte(first - 1)) ~= word(text:byte(first)) and word(text:byte(last)) ~= word(text:byte(last + 1)))
    then
      return first, {
        precision = "exact",
        byte_start0 = first - 1,
        byte_end0 = last,
      }
    end
    from = first + 1
  end
  return nil, { precision = "line", reason = "literal-span-unavailable" }
end

return M
