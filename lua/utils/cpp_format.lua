-- Explicit project-style formatting. Missing configuration never means LLVM.
local M = {}
local family = { c = true, cpp = true, objc = true, objcpp = true }
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
M.template = vim.fs.joinpath(root, "docs", "epic.clang-format")

function M.is_cpp(buf)
  return family[vim.bo[buf or 0].filetype] == true
end

function M.find_config(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  local dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  return vim.fs.find({ ".clang-format", "_clang-format" }, { path = dir, upward = true, type = "file" })[1]
end

function M.command()
  local platform = require("utils.platform")
  local candidates = { "clang-format" }
  local clangd = { vim.env.UE_CLANGD }
  vim.list_extend(clangd, require("ue.config").get("clangd.candidates_extra") or {})
  vim.list_extend(clangd, platform.driver().default_clangd_candidates())
  for _, path in ipairs(clangd) do
    candidates[#candidates + 1] = path:gsub("clangd([^/\\]*)$", "clang-format%1")
  end
  return platform.resolve_tool({ name = "clang-format", env = { "UE_CLANG_FORMAT" }, driver_candidates = candidates }).path
    or "clang-format"
end

-- Capture the active selection before a picker changes mode or focus.
function M.selection()
  local mode = vim.fn.mode()
  if mode == "\22" then
    vim.notify("格式化不支持块选区，请用 v 或 V 选择连续文本", vim.log.levels.INFO)
    return nil
  end
  if mode ~= "v" and mode ~= "V" then
    return nil
  end
  local first, last = vim.fn.getpos("v"), vim.fn.getpos(".")
  if first[2] > last[2] or (first[2] == last[2] and first[3] > last[3]) then
    first, last = last, first
  end
  local ending = mode == "V" and #vim.api.nvim_buf_get_lines(0, last[2] - 1, last[2], false)[1] or last[3]
  return { start = { first[2], mode == "V" and 0 or first[3] - 1 }, ["end"] = { last[2], ending } }
end

local function run(buf, opts)
  local conform = require("conform")
  local formatter = opts.style == "epic" and "ue_epic" or "clang_format"
  if not conform.get_formatter_info(formatter, buf).available then
    vim.notify("clang-format 不可用；未修改文件。请查看 :ConformInfo", vim.log.levels.WARN)
    return
  end
  conform.format({
    bufnr = buf,
    range = opts.range,
    formatters = { formatter },
    lsp_format = "never",
    async = true,
    timeout_ms = 3000,
  })
end

function M.format(opts)
  opts = opts or {}
  local buf = opts.bufnr or vim.api.nvim_get_current_buf()
  if not M.is_cpp(buf) then
    return LazyVim.format({ force = true, buf = buf })
  end
  if M.find_config(buf) or opts.style == "epic" then
    return run(buf, opts)
  end
  vim.notify("本工程没有 .clang-format，已跳过", vim.log.levels.INFO)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local choice = opts.range and "用 UE 风格格式化选区" or "用 UE 风格格式化全文件"
  vim.ui.select(
    { choice, "取消" },
    { prompt = "选择格式化方式（不会创建工程配置）：" },
    function(item)
      if item ~= choice or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        vim.notify("文件已改变，请重新选择格式化范围", vim.log.levels.INFO)
        return
      end
      run(buf, { range = opts.range, style = "epic" })
    end
  )
end

function M.setup()
  vim.api.nvim_create_user_command("UEFormat", function(args)
    if args.args ~= "" and args.args ~= "epic" then
      vim.notify("用法：:[range]UEFormat [epic]", vim.log.levels.WARN)
      return
    end
    local range = args.range > 0
        and {
          start = { args.line1, 0 },
          ["end"] = { args.line2, #vim.api.nvim_buf_get_lines(0, args.line2 - 1, args.line2, false)[1] },
        }
      or nil
    M.format({ style = args.args, range = range })
  end, {
    nargs = "?",
    range = true,
    complete = function()
      return { "epic" }
    end,
    desc = "安全格式化 C++（缺配置时可选 UE 风格）",
  })
end

return M
