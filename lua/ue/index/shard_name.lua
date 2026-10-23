-- Seed-zero XXH3-64, matching LLVM 22.1.5 llvm/lib/Support/xxhash.cpp
-- and clangd/SourceCode.cpp digest(): eight little-endian bytes, uppercase hex.
-- Uses LuaJIT's built-in uint64 arithmetic; never converts a hash to double.
-- Algorithm adapted from xxHash, Copyright (C) 2012-2023 Yann Collet.
-- BSD 2-Clause License:
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
-- 1. Redistributions of source code must retain the above copyright notice,
--    this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright notice,
--    this list of conditions and the following disclaimer in the documentation
--    and/or other materials provided with the distribution.
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.
local bit = require("bit")
local band, bxor, bor = bit.band, bit.bxor, bit.bor
local shl, shr, rol = bit.lshift, bit.rshift, bit.rol
local M = {}
local P1, P2, P3 = 0x9E3779B185EBCA87ULL, 0xC2B2AE3D27D4EB4FULL, 0x165667B19E3779F9ULL
local P4, P5 = 0x85EBCA77C2B2AE63ULL, 0x27D4EB2F165667C5ULL
local MX1, MX2 = 0x165667919E3779F9ULL, 0x9FB21C651E98DF25ULL
local MASK = 0xFFFFFFFFULL
local secret = ("b8fe6c3923a44bbe7c01812cf721ad1cded46de9839097db7240a4a4b7b3671f"
  .. "cb79e64eccc0e578825ad07dccff7221b8084674f743248ee03590e6813a264c"
  .. "3c2852bb91c300cb88d0658b1b532ea371644897a20df94e3819ef46a9deacd8"
  .. "a8fa763fe39c343ff9dcbbc7c70b4f1d8a51e04bcdb45931c89f7ec9d9787364"
  .. "eac5ac8334d3ebc3c581a0fffa1363eb170ddd51b7f0da49d316552629d4689e"
  .. "2b16be587d47a1fc8ff8b8d17ad031ce45cb3a8f95160428afd7fbcabb4b407e")
  :gsub("..", function(byte) return string.char(tonumber(byte, 16)) end)

-- Offsets throughout this module are zero-based, as in the reference algorithm.
local function read32(s, p)
  local a, b, c, d = s:byte(p + 1, p + 4)
  return a + b * 256 + c * 65536 + d * 16777216
end
local function read64(s, p)
  return read32(s, p) + shl(read32(s, p + 4) + 0ULL, 32)
end
local function fold(a, b)
  local ll = band(a, MASK) * band(b, MASK)
  local hl = shr(a, 32) * band(b, MASK)
  local lh = band(a, MASK) * shr(b, 32)
  local hh = shr(a, 32) * shr(b, 32)
  local cross = shr(ll, 32) + band(hl, MASK) + lh
  return bxor(shr(hl, 32) + shr(cross, 32) + hh, bor(shl(cross, 32), band(ll, MASK)))
end
local function avalanche(h)
  h = bxor(h, shr(h, 37)) * MX1
  return bxor(h, shr(h, 32))
end
local function avalanche64(h)
  h = bxor(h, shr(h, 33)) * P2
  h = bxor(h, shr(h, 29)) * P3
  return bxor(h, shr(h, 32))
end
local function mix(s, p, k)
  return fold(bxor(read64(s, p), read64(secret, k)), bxor(read64(s, p + 8), read64(secret, k + 8)))
end
local function hash(s)
  local n = #s
  if n <= 16 then
    if n > 8 then
      local lo = bxor(read64(s, 0), read64(secret, 24), read64(secret, 32))
      local hi = bxor(read64(s, n - 8), read64(secret, 40), read64(secret, 48))
      return avalanche(n + bit.bswap(lo) + hi + fold(lo, hi))
    elseif n >= 4 then
      local h = bxor(read64(secret, 8), read64(secret, 16),
        bor(read32(s, n - 4) + 0ULL, shl(read32(s, 0) + 0ULL, 32)))
      h = bxor(h, rol(h, 49), rol(h, 24)) * MX2
      h = bxor(h, shr(h, 35) + n) * MX2
      return bxor(h, shr(h, 28))
    elseif n > 0 then
      local combined = s:byte(1) * 65536 + s:byte(math.floor(n / 2) + 1) * 16777216
        + s:byte(n) + n * 256
      return avalanche64(bxor(combined + 0ULL, read32(secret, 0) + 0ULL, read32(secret, 4) + 0ULL))
    end
    return avalanche64(bxor(read64(secret, 56), read64(secret, 64)))
  elseif n <= 128 then
    local acc = n * P1 + mix(s, 0, 0) + mix(s, n - 16, 16)
    if n > 32 then
      acc = acc + mix(s, 16, 32) + mix(s, n - 32, 48)
      if n > 64 then
        acc = acc + mix(s, 32, 64) + mix(s, n - 48, 80)
        if n > 96 then acc = acc + mix(s, 48, 96) + mix(s, n - 64, 112) end
      end
    end
    return avalanche(acc)
  elseif n <= 240 then
    local acc = n * P1
    for i = 0, 7 do acc = acc + mix(s, 16 * i, 16 * i) end
    acc = avalanche(acc)
    for i = 8, math.floor(n / 16) - 1 do acc = acc + mix(s, 16 * i, 16 * (i - 8) + 3) end
    return avalanche(acc + mix(s, n - 16, 119))
  end
  local acc = { 0xC2B2AE3DULL, P1, P2, P3, P4, 0x85EBCA77ULL, P5, 0x9E3779B1ULL }
  local function stripe(p, k)
    for i = 0, 7 do
      local value = read64(s, p + i * 8)
      local key = bxor(value, read64(secret, k + i * 8))
      local other = bit.bxor(i, 1) + 1
      acc[other] = acc[other] + value
      acc[i + 1] = acc[i + 1] + band(key, MASK) * shr(key, 32)
    end
  end
  local blocks = math.floor((n - 1) / 1024)
  for block = 0, blocks - 1 do
    for j = 0, 15 do stripe(block * 1024 + j * 64, j * 8) end
    for i = 0, 7 do
      local value = bxor(acc[i + 1], shr(acc[i + 1], 47), read64(secret, 128 + i * 8))
      acc[i + 1] = value * 0x9E3779B1ULL
    end
  end
  for j = 0, math.floor((n - 1 - blocks * 1024) / 64) - 1 do stripe(blocks * 1024 + j * 64, j * 8) end
  stripe(n - 64, 121)
  local h = n * P1
  for i = 0, 3 do
    h = h + fold(bxor(acc[2 * i + 1], read64(secret, 11 + i * 16)),
      bxor(acc[2 * i + 2], read64(secret, 19 + i * 16)))
  end
  return avalanche(h)
end

function M.digest(bytes)
  assert(type(bytes) == "string", "digest expects bytes")
  local h, out = hash(bytes), {}
  for i = 1, 8 do
    out[i] = string.format("%02X", tonumber(band(h, 255ULL)))
    h = shr(h, 8)
  end
  return table.concat(out)
end

-- Callers resolve relative CDB paths first. Preserve case: clangd hashes path
-- bytes, not a case-folded identity key. No filesystem lookup or process spawn.
function M.for_path(path)
  assert(type(path) == "string" and not path:find("\0", 1, true), "invalid main path")
  local windows = path:match("^%a:[/\\]") or path:match("^\\\\") or path:match("^//[^/]+/")
  assert(windows or path:sub(1, 1) == "/", "main path must be absolute")
  if windows then path = path:gsub("/", "\\") end
  local basename = path:match("([^/\\]+)$")
  assert(basename, "main path must name a file")
  return basename .. "." .. M.digest(path) .. ".idx"
end

return M
