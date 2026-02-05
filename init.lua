-- ========= Modular nvim config (UE-friendly) =========
vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("config.options")
require("config.lazy")

-- UE helpers + commands (UEIndex/UEGrep/UEShaderIndex...)
require("ue")

require("config.keymaps")
require("config.setup")
