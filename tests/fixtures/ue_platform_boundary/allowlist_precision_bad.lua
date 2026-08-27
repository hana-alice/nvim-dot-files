local function register()
  vim.keymap.set("n", "<leader>ua", function() end, { desc = "UE: Select Android device" })
  local executable = "cmd.exe"
  return executable
end

return register
