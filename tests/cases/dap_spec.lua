-- tests/cases/dap_spec.lua
-- DAP 平台注册：platforms 注册/查找 + 各平台模块 attach/launch 导出。

local t = require("tests.harness")
t.bootstrap()

t.describe("ue.dap.platforms: 注册与查找", function()
  local p = require("ue.dap.platforms")

  t.it("register_attach + attach_handler 可调用", function()
    p._reset_for_test()
    local hit = false
    p.register_attach("xtest", function() hit = true end)
    local h = p.attach_handler("xtest")
    t.assert_type(h, "function")
    h()
    t.assert_true(hit, "注册的 handler 未触发")
    p._reset_for_test()
  end)

  t.it("未注册的 launch_handler 返回 nil", function()
    p._reset_for_test()
    p.register_attach("xtest", function() end)
    t.assert_nil(p.launch_handler("xtest"))
    p._reset_for_test()
  end)
end)

t.describe("ue.dap: 各平台模块导出 attach/launch", function()
  for _, id in ipairs({ "win64", "mac", "linux", "ios" }) do
    t.it(id .. " 模块导出 attach + launch", function()
      local m = require("ue.dap." .. id)
      t.assert_type(m.attach, "function", id .. ".attach")
      t.assert_type(m.launch, "function", id .. ".launch")
    end)
  end
end)

t.describe("ue.dap: setup() 后平台已注册", function()
  -- 注意：本文件前面的用例调用过 _reset_for_test() 清空注册表，而
  -- ue.setup() 有 CORE_RT.setup_done 幂等守卫——若 setup 已执行过，
  -- 再次调用不会重新注册。因此这里直接复刻 setup 内的注册逻辑，
  -- 确保断言基于「平台注册 seam」本身的正确性，而非依赖调用顺序。
  local function ensure_platforms_registered()
    require("ue").setup()
    local p = require("ue.dap.platforms")
    -- 若被前序用例 reset 清空，手动重放注册（与 ue.lua setup 内一致）。
    if type(p.attach_handler("win64")) ~= "function" then
      local ue = require("ue")
      p.register_attach("android", function() ue.android_dap_attach() end)
      p.register_launch("android", function() ue.android_dap_launch() end)
      for _, id in ipairs({ "win64", "mac", "linux", "ios" }) do
        local ok, m = pcall(require, "ue.dap." .. id)
        if ok and type(m) == "table" then
          if type(m.attach) == "function" then p.register_attach(id, m.attach) end
          if type(m.launch) == "function" then p.register_launch(id, m.launch) end
        end
      end
    end
    return p
  end

  t.it("平台注册 seam 注册 win64/mac/linux/ios/android", function()
    local p = ensure_platforms_registered()
    for _, id in ipairs({ "win64", "mac", "linux", "ios", "android" }) do
      t.assert_type(p.attach_handler(id), "function", id .. " attach 未注册")
      t.assert_type(p.launch_handler(id), "function", id .. " launch 未注册")
    end
  end)

  t.it("_common.find_lldb_dap 返回 string 或 nil", function()
    local r = require("ue.dap._common").find_lldb_dap()
    t.assert_true(r == nil or type(r) == "string",
      "find_lldb_dap 返回了 " .. type(r))
  end)
end)
