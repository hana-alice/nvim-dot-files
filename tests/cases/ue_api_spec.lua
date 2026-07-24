-- tests/cases/ue_api_spec.lua
-- ue 公共 API 冻结：PUBLIC_TABLES 非空 table、PUBLIC_FUNCTIONS 为 function。
-- 迁移自 scripts/headless_smoke.lua 的对应断言。

local t = require("tests.harness")
t.bootstrap()

local PUBLIC_TABLES = {
  "FT_CPP", "FT_SHADER", "FT_CODE", "FT_CONFIG", "FT_ALL",
  "FT_GTAGS", "GLOBS_CODE", "GLOBS_ALL",
}

local PUBLIC_FUNCTIONS = {
  "clangd_cmd", "clangd_root", "current_platform", "platform_path_priorities",
  "android_build_command", "picker_options", "picker_project_options",
  "current_scope_picker_options", "cached_grep_file_list", "cached_code_file_list",
  "cached_files", "cached_grep", "statusline_status", "index_status", "index_now",
  "index_hot", "index_full", "ue_roots", "gtags_rebuild_shaders",
  "gtags_references", "gtags_definition", "launch_app", "toggle_log",
  "toggle_debug_log", "prepare_headless", "ai_context",
}

t.describe("ue: 公共表冻结", function()
  local ue = require("ue")
  for _, k in ipairs(PUBLIC_TABLES) do
    t.it("ue." .. k .. " 是非空 table", function()
      local v = ue[k]
      t.assert_type(v, "table", "ue." .. k)
      t.assert_true(#v > 0, "ue." .. k .. " 应非空")
    end)
  end
end)

t.describe("ue: 公共函数冻结", function()
  local ue = require("ue")
  for _, fn in ipairs(PUBLIC_FUNCTIONS) do
    t.it("ue." .. fn .. " 是 function", function()
      t.assert_type(ue[fn], "function", "ue." .. fn)
    end)
  end
end)

t.describe("ue.clangd_cmd", function()
  local ue = require("ue")

  t.it("function-arg-placeholders 对 clangd 22 使用显式布尔值", function()
    local cmd = ue.clangd_cmd()
    local has_explicit = false
    local has_bare = false

    for _, arg in ipairs(cmd) do
      if arg == "--function-arg-placeholders=true" then
        has_explicit = true
      elseif arg == "--function-arg-placeholders" then
        has_bare = true
      end
    end

    t.assert_true(has_explicit, "clangd 22 需要 --function-arg-placeholders=true")
    t.assert_false(has_bare, "clangd 22 不接受裸 --function-arg-placeholders")
  end)
end)

-- ── .clangd 同步：engine + 引擎树外 project root 双写（2026-07-24）──────────
-- 根因回归：project 在 E:、engine 在 D: 时，clangd 从 E: 源文件向上找不到
-- D: 的 .clangd（无 Background: Skip）→ 对 CDB 里 ~半数的 project TU 全量
-- background-index（UEPrepare 后 CPU/RAM 爆炸、%LocalAppData%/clangd/index
-- 万级 shard）。sync_dot_clangd 必须在两个根都落 .clangd。
t.describe("ue.sync_dot_clangd（跨盘 project root 双写）", function()
  local ue = require("ue")

  local function tmp_root(name)
    local dir = vim.fn.tempname():gsub("\\", "/") .. "_" .. name
    vim.fn.mkdir(dir, "p")
    return dir
  end
  local function read_all_file(p)
    local f = io.open(p, "r"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
  end

  t.it("sync_one_dot_clangd 新建文件含 External.File/MountPoint + Background: Skip", function()
    local dir = tmp_root("one")
    local p = dir .. "/.clangd"
    local ok, msg = ue._sync_one_dot_clangd_for_test(p, [[D:\idx\a.idx]], [[D:\mount]])
    t.assert_true(ok, tostring(msg))
    local body = read_all_file(p) or ""
    t.assert_contains(body, [[File: D:\idx\a.idx]])
    t.assert_contains(body, [[MountPoint: D:\mount]])
    t.assert_contains(body, "Background: Skip")
    pcall(vim.fn.delete, dir, "rf")
  end)

  t.it("sync_one_dot_clangd 幂等：相同内容第二次返回 unchanged", function()
    local dir = tmp_root("idem")
    local p = dir .. "/.clangd"
    ue._sync_one_dot_clangd_for_test(p, [[D:\idx\a.idx]], [[D:\mount]])
    local ok, msg = ue._sync_one_dot_clangd_for_test(p, [[D:\idx\a.idx]], [[D:\mount]])
    t.assert_true(ok)
    t.assert_eq(msg, "unchanged", "重复同步不应改写文件（防 clangd 重载放大）")
    pcall(vim.fn.delete, dir, "rf")
  end)

  t.it("project 在引擎树外 → 两个根都落 .clangd，idx 同一文件、mount 各自根", function()
    local eroot = tmp_root("engine")
    local proot = tmp_root("project")
    local idx = eroot .. "/.cache/nvim-ue/clangd/index/x.idx"
    local ctx = { engine_root = eroot, project_root = proot,
      paths = { active_index = idx } }
    local ok = ue._sync_dot_clangd_for_test(ctx)
    t.assert_true(ok)
    local eng_body = read_all_file(eroot .. "/.clangd") or ""
    local prj_body = read_all_file(proot .. "/.clangd") or ""
    t.assert_true(eng_body ~= "", "engine root 应有 .clangd")
    t.assert_true(prj_body ~= "", "引擎树外 project root 也应有 .clangd（防 background-index 爆炸）")
    -- 同一 idx 文件
    local native_idx = idx:gsub("/", [[\]])
    t.assert_contains(eng_body, native_idx)
    t.assert_contains(prj_body, native_idx)
    -- mount 各自根
    t.assert_contains(prj_body, "MountPoint: " .. proot:gsub("/", [[\]]))
    t.assert_contains(prj_body, "Background: Skip")
    pcall(vim.fn.delete, eroot, "rf")
    pcall(vim.fn.delete, proot, "rf")
  end)

  t.it("project 在引擎树内 → 不额外写 project .clangd", function()
    local eroot = tmp_root("engnest")
    local proot = eroot .. "/Games/MyGame"
    vim.fn.mkdir(proot, "p")
    local ctx = { engine_root = eroot, project_root = proot,
      paths = { active_index = eroot .. "/x.idx" } }
    ue._sync_dot_clangd_for_test(ctx)
    t.assert_true(read_all_file(eroot .. "/.clangd") ~= nil)
    t.assert_nil((vim.uv or vim.loop).fs_stat(proot .. "/.clangd"),
      "树内 project 向上查找已命中 engine .clangd，不应重复落文件")
    pcall(vim.fn.delete, eroot, "rf")
  end)
end)
