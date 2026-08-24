local platform = current_target()

if platform == "IOS" then
  return launch_ios()
end

return launch_default()
