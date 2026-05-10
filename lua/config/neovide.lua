local M = {}

local function map(modes, lhs, rhs, desc)
  vim.keymap.set(modes, lhs, rhs, { silent = true, desc = desc })
end

local function adjust_scale(delta)
  local next_scale = math.max(0.6, math.min(2.0, (vim.g.neovide_scale_factor or 1.0) + delta))
  vim.g.neovide_scale_factor = math.floor(next_scale * 100 + 0.5) / 100
  vim.notify(("Neovide scale: %.2f"):format(vim.g.neovide_scale_factor), vim.log.levels.INFO)
end

local function set_ime_enabled(enabled)
  vim.g.neovide_input_ime = enabled
end

function M.setup()
  if not vim.g.neovide then
    return
  end

  -- JetBrainsMonoNL = official "No Ligatures" variant (ligatures physically
  -- removed from the font). NFM = Nerd Font Mono (single-width icons).
  -- Note: Neovide's guifont syntax does NOT support disabling OpenType
  -- features — relying on the NL variant is the correct approach.
  vim.o.guifont = "JetBrainsMonoNL NFM:h12"
  vim.opt.linespace = 0

  vim.g.neovide_scale_factor = 1.0
  vim.g.neovide_theme = "dark"
  vim.g.neovide_remember_window_size = true
  vim.g.neovide_confirm_quit = true
  vim.g.neovide_refresh_rate_idle = 30

  vim.g.neovide_position_animation_length = 0.08
  vim.g.neovide_scroll_animation_length = 0.12
  -- ROOT-CAUSE FIX for "<C-o>/gd flash" perceived after cross-buffer jumps.
  --
  -- Wire trace (pynvim UI sniff, see C:/tmp/ui_wire_baseline.log) proves:
  -- when nvim does <C-o> across buffers, Neovide receives a SINGLE
  -- win_viewport with scroll_delta=2818 (raw line count between source and
  -- target). With far_lines=1, Neovide treats this as "far scroll" and plays
  -- a 120ms scroll animation that visually rasters the entire buffer past
  -- the screen -- that's the "flash". There is no (1,0) intermediate cursor
  -- frame on the wire; the flash is 100% client-side scroll animation.
  --
  -- Setting far_lines well above one page height (~52) but well below typical
  -- cross-buffer jump distances (hundreds-thousands) lets <C-f>/<C-b>/zz and
  -- in-screen scrolls animate, while jumplist navigation, gd-to-far-file,
  -- picker confirms, gg, G, etc. teleport instantly.
  vim.g.neovide_scroll_animation_far_lines = 200
  vim.g.neovide_cursor_animation_length = 0.08
  vim.g.neovide_cursor_trail_size = 0.6
  vim.g.neovide_cursor_animate_in_insert_mode = false
  vim.g.neovide_cursor_animate_command_line = false

  vim.g.neovide_floating_shadow = true
  vim.g.neovide_floating_z_height = 8
  vim.g.neovide_light_angle_degrees = 45
  vim.g.neovide_light_radius = 5
  vim.g.neovide_floating_corner_radius = 0.2
  vim.g.neovide_padding_top = 4
  vim.g.neovide_padding_bottom = 0 -- 0 to flush statusline against window edge (cmdheight=0 + noice)
  vim.g.neovide_padding_left = 6
  vim.g.neovide_padding_right = 6
  vim.g.neovide_hide_mouse_when_typing = true
  vim.g.neovide_input_ime = false

  local ime_group = vim.api.nvim_create_augroup("NeovideIME", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertEnter", "InsertLeave" }, {
    group = ime_group,
    callback = function(args)
      set_ime_enabled(args.event == "InsertEnter")
    end,
  })
  vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineLeave" }, {
    group = ime_group,
    pattern = "[/?]",
    callback = function(args)
      set_ime_enabled(args.event == "CmdlineEnter")
    end,
  })

  map({ "n", "i", "t" }, "<C-=>", function()
    adjust_scale(0.05)
  end, "Neovide: Zoom in")
  map({ "n", "i", "t" }, "<C-->", function()
    adjust_scale(-0.05)
  end, "Neovide: Zoom out")
  map({ "n", "i", "t" }, "<C-0>", function()
    vim.g.neovide_scale_factor = 1.0
    vim.notify("Neovide scale: 1.00", vim.log.levels.INFO)
  end, "Neovide: Reset zoom")

  vim.api.nvim_create_user_command("NeovideZoomIn", function()
    adjust_scale(0.05)
  end, { desc = "Increase Neovide scale" })
  vim.api.nvim_create_user_command("NeovideZoomOut", function()
    adjust_scale(-0.05)
  end, { desc = "Decrease Neovide scale" })
  vim.api.nvim_create_user_command("NeovideZoomReset", function()
    vim.g.neovide_scale_factor = 1.0
  end, { desc = "Reset Neovide scale" })
end

return M
