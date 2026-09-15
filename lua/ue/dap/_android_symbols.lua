-- ue.dap._android_symbols — 按**构建配置**选符号库（build-id 为权威关联）。
--
-- 为何存在（K65，2026-09-04 用户指出）：
-- 符号库选择此前只按 `packageInfo.txt` 的 versionCode 匹配，注释还声称这
-- "guarantees the symbols correspond to the installed APK" —— 该说法已被 K64 证伪：
-- 同一 versionCode 下存在多个不同 build-id（Shipping / Test / Testarm64 / …），
-- 因为 versionCode 来自打包配置、build-id 来自链接产物。
--
-- 更严重的是**配置从未参与选择**：引擎 cache 明确记录了
-- `target_configuration`（本机实测为 `Test`），而 versionCode 匹配却选中了 Shipping
-- 的符号包。于是断点会解析到用户从未构建、也从未要求的配置上。
--
-- 正确的关联链（本模块实现）：
--   引擎 cache 的 target_configuration
--     → 该配置的 receipt / 产物 so（沿用 targets/android.lua 的命名规则）
--       → 产物自带 DWARF 时直接作为符号源（K66）
--       → 否则取其 build-id，选择 build-id 相同的符号包（**权威**）
--
-- 符号包目录名只带 versionCode、不带配置，所以 build-id 是唯一可靠的关联键；
-- versionCode 仍作为**必要条件**先行收窄候选集，降低要读的文件数。

local M = {}

local deps = {
  read_build_id = false,  -- fun(path, read_bytes?): string|nil
  resolve_artifact = false, -- fun(android_dir, target, configuration): string|nil
}

function M.bind(overrides)
  for key, value in pairs(overrides or {}) do
    assert(deps[key] ~= nil, "unknown symbols dependency: " .. tostring(key))
    deps[key] = value
  end
  return M
end

--- 该文件是否自带可调试符号（纯解析，可单测）。
---
--- K66（2026-09-04 实测）：UBT 为 Android 产出的**未 strip** `.so`（位于
--- `Binaries/Android/<Target>-Android-<Cfg>-arm64.so`）本身就含完整调试信息，
--- 且其 build-id 与同配置 APK 内 lib **逐字相同**。实测某 Test 产物：
--- `.debug_info` 1.2GB、`.debug_line` 186MB、`.symtab` 52MB。
--- 因此它是该配置**最直接且不会选错**的符号来源——早期实现只在
--- `*_Symbols_v*` 目录里找候选，于是在只有另一配置符号包的工程上错失了它。
---
--- ELF section header 在**文件尾部**（`e_shoff`），不在头部；只读前几 KB 找
--- `.debug_info` 字串会得到假阴性（实测踩过）。这里按 header 定位，不扫全文。
local function inspect_elf(path)
  if type(path) ~= "string" or path == "" then return nil end
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local ok, result = pcall(function()
    local head = fh:read(64)
    if not head or #head < 64 or head:sub(1, 4) ~= "\127ELF" then return nil end
    -- Android arm64 产物是 little-endian ELF64。拒绝把其他布局按 ELF64 偏移误读。
    if head:byte(5) ~= 2 or head:byte(6) ~= 1 then return nil end

    local function u16(s, off)
      return s:byte(off + 1) + s:byte(off + 2) * 256
    end
    local function u32(s, off)
      return s:byte(off + 1)
        + s:byte(off + 2) * 256
        + s:byte(off + 3) * 65536
        + s:byte(off + 4) * 16777216
    end
    local function u64(s, off)
      local value = 0
      for i = 7, 0, -1 do value = value * 256 + s:byte(off + i + 1) end
      return value
    end
    local function read_at(offset, size, max_size)
      if size < 0 or size > max_size or not fh:seek("set", offset) then return nil end
      local bytes = fh:read(size)
      return bytes and #bytes == size and bytes or nil
    end

    local shoff = u64(head, 0x28)
    local shentsize = u16(head, 0x3a)
    local shnum = u16(head, 0x3c)
    local shstrndx = u16(head, 0x3e)
    if shoff == 0 or shentsize < 64 or shentsize > 4096 or shnum < 2 then return nil end
    if shstrndx == 0 or shstrndx == 0xffff or shstrndx >= shnum then return nil end

    local section_table_size = shentsize * shnum
    local section_table = read_at(shoff, section_table_size, 8 * 1024 * 1024)
    if not section_table then return nil end
    local function section_at(index)
      local start = index * shentsize + 1
      return section_table:sub(start, start + shentsize - 1)
    end

    local string_section = section_at(shstrndx)
    local str_off, str_size = u64(string_section, 0x18), u64(string_section, 0x20)
    local names = read_at(str_off, str_size, 1024 * 1024)
    if not names then return nil end
    local function cstring(bytes, offset)
      if offset < 0 or offset >= #bytes then return nil end
      local start = offset + 1
      local terminator = bytes:find("\0", start, true)
      if not terminator then return nil end
      return bytes:sub(start, terminator - 1)
    end
    local function section_name(section)
      return cstring(names, u32(section, 0))
    end

    local metadata = { has_debug_symbols = false, soname = nil }
    local dynamic_section
    for index = 1, shnum - 1 do
      local section = section_at(index)
      local name = section_name(section)
      local section_type = u32(section, 4)
      local section_size = u64(section, 0x20)
      if (name == ".debug_info" or name == ".zdebug_info")
        and section_type == 1 and section_size > 0 then -- SHT_PROGBITS
        metadata.has_debug_symbols = true
      end
      if section_type == 6 then -- SHT_DYNAMIC
        dynamic_section = section
      end
    end

    -- DT_SONAME is the verified bridge between a differently named host UBT
    -- artifact and the module basename that actually appears in /proc/<pid>/maps.
    if dynamic_section then
      local dynstr_index = u32(dynamic_section, 0x28)
      local entry_size = u64(dynamic_section, 0x38)
      local dynamic_size = u64(dynamic_section, 0x20)
      local dynamic_offset = u64(dynamic_section, 0x18)
      if dynstr_index < shnum and entry_size >= 16 and entry_size <= 256 then
        local dynstr_section = section_at(dynstr_index)
        local dynstr_offset = u64(dynstr_section, 0x18)
        local dynstr_size = u64(dynstr_section, 0x20)
        local dynamic = read_at(dynamic_offset, dynamic_size, 8 * 1024 * 1024)
        if dynamic then
          for offset = 0, #dynamic - entry_size, entry_size do
            if u64(dynamic, offset) == 14 then -- DT_SONAME
              local name_offset = u64(dynamic, offset + 8)
              if name_offset < dynstr_size then
                -- UE's dynstr can exceed 70 MB. Read only the SONAME slice;
                -- loading the whole table just to fetch one C string is wasteful.
                local remaining = dynstr_size - name_offset
                local bytes = read_at(dynstr_offset + name_offset, math.min(remaining, 4096), 4096)
                metadata.soname = bytes and cstring(bytes, 0) or nil
              end
              break
            end
          end
        end
      end
    end
    return metadata
  end)
  fh:close()
  return ok and result or nil
end

function M.has_debug_symbols(path)
  local metadata = inspect_elf(path)
  return metadata and metadata.has_debug_symbols == true or false
end

function M.read_soname(path)
  local metadata = inspect_elf(path)
  return metadata and metadata.soname or nil
end

--- 读出「当前配置的产物 so」的 build-id。
---
--- 这是**期望值**：符号包必须与它一致，否则断点解析到别的构建。
--- 拿不到就返回 nil —— 上层据此降级为 versionCode 匹配并明确标注为弱判定，
--- MUST NOT 假装已经按配置对齐。
function M.expected_build_id(android_dir, target, configuration)
  if type(android_dir) ~= "string" or android_dir == "" then return nil end
  if type(target) ~= "string" or target == "" then return nil end
  if type(configuration) ~= "string" or configuration == "" then return nil end
  local path = deps.resolve_artifact(android_dir, target, configuration)
  if not path then return nil end
  return deps.read_build_id(path), path
end

--- 纯函数（可单测）：在候选符号库中挑出 build-id 与期望值一致的那个。
---
--- 返回 (path, verdict)：
---   verdict "build-id"      — 按 build-id 命中（**权威**）
---   verdict "ambiguous"     — 多个候选 build-id 都命中（不选，交由上层报告）
---   verdict "no-match"      — 有期望值但无候选命中（不选：错的符号比没有更危险）
---   verdict "unknown"       — 没有期望值可比（上层降级为 versionCode 弱匹配）
function M.select_by_build_id(candidates, expected)
  if not expected then return nil, "unknown" end
  local hits = {}
  for _, path in ipairs(candidates or {}) do
    if deps.read_build_id(path) == expected then hits[#hits + 1] = path end
  end
  if #hits == 1 then return hits[1], "build-id" end
  if #hits > 1 then return nil, "ambiguous" end
  return nil, "no-match"
end

return M
