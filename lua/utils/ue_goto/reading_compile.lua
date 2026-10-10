-- Pure compiler descriptor checks for header command transport.
local M = {}
local model = require("utils.ue_goto.semantic_context")

local operands = {}
for _, flag in ipairs({
  "-include", "-include-pch", "-imacros", "-I", "-isystem", "-iquote", "-idirafter", "-iframework", "-F",
  "-D", "-U", "-o", "-MF", "-MT", "-MQ", "-MJ", "-x", "-std", "--target", "-target", "-isysroot",
  "--sysroot", "-resource-dir", "-gcc-toolchain", "--gcc-toolchain", "-fmodule-map-file", "-fmodule-file",
  "-Xclang", "-Xpreprocessor", "-Xassembler", "-Xlinker", "-working-directory", "-dependency-file",
  "-serialize-diagnostics", "-fdebug-compilation-dir", "-arch", "-B", "--config", "-L", "-l", "/FI", "/I", "/D", "/Fo",
}) do operands[flag] = true end

function M.rebind(compile, origin, subject)
  local main = model.match_key(compile.file or origin)
  local argv, replaced, operand, options_end = {}, 0, false, false
  for index, value in ipairs(compile.argv or {}) do
    if type(value) ~= "string" then return nil, "header-command-argv-invalid" end
    if index > 1 then
      if operand then
        operand = false
      elseif value == "--" then
        options_end = true
      elseif not options_end and operands[value] then
        operand = true
      elseif options_end or value:sub(1, 1) ~= "-" then
        local path = value
        if not path:match("^%a:[/\\]") and path:sub(1, 1) ~= "/" then
          path = compile.directory .. "/" .. path
        end
        if model.match_key(path) == main then value, replaced = subject, replaced + 1 end
      end
    end
    argv[#argv + 1] = value
  end
  if replaced ~= 1 then return nil, "header-command-main-file-unproven" end
  return { workingDirectory = vim.fs.normalize(compile.directory), compilationCommand = argv }
end

function M.matches_native(compile, origin, fingerprint)
  return model.compile_descriptor_fingerprint(compile.directory, compile.file or origin, compile.argv) == fingerprint
end

return M
