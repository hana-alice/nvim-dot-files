-- Compatibility shim for `require("utils.platform")`.
--
-- The real implementation moved to `lua/utils/platform/init.lua` so we can
-- ship a per-platform driver registry under the same namespace.
-- This file is kept so existing call sites (which directly read
-- `M.is_windows`, etc.) remain valid byte-for-byte.

return require("utils.platform.init")
