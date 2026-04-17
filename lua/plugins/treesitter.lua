-- nvim-treesitter is on the `main` branch (rewrite). The old API
-- (auto_install, highlight.enable as a flat opt, :TSUpdate as build cmd)
-- no longer applies — LazyVim's own spec already handles install/setup
-- correctly. We only extend ensure_installed via opts_extend.
--
-- main branch compiles parsers from C source via cc -- on Windows that
-- means clang/gcc/cl must be on PATH. LLVM ships with UE workflows but
-- isn't on user PATH by default. Inject it here so :TSInstall works.
local llvm_bin = "C:\\Program Files\\LLVM\\bin"
if vim.fn.has("win32") == 1 and vim.fn.isdirectory(llvm_bin) == 1 then
  if not (vim.env.PATH or ""):find(llvm_bin, 1, true) then
    vim.env.PATH = llvm_bin .. ";" .. (vim.env.PATH or "")
  end
end

return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts_extend = { "ensure_installed" },
    opts = {
      ensure_installed = {
        "c",
        "cpp",
        "hlsl",
      },
    },
  },
}
