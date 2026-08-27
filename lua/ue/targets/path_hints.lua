-- Target-owned path ranking data for the public `ue.platform_path_priorities`
-- compatibility API. This is registry data only; it never selects or executes
-- a workflow.
local HINTS = {
  Win64 = { "D3D12RHI", "D3D11RHI", "VulkanRHI", "WindowsRHI", "WindowsPlatform", "Windows/" },
  Win32 = { "D3D11RHI", "D3D12RHI", "VulkanRHI", "WindowsRHI", "WindowsPlatform", "Windows/" },
  Android = { "VulkanRHI", "OpenGLDrv", "AndroidRHI", "AndroidOpenGL", "AndroidVulkan", "Android/" },
  Mac = { "MetalRHI", "MacRHI", "MacPlatform", "Mac/", "Apple/" },
  IOS = { "MetalRHI", "IOSRHI", "IOSPlatform", "IOS/", "Apple/" },
  TVOS = { "MetalRHI", "TVOSPlatform", "TVOS/", "Apple/" },
  Linux = { "VulkanRHI", "LinuxRHI", "LinuxPlatform", "Linux/" },
  LinuxArm64 = { "VulkanRHI", "LinuxRHI", "LinuxPlatform", "Linux/" },
}

local M = {}

function M.for_target(target_id)
  return vim.deepcopy(HINTS[tostring(target_id or "")] or {})
end

return M
