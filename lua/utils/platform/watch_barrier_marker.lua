-- Windows watcher barrier marker: no subprocess, never replaces an existing file.
local M = {}
local pending = {}

-- No upvalues/editor APIs: luv executes this in an independent Lua state.
local function marker_worker(path)
  local ffi, kernel, handle, writer
  local invoked, ok, err = pcall(function()
    ffi = require("ffi")
    if ffi.os ~= "Windows" then
      return false, "Windows native watcher marker is unavailable on this host"
    end
    path = path:gsub("/", "\\")
    if path:sub(1, 4) == "\\\\?\\" then
      -- Already extended; preserve the caller's native absolute path.
    elseif path:match("^%a:\\") then
      path = "\\\\?\\" .. path
    elseif path:match("^\\\\[^\\]+\\[^\\]+") then
      path = "\\\\?\\UNC\\" .. path:sub(3)
    else
      return false, "Native watcher marker requires an absolute path"
    end
    ffi.cdef([[
      int __stdcall MultiByteToWideChar(unsigned int, unsigned long,
        const char *, int, uint16_t *, int);
      void * __stdcall CreateFileW(const uint16_t *, unsigned long,
        unsigned long, void *, unsigned long, unsigned long, void *);
      int __stdcall WriteFile(void *, const void *, unsigned long, unsigned long *, void *);
      int __stdcall FlushFileBuffers(void *);
      int __stdcall CloseHandle(void *);
      unsigned long __stdcall GetLastError(void);
    ]])
    kernel = ffi.load("kernel32")
    local function failure(operation)
      return operation .. " failed (Win32 error " .. tonumber(kernel.GetLastError()) .. ")"
    end
    local length = kernel.MultiByteToWideChar(65001, 8, path, #path, nil, 0)
    if length == 0 then return false, failure("UTF-8 path conversion") end
    if length > 32766 then return false, "Native watcher marker path exceeds the Windows limit" end
    local wide = ffi.new("uint16_t[?]", length + 1)
    if kernel.MultiByteToWideChar(65001, 8, path, #path, wide, length) ~= length then
      return false, failure("UTF-8 path conversion")
    end
    -- CREATE_NEW; read/write/delete sharing; hidden + temporary + delete-on-close.
    handle = kernel.CreateFileW(wide, 0x00010000, 7, nil, 1, 0x04000102, nil)
    if handle == ffi.cast("void *", -1) or handle == ffi.NULL then
      handle = nil
      return false, failure("CreateFileW")
    end
    writer = kernel.CreateFileW(wide, 0x40000000, 7, nil, 3, 0x00000102, nil)
    if writer == ffi.cast("void *", -1) or writer == ffi.NULL then
      writer = nil
      return false, failure("CreateFileW writer")
    end
    local written = ffi.new("unsigned long[1]")
    if kernel.WriteFile(writer, "x", 1, written, nil) == 0 then
      return false, failure("WriteFile")
    end
    if tonumber(written[0]) ~= 1 then return false, "Native watcher marker write was incomplete" end
    if kernel.FlushFileBuffers(writer) == 0 then return false, failure("FlushFileBuffers") end
    if kernel.CloseHandle(writer) == 0 then return false, failure("CloseHandle writer") end
    writer = nil
    return true
  end)
  -- Close every writer before ACK, retaining only the non-writing deletion owner.
  if writer then
    pcall(function() kernel.CloseHandle(writer) end)
  end
  if handle and (not invoked or not ok) then
    local closed, close_ok, close_err = pcall(function()
      if kernel.CloseHandle(handle) == 0 then
        return false, "CloseHandle failed (Win32 error " .. tonumber(kernel.GetLastError()) .. ")"
      end
      return true
    end)
    if not closed or not close_ok then
      return false, closed and close_err or ("Native watcher marker close failed: " .. tostring(close_ok))
    end
  end
  if not invoked then return false, "Native watcher marker unavailable: " .. tostring(ok) end
  if ok then return true, nil, tonumber(ffi.cast("uintptr_t", handle)) end
  return ok, err
end

-- The owner has DELETE access but never writes; its final close removes the marker.
local function release_worker(owner)
  local invoked, ok, err = pcall(function()
    local ffi = require("ffi")
    ffi.cdef([[
      int __stdcall CloseHandle(void *);
      unsigned long __stdcall GetLastError(void);
    ]])
    local kernel = ffi.load("kernel32")
    if kernel.CloseHandle(ffi.cast("void *", owner)) == 0 then
      return false, "CloseHandle owner failed (Win32 error " .. tonumber(kernel.GetLastError()) .. ")"
    end
    return true
  end)
  if not invoked then return false, "Native watcher marker release unavailable: " .. tostring(ok) end
  return ok, err
end

local function owner_release(owner)
  local released = false
  local release
  release = function(done)
    if type(done) ~= "function" then return false, "Marker release requires a callback" end
    if released then
      vim.schedule(function() done(false, "Marker owner release already requested") end)
      return false, "Marker owner release already requested"
    end
    local uv = vim.uv or vim.loop
    local work, completed
    local function complete(ok, err)
      if completed then return end
      completed = true
      vim.schedule(function()
        if work then pending[work] = nil end
        pending[release] = nil
        if ok == true then done(true, nil) else done(false, err or "Native marker release failed") end
      end)
    end
    local function fail_async(err)
      -- Only broken async submission falls back to a synchronous handle close.
      -- This releases the resource; it does not turn the failed request into success.
      local closed, close_err = release_worker(owner)
      if closed then
        released = true
        pending[release] = nil
      else
        err = err .. "; owner cleanup failed: " .. tostring(close_err)
      end
      vim.schedule(function() done(false, err) end)
      return false, err
    end
    local created, value = pcall(uv.new_work, release_worker, complete)
    if not created or not value then
      local err = "Cannot create marker release worker: " .. tostring(value)
      return fail_async(err)
    end
    work = value
    pending[work] = true
    local called, queued, queue_err = pcall(work.queue, work, owner)
    if not called or not queued then
      pending[work] = nil
      local err = "Cannot queue marker release worker: " .. tostring(called and queue_err or queued)
      return fail_async(err)
    end
    released = true
    return true
  end
  pending[release] = true
  return release
end

---@param path string Absolute, unique marker path inside the watched root.
---@param callback fun(ok:boolean, err:string|nil, release:function|nil) Release after watcher ACK.
---@return boolean queued
---@return string? error
function M.create(path, callback)
  if type(callback) ~= "function" then return false, "Native watcher marker requires a callback" end
  local work, completed
  local function complete(ok, err, owner)
    if completed then return end
    completed = true
    vim.schedule(function()
      if work then pending[work] = nil end
      if ok == true and type(owner) == "number" and owner > 0 then
        callback(true, nil, owner_release(owner))
      else
        callback(false, err or "Native watcher marker failed")
      end
    end)
  end
  if type(path) ~= "string" or path == "" or #path > 131068 or path:find("\0", 1, true) then
    local err = "Native watcher marker requires a bounded path without NUL bytes"
    complete(false, err)
    return false, err
  end
  local uv = vim.uv or vim.loop
  if not uv.new_work then
    local err = "Native watcher marker requires libuv worker support"
    complete(false, err)
    return false, err
  end
  local created, value = pcall(uv.new_work, marker_worker, complete)
  if not created or not value then
    local err = "Cannot create native watcher marker worker: " .. tostring(value)
    complete(false, err)
    return false, err
  end
  work = value
  pending[work] = true
  local called, queued, queue_err = pcall(work.queue, work, path)
  if not called or not queued then
    local err = "Cannot queue native watcher marker worker: " .. tostring(called and queue_err or queued)
    complete(false, err)
    return false, err
  end
  return true
end

return M
