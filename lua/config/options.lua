vim.g.root_spec = { "cwd" }
vim.g.autoformat = false

-- Persistent Zellij sessions can hide SSH_TTY from Nvim's OSC 52 detection.
-- Install the provider before LazyVim initializes clipboard support.
require("config.clipboard").setup()

local opt = vim.opt

-- Keep sessions from silently restoring a different cwd without replaying fold state.
vim.opt.sessionoptions = { "buffers", "tabpages", "winsize", "help", "globals", "skiprtp" }
vim.opt.list = false
opt.expandtab = true
opt.shiftwidth = 4
opt.softtabstop = 4
opt.tabstop = 4
opt.number = true
opt.relativenumber = false

-- C/C++/HLSL: use Vim's `cindent` (C-aware) instead of `smartindent` (generic).
-- smartindent only knows `{` / `}` / `#` and copies prior indent for everything
-- else — so after `private:` it copies `private:`'s indent (wrong, you want
-- members one level deeper). cindent understands access specifiers, labels,
-- namespaces, case statements, etc. and behaves like Rider/clang-format.
--
-- cinoptions tuning:
--   g0     : `public:` / `private:` / `protected:` flush with class brace
--   :0     : `case:` flush with `switch` (we still indent the body)
--   l1     : case body aligned to case statement, not the colon
--   (0  W4 : continuation lines after `(` align to next char, or +4 if `(` is EOL
--   t0     : function return type stays on same column as the function name
--   j1     : Java-style anonymous class / C++ lambda body indent
--   J1     : JS-object-style indent (helps with brace-init lists)
-- (No `N-s` — namespace body IS indented 1 level, matching this project's style.
--  If you want UE/LLVM-style flush namespaces, prepend `N-s,` to cindent_opts.)
local cindent_filetypes = { "c", "cpp", "objc", "objcpp", "hlsl", "shaderslang", "cs", "java", "glsl" }
local cindent_opts = "g0,:0,l1,(0,W4,t0,j1,J1"

local cindent_group = vim.api.nvim_create_augroup("CIndentForCFamily", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = cindent_group,
  pattern = cindent_filetypes,
  callback = function(args)
    local bo = vim.bo[args.buf]
    bo.smartindent = false   -- smartindent + cindent both on = duplicated work + conflicts
    bo.cindent = true
    bo.cinoptions = cindent_opts
    -- Let cindent fully own indent decisions; clear any ftplugin indentexpr
    -- that would otherwise take precedence (cpp has none by default, but be safe)
    bo.indentexpr = ""
  end,
})

vim.filetype.add({
  extension = {
    usf = "hlsl",
    ush = "hlsl",
  },
})

local fallback_commentstrings = {
  hlsl = "// %s",
  shaderslang = "// %s",
  ini = "; %s",
  dosini = "; %s",
}

local function ensure_commentstring(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local bo = vim.bo[bufnr]
  if bo.commentstring ~= "" or bo.filetype == "" then
    return
  end

  local commentstring = fallback_commentstrings[bo.filetype]
  if not commentstring then
    local ok, detected = pcall(vim.filetype.get_option, bo.filetype, "commentstring")
    if ok and type(detected) == "string" and detected:find("%%s") then
      commentstring = detected
    end
  end

  if commentstring and commentstring ~= "" then
    bo.commentstring = commentstring
  end
end

local commentstring_group = vim.api.nvim_create_augroup("UECommentstringFallback", { clear = true })
vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
  group = commentstring_group,
  callback = function(args)
    ensure_commentstring(args.buf)
  end,
})

-- Apple UBT can compile files whose extension is still .cpp/.h with
-- `-x objective-c++`. Resolve only the current buffer's existing exact command
-- so mixed ObjC++ syntax remains available whenever clangd is deferred for
-- missing/stale artifacts; this lookup does not build, index, or launch LSP.
local compile_language_group = vim.api.nvim_create_augroup("UECompileLanguageSyntax", { clear = true })
vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
  group = compile_language_group,
  callback = function(args)
    local bufnr = args.buf
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    local bo = vim.bo[bufnr]
    if (bo.filetype ~= "cpp" and bo.filetype ~= "c") or bo.buftype ~= "" then return end
    if vim.api.nvim_buf_get_name(bufnr) == "" then return end

    local ok_ue, ue = pcall(require, "ue")
    if not ok_ue then return end
    local ok_root, root = pcall(ue.clangd_root, bufnr)
    if not ok_root or not root then return end
    local ok_cmd, resolved_cmd = pcall(ue.clangd_cmd, root)
    if not ok_cmd or type(resolved_cmd) ~= "table" then return end
    pcall(require("ue.clangd_commands").detect_syntax, bufnr, resolved_cmd)
  end,
})

vim.schedule(function()
  pcall(ensure_commentstring, vim.api.nvim_get_current_buf())
end)
