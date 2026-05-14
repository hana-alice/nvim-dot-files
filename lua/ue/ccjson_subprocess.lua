-- ue.ccjson_subprocess — entry point for the compile_commands subprocess.
--
-- Invocation (from main nvim):
--   nvim --headless -u NONE \
--     --cmd 'lua package.path=vim.fn.stdpath("config").."/lua/?.lua;"..vim.fn.stdpath("config").."/lua/?/init.lua;"..package.path' \
--     -l <this file> <ctx_json_path>
--
-- Reads ctx (project_root/engine_root/etc.) from a JSON file (argv[1]),
-- runs the full compile_commands generation pipeline in this subprocess,
-- and emits progress events to stderr as line-delimited records:
--   PROGRESS|<stage>|<pct>|<detail>
--   DONE|<entries>|<preferred_path>
--   ERROR|<msg>
--
-- The subprocess writes the cdb to disk itself (compile_commands_targets);
-- the main nvim only consumes progress events and inspects exit code.

local ctx_path = arg and arg[1]
if not ctx_path or ctx_path == "" then
  io.stderr:write("ERROR|missing ctx_json path argv[1]\n")
  os.exit(2)
end

local f, ferr = io.open(ctx_path, "r")
if not f then
  io.stderr:write("ERROR|cannot open ctx: " .. tostring(ferr) .. "\n")
  os.exit(2)
end
local ctx_str = f:read("*a")
f:close()

local ok_decode, ctx = pcall(vim.json.decode, ctx_str)
if not ok_decode or type(ctx) ~= "table" then
  io.stderr:write("ERROR|invalid ctx json: " .. tostring(ctx) .. "\n")
  os.exit(2)
end

-- Make ue.lua and its submodules requireable. We were launched with -u NONE,
-- so nothing in the user's init.lua ran; package.path was set via --cmd.
local ue_ok, ue = pcall(require, "ue")
if not ue_ok then
  io.stderr:write("ERROR|require ue failed: " .. tostring(ue) .. "\n")
  os.exit(3)
end

-- Progress callback writes one line per event to stderr (flushed immediately).
-- The main nvim's stderr handler parses these and feeds the progress UI.
local function emit_progress(stage, pct, detail)
  io.stderr:write(string.format("PROGRESS|%s|%d|%s\n",
    stage, pct or 0, detail or ""))
  io.stderr:flush()
end

-- The export hook in ue.lua sets up the same closure environment that the
-- in-process call would use, then runs generate_compile_commands(ctx, progress).
if type(ue._ccjson_subprocess_run) ~= "function" then
  io.stderr:write("ERROR|ue._ccjson_subprocess_run not exported\n")
  os.exit(4)
end

local ok_run, result_or_err, preferred = pcall(ue._ccjson_subprocess_run, ctx, emit_progress)
if not ok_run then
  io.stderr:write("ERROR|" .. tostring(result_or_err) .. "\n")
  os.exit(5)
end

-- result_or_err is `ok` (boolean) from generate_compile_commands; preferred is the path.
if result_or_err then
  io.stderr:write(string.format("DONE|%s|%s\n",
    tostring(preferred or ""), ""))
  os.exit(0)
else
  io.stderr:write("ERROR|" .. tostring(preferred or "compile_commands generation failed") .. "\n")
  os.exit(6)
end
