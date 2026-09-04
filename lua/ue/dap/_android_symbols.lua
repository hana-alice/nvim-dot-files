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
--       → 取其 build-id
--         → 选 build-id 相同的符号包（**权威**）
--
-- 符号包目录名只带 versionCode、不带配置，所以 build-id 是唯一可靠的关联键；
-- versionCode 仍作为**必要条件**先行收窄候选集，降低要读的文件数。

local M = {}

local deps = {
  read_build_id = nil, -- fun(path, read_bytes?): string|nil
  is_file = nil,       -- fun(path): boolean
  is_dir = nil,        -- fun(path): boolean
}

function M.bind(overrides)
  for key, value in pairs(overrides or {}) do
    assert(deps[key] ~= nil or key ~= nil, "unknown symbols dependency: " .. tostring(key))
    deps[key] = value
  end
  return M
end

--- 纯函数（可单测）：该配置下产物 so 的文件名。
---
--- 命名规则与 `lua/ue/targets/android.lua` 一致（`<Target>-Android-<Cfg>-arm64.so`）。
--- 刻意复用同一规则而不另造一套：产物命名是 target 层已确立的契约，DAP 只消费它。
--- `Development` 配置的 UBT 产物不带配置后缀，这里也照此处理。
function M.artifact_so_name(target, configuration)
  if type(target) ~= "string" or target == "" then return nil end
  local cfg = tostring(configuration or "")
  if cfg == "" then return nil end
  if cfg == "Development" then
    return ("%s-arm64.so"):format(target)
  end
  return ("%s-Android-%s-arm64.so"):format(target, cfg)
end

--- 纯函数（可单测）：该配置下 receipt 的文件名。
function M.artifact_receipt_name(target, configuration)
  if type(target) ~= "string" or target == "" then return nil end
  local cfg = tostring(configuration or "")
  if cfg == "" then return nil end
  if cfg == "Development" then
    return ("%s.target"):format(target)
  end
  return ("%s-Android-%s.target"):format(target, cfg)
end

--- 读出「当前配置的产物 so」的 build-id。
---
--- 这是**期望值**：符号包必须与它一致，否则断点解析到别的构建。
--- 拿不到就返回 nil —— 上层据此降级为 versionCode 匹配并明确标注为弱判定，
--- MUST NOT 假装已经按配置对齐。
function M.expected_build_id(android_dir, target, configuration)
  if type(android_dir) ~= "string" or android_dir == "" then return nil end
  local so_name = M.artifact_so_name(target, configuration)
  if not so_name then return nil end
  local path = android_dir .. "/" .. so_name
  if not deps.is_file(path) then return nil, path end
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
