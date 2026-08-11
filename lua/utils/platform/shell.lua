-- Host-neutral shell argv and quoting primitives.
--
-- This module never detects an OS or chooses an executable. Host drivers own
-- that decision and pass an explicit shell kind + executable here.

local M = {}

local function quote_posix(value)
  local text = tostring(value or "")
  return "'" .. text:gsub("'", [['\'']]) .. "'"
end

local function quote_powershell(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function quote_cmd(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

function M.quote(kind, value)
  if kind == "posix" then
    return quote_posix(value)
  end
  if kind == "powershell" then
    return quote_powershell(value)
  end
  if kind == "cmd" then
    return quote_cmd(value)
  end
  error("unknown shell kind: " .. tostring(kind))
end

function M.command(kind, executable, script, opts)
  opts = opts or {}
  executable = tostring(executable or "")
  assert(executable ~= "", "shell executable must be non-empty")
  script = tostring(script or "")

  local args
  if kind == "posix" then
    local basename = vim.fs.basename(executable):lower()
    args = { basename == "sh" and "-c" or "-lc", script }
  elseif kind == "powershell" then
    args = {}
    if opts.no_logo ~= false then
      args[#args + 1] = "-NoLogo"
    end
    vim.list_extend(args, {
      "-NoProfile",
      "-ExecutionPolicy",
      opts.execution_policy or "Bypass",
      "-Command",
      script,
    })
  elseif kind == "cmd" then
    args = { "/d", "/c", script }
  else
    error("unknown shell kind: " .. tostring(kind))
  end

  return {
    executable = executable,
    args = args,
    cwd = opts.cwd,
    metadata = vim.deepcopy(opts.metadata or {}),
  }
end

function M.follow_file(kind, executable, path, cwd)
  path = tostring(path or "")
  if kind == "powershell" then
    local quoted = quote_powershell(path)
    local script = ([[$ErrorActionPreference = 'Continue'
$path = %s
Write-Output ('Following UE log: ' + $path)
$announced = $false
while (-not (Test-Path -LiteralPath $path)) {
  if (-not $announced) {
    Write-Output ('Waiting for log file: ' + $path)
    $announced = $true
  }
  Start-Sleep -Seconds 1
}
Get-Content -LiteralPath $path -Encoding UTF8 -Wait -Tail 200]]):format(quoted)
    return M.command(kind, executable, script, { cwd = cwd })
  end

  if kind == "posix" then
    local quoted = quote_posix(path)
    local script = ([[printf 'Following UE log: %%s\n' %s
if [ ! -f %s ]; then
  printf 'Waiting for log file: %%s\n' %s
fi
while [ ! -f %s ]; do
  sleep 1
done
tail -n 200 -F %s]]):format(quoted, quoted, quoted, quoted, quoted)
    return M.command(kind, executable, script, { cwd = cwd })
  end

  return nil, "file following is unsupported for shell kind: " .. tostring(kind)
end

return M
