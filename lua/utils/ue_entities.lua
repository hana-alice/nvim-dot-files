-- Explicit project modules only; never rewrites existing C++ or Build.cs.
-- Filesystem ownership: exclusive-create two requested source files, with
-- content/inode-checked recovery on failure. No cache or persistent state.
local M = {}
local uv = vim.uv
local templates = {
  object = { label = "UObject", prefix = "U", base = "UObject", include = "UObject/Object.h" },
  actor = { label = "AActor", prefix = "A", base = "AActor", include = "GameFramework/Actor.h" },
  component = {
    label = "UActorComponent",
    prefix = "U",
    base = "UActorComponent",
    include = "Components/ActorComponent.h",
  },
}

local function evidence(key, data)
  pcall(function()
    local probe = require("utils.probe")
    probe.observe("ue-entities", "ide-ue-tools-2026-10-03")
    probe.record("ue-entities", key, data)
  end)
end

local function canonical(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local real = uv.fs_realpath(path)
  return real and vim.fs.normalize(real) or nil
end

local function key(path)
  return require("utils.platform").driver().path_key(vim.fs.normalize(path or ""))
end

local function within(path, root)
  path, root = key(path), key(root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function bytes(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size > 2 * 1024 * 1024 then
    return nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local value = f:read("*a")
  f:close()
  return value
end

local function identifier(value)
  return type(value) == "string" and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function project_identity(ctx)
  if not ctx or not ctx.uproject then
    return nil
  end
  return canonical(ctx.uproject)
end

function M.discover(ctx)
  local project = project_identity(ctx)
  local descriptor = project and bytes(project)
  if not descriptor then
    return nil, "未选择可读的 .uproject；先运行 :UESetProject"
  end
  local ok, document = pcall(vim.json.decode, descriptor)
  if not ok or type(document) ~= "table" or type(document.Modules) ~= "table" then
    return nil, "项目描述没有有效的 Modules；首版只支持项目明确声明的 C++ 模块"
  end
  local source = canonical(vim.fs.dirname(project) .. "/Source")
  if not source then
    return nil, "项目没有 Source 目录"
  end
  local result, seen = {}, {}
  for _, entry in ipairs(document.Modules) do
    local name = type(entry) == "table" and entry.Name or nil
    if identifier(name) and not seen[name] then
      local root = canonical(source .. "/" .. name)
      local build = root and canonical(root .. "/" .. name .. ".Build.cs")
      if root and build and within(root, source) and within(build, root) and bytes(build) then
        result[#result + 1] = { name = name, root = root, build_cs = build, project = project }
        seen[name] = true
      end
    end
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  if #result == 0 then
    return nil, "没有明确声明且带 .Build.cs 的项目模块；不扫描 Engine/插件目录"
  end
  return result
end

local function buffered(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and key(vim.api.nvim_buf_get_name(buf)) == key(path) then
      return true
    end
  end
  return false
end

local function signature(plan)
  return vim.fn.sha256(vim.json.encode({
    plan.project,
    plan.engine,
    plan.module,
    plan.kind,
    plan.name,
    plan.directory,
    plan.files,
    plan.descriptor_hash,
    plan.build_hash,
    plan.parents,
  }))
end

function M.plan(ctx, spec)
  spec = spec or {}
  local template = templates[spec.kind]
  if not template then
    return nil, "请选择 UObject、AActor 或 UActorComponent"
  end
  if
    not identifier(spec.name)
    or spec.name:sub(1, 1) ~= template.prefix
    or not spec.name:sub(2):match("^[A-Z][A-Za-z0-9_]*$")
    or spec.name == template.base
  then
    return nil,
      "类名必须使用 " .. template.prefix .. " 前缀及大写名称，例如 " .. template.prefix .. "MyClass"
  end
  local directory = spec.directory or ""
  if
    type(directory) ~= "string"
    or directory:find("\\", 1, true)
    or directory:find("//", 1, true)
    or directory:sub(1, 1) == "/"
    or directory:sub(-1) == "/"
  then
    return nil, "目录必须是模块内已有的相对路径"
  end
  for part in directory:gmatch("[^/]+") do
    if not identifier(part) then
      return nil, "目录不能包含 .、.. 或特殊字符"
    end
  end
  local modules, err = M.discover(ctx)
  if not modules then
    return nil, err
  end
  local module
  for _, item in ipairs(modules) do
    if item.name == spec.module then
      module = item
    end
  end
  if not module then
    return nil, "所选模块不再存在或没有 .Build.cs"
  end
  local public, private = canonical(module.root .. "/Public"), canonical(module.root .. "/Private")
  if not (public and private) then
    public, private = module.root, module.root
  end
  local suffix = directory ~= "" and "/" .. directory or ""
  local hdir, cdir = canonical(public .. suffix), canonical(private .. suffix)
  if not hdir or not cdir or not within(hdir, module.root) or not within(cdir, module.root) then
    return nil, "头文件与源文件目录必须已存在于所选模块内"
  end
  local stem = spec.name:sub(2)
  local class_spec = spec.kind == "component" and "ClassGroup=(Custom), meta=(BlueprintSpawnableComponent)" or ""
  local header = {
    "#pragma once",
    "",
    '#include "CoreMinimal.h"',
    '#include "' .. template.include .. '"',
    '#include "' .. stem .. '.generated.h"',
    "",
    "UCLASS(" .. class_spec .. ")",
    "class " .. module.name:upper() .. "_API " .. spec.name .. " : public " .. template.base,
    "{",
    "\tGENERATED_BODY()",
  }
  if spec.kind ~= "object" then
    vim.list_extend(header, { "", "public:", "\t" .. spec.name .. "();" })
  end
  vim.list_extend(header, { "};", "" })
  local source_text = { '#include "' .. (directory ~= "" and directory .. "/" or "") .. stem .. '.h"', "" }
  if spec.kind ~= "object" then
    vim.list_extend(source_text, {
      spec.name .. "::" .. spec.name .. "()",
      "{",
      "\t" .. (spec.kind == "actor" and "PrimaryActorTick" or "PrimaryComponentTick") .. ".bCanEverTick = false;",
      "}",
      "",
    })
  end
  local plan = {
    project = module.project,
    engine = canonical(ctx.engine_root),
    module = module,
    kind = spec.kind,
    name = spec.name,
    directory = directory,
    parents = { hdir, cdir },
    descriptor_hash = vim.fn.sha256(assert(bytes(module.project))),
    build_hash = vim.fn.sha256(assert(bytes(module.build_cs))),
    files = {
      { path = hdir .. "/" .. stem .. ".h", content = table.concat(header, "\n") },
      { path = cdir .. "/" .. stem .. ".cpp", content = table.concat(source_text, "\n") },
    },
  }
  for _, file in ipairs(plan.files) do
    if uv.fs_lstat(file.path) or buffered(file.path) then
      return nil, "目标已经存在或在缓冲区中：" .. file.path
    end
  end
  plan.signature = signature(plan)
  return plan
end

local function unchanged(plan, ctx)
  if type(plan) ~= "table" or plan.signature ~= signature(plan) then
    return nil, "预览内容已改变，请重新创建"
  end
  if project_identity(ctx) ~= plan.project or canonical(ctx.engine_root) ~= plan.engine then
    return nil, "所选工程已改变，请重新创建"
  end
  local descriptor, build = bytes(plan.project), bytes(plan.module.build_cs)
  if canonical(plan.module.root) ~= plan.module.root or canonical(plan.module.build_cs) ~= plan.module.build_cs then
    return nil, "模块目录或规则文件的真实路径已改变"
  end
  if
    not descriptor
    or vim.fn.sha256(descriptor) ~= plan.descriptor_hash
    or not build
    or vim.fn.sha256(build) ~= plan.build_hash
  then
    return nil, "项目描述或模块规则已改变，请重新预览"
  end
  for _, parent in ipairs(plan.parents) do
    if canonical(parent) ~= parent or not within(parent, plan.module.root) then
      return nil, "目标目录已改变"
    end
  end
  for _, file in ipairs(plan.files) do
    if uv.fs_lstat(file.path) or buffered(file.path) then
      return nil, "目标已存在或在缓冲区中：" .. file.path
    end
  end
  return true
end

local function same_file(a, b)
  return a
    and b
    and a.type == "file"
    and b.type == "file"
    and a.dev == b.dev
    and a.ino == b.ino
    and vim.deep_equal(a.birthtime, b.birthtime)
end

function M.apply(plan, opts)
  opts = opts or {}
  local ctx = opts.context
  if opts.resolve_context then
    ctx = opts.resolve_context()
  end
  if not ctx then
    ctx = require("ue").resolve_context()
  end
  local valid, err = unchanged(plan, ctx)
  if not valid then
    return false, err
  end
  local owned = {}
  local function recover(reason)
    local retained = {}
    for _, item in ipairs(owned) do
      if item.fd then
        pcall(uv.fs_close, item.fd)
        item.fd = nil
      end
      if same_file(uv.fs_lstat(item.path), item.stat) and bytes(item.path) == item.written then
        local removed = uv.fs_unlink(item.path)
        if not removed then
          retained[#retained + 1] = item.path
        end
      elseif uv.fs_lstat(item.path) then
        retained[#retained + 1] = item.path
      end
    end
    if #retained > 0 then
      reason = reason .. "；保留已变化/无法移除的文件：" .. table.concat(retained, ", ")
    end
    evidence(plan.kind .. "|create", {
      state = "unavailable",
      kind = plan.kind,
      name = plan.name,
      project = plan.project,
      partial = #retained > 0,
      reason = reason:sub(1, 512),
    })
    return false, reason
  end
  for _, file in ipairs(plan.files) do
    local ok, fd, open_err = pcall(opts.open or uv.fs_open, file.path, "wx", 420)
    if not ok or not fd then
      return recover("创建失败：" .. tostring(ok and open_err or fd))
    end
    -- Compare path-stat with path-stat during recovery: libuv's handle and
    -- path stat device identifiers need not have the same representation.
    local claim = { path = file.path, fd = fd, stat = uv.fs_lstat(file.path), written = "" }
    owned[#owned + 1] = claim
    local handle_stat = uv.fs_fstat(fd)
    if
      not handle_stat
      or not claim.stat
      or handle_stat.ino ~= claim.stat.ino
      or not vim.deep_equal(handle_stat.birthtime, claim.stat.birthtime)
    then
      claim.stat = nil
      return recover("新文件身份在创建时已改变")
    end
    local offset = 0
    while offset < #file.content do
      local written, write_err = uv.fs_write(fd, file.content:sub(offset + 1), offset)
      if not written or written == 0 then
        return recover("写入失败：" .. tostring(write_err))
      end
      offset = offset + written
      claim.written = file.content:sub(1, offset)
    end
    local synced, sync_err = uv.fs_fsync(fd)
    if not synced then
      return recover("保存失败：" .. tostring(sync_err))
    end
  end
  for _, item in ipairs(owned) do
    local closed, close_err = uv.fs_close(item.fd)
    item.fd = nil
    if not closed then
      return recover("关闭文件失败：" .. tostring(close_err))
    end
  end
  evidence(plan.kind .. "|create", { state = "ok", kind = plan.kind, files = #plan.files })
  return true
end

function M.preview(plan, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {
    "预览两个新文件。y 创建；q / Esc 取消。",
    "模板仍需本工程 UHT/编译验证；不会修改 Build.cs。",
    "",
  }
  for _, file in ipairs(plan.files) do
    lines[#lines + 1] = "## " .. file.path
    lines[#lines + 1] = "```cpp"
    vim.list_extend(lines, vim.split(file.content, "\n", { plain = true }))
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype, vim.bo[buf].modifiable, vim.bo[buf].bufhidden = "markdown", false, "wipe"
  local width, height = math.max(1, math.min(vim.o.columns - 4, 110)), math.max(1, math.min(vim.o.lines - 6, 38))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    border = "rounded",
    title = " UE 新建类 ",
    style = "minimal",
  })
  local decided = false
  local function finish(accept)
    if decided then
      return
    end
    decided = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    callback(accept)
  end
  vim.keymap.set("n", "y", function()
    finish(true)
  end, { buffer = buf, nowait = true })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      finish(false)
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if not decided then
        decided = true
        callback(false)
      end
    end,
  })
end

function M.new(opts)
  opts = opts or {}
  local resolve = opts.resolve_context or function()
    return require("ue").resolve_context()
  end
  local ctx = opts.context or resolve()
  local modules, err = M.discover(ctx)
  if not modules then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  ctx = vim.deepcopy(ctx)
  vim.ui.select(modules, {
    prompt = "新类所属模块：",
    format_item = function(item)
      return item.name
    end,
  }, function(module)
    if not module then
      return
    end
    vim.ui.select({ "object", "actor", "component" }, {
      prompt = "父类：",
      format_item = function(kind)
        return templates[kind].label
      end,
    }, function(kind)
      if not kind then
        return
      end
      vim.ui.input({ prompt = "类名（含 " .. templates[kind].prefix .. " 前缀）：" }, function(name)
        if not name then
          return
        end
        vim.ui.input(
          { prompt = "已有子目录（相对 Public/Private；留空为根）：", default = "" },
          function(directory)
            if directory == nil then
              return
            end
            local plan, plan_err =
              M.plan(ctx, { module = module.name, kind = kind, name = name, directory = directory })
            if not plan then
              vim.notify(plan_err, vim.log.levels.WARN)
              return
            end
            (opts.preview or M.preview)(plan, function(accept)
              if not accept then
                return
              end
              local ok, apply_err = M.apply(plan, { resolve_context = resolve })
              if not ok then
                vim.notify(apply_err, vim.log.levels.ERROR)
                return
              end
              vim.notify(
                "已创建 " .. plan.name .. " 的头文件与源文件；请运行工程 UHT/编译验证",
                vim.log.levels.INFO
              )
              vim.cmd.edit(vim.fn.fnameescape(plan.files[1].path))
            end)
          end
        )
      end)
    end)
  end)
end

function M.setup_commands()
  vim.api.nvim_create_user_command("UENewClass", function()
    M.new()
  end, { desc = "预览并创建项目模块中的 UE 类" })
end

return M
