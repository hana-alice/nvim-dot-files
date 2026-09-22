local t = require("tests.harness")
t.bootstrap()

local shards = require("ue.cdb.shards")
local fs = require("ue.core.fs")

local function bucket(platform, target, config, count)
  local entries = {}
  for index = 1, count do
    entries[index] = { file = index .. ".cpp" }
  end
  return {
    key = shards.shard_key(platform, target, config),
    platform = platform,
    target = target,
    config = config,
    entries = entries,
  }
end

local function buckets(...)
  local result = {}
  for _, value in ipairs({ ... }) do
    result[value.key] = value
  end
  return result
end

local state = { target_platform = "Android", target_configuration = "Development" }

t.describe("generated CDB bucket selection", function()
  t.it("breaks equal-count ties by key regardless of insertion order", function()
    local client = bucket("Android", "Client", "Development", 2)
    local engine = bucket("Android", "UE4", "Development", 2)
    t.assert_eq(shards.select_generated_bucket(buckets(client, engine), state), client)
    t.assert_eq(shards.select_generated_bucket(buckets(engine, client), state), client)
  end)

  t.it("chooses the largest matching tuple before a larger foreign tuple", function()
    local client = bucket("Android", "Client", "Development", 1)
    local engine = bucket("Android", "UE4", "Development", 3)
    local foreign = bucket("Win64", "Client", "Development", 8)
    t.assert_eq(shards.select_generated_bucket(buckets(client, engine, foreign), state), engine)
  end)

  t.it("explicit target and target_name beat persisted choice and entry counts", function()
    local client = bucket("Android", "Client", "Development", 1)
    local engine = bucket("Android", "UE4", "Development", 3)
    local values = buckets(client, engine)
    for _, explicit in ipairs({ { target = " Client ", target_name = "UE4" }, { target = " ", target_name = "Client" } }) do
      local selected = vim.tbl_extend("force", state, explicit)
      t.assert_eq(shards.select_generated_bucket(values, selected, engine.key), client)
    end
  end)

  t.it("preserves only a current matching persisted bucket", function()
    local client = bucket("Android", "Client", "Development", 1)
    local engine = bucket("Android", "UE4", "Development", 3)
    local foreign = bucket("Win64", "Client", "Development", 8)
    local shipping = bucket("Android", "Client", "Shipping", 9)
    local values = buckets(client, engine, foreign, shipping)
    t.assert_eq(shards.select_generated_bucket(values, state, client.key), client)
    for _, preferred in ipairs({ "Android-Removed-Development", foreign.key, shipping.key }) do
      t.assert_eq(shards.select_generated_bucket(values, state, preferred), engine)
    end
  end)

  t.it("keeps largest fallback deterministic when no platform/config matches", function()
    local first = bucket("IOS", "Client", "Development", 3)
    local second = bucket("Mac", "Client", "Development", 3)
    local small = bucket("Android", "Client", "Shipping", 1)
    t.assert_eq(shards.select_generated_bucket(buckets(second, first, small), state, small.key), first)
    t.assert_eq(shards.select_generated_bucket(buckets(small, first, second), state), first)
    t.assert_nil(shards.select_generated_bucket({}, state))
  end)
end)

t.describe("production response collection order", function()
  local function collector(lines)
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local parser = vim.treesitter.get_string_parser(source, "lua")
    local query = vim.treesitter.query.parse(
      "lua",
      [[
      (function_declaration name: (identifier) @name) @function
    ]]
    )
    for _, match in query:iter_matches(parser:parse()[1]:root(), source, 0, -1) do
      local name, declaration
      for id, nodes in pairs(match) do
        local node = type(nodes) == "table" and nodes[1] or nodes
        local text = vim.treesitter.get_node_text(node, source)
        if query.captures[id] == "name" then
          name = text
        else
          declaration = text
        end
      end
      if name == "collect_rsp_files" then
        local chunk = assert(loadstring(declaration .. "\nreturn collect_rsp_files", "@production-rsp-collection"))
        setfenv(
          chunk,
          setmetatable({
            trim = vim.trim,
            norm = fs.norm,
            join = fs.join,
            _ufs = fs,
            _uproc = {
              first_executable = function()
                return "fd"
              end,
            },
            run_lines = function()
              return 0, lines
            end,
          }, { __index = _G })
        )
        return chunk()
      end
    end
    error("production collect_rsp_files missing")
  end

  t.it("sorts accepted paths after filtering so fd order cannot change first-wins", function()
    local root = fs.norm(vim.fn.tempname())
    local build = root .. "/Engine/Intermediate/Build"
    vim.fn.mkdir(build, "p")
    local first = build .. "/Android/Client/Development/Core/Module.Core.1.cppa8.o.rsp"
    local second = build .. "/Android/Client/Development/Core/Module.Core.2.cppa8.o.rsp"
    local rejected = {
      build .. "/Win64/Client/Development/Core/Module.Core.cpp.obj.rsp",
      build .. "/Android/Client/Shipping/Core/Module.Core.cppa8.o.rsp",
      second .. ".old",
    }
    local ctx = { engine_root = root, state = state }
    local reversed = collector(vim.list_extend({ second, first }, rejected))(ctx)
    local forward = collector(vim.list_extend({ first, second }, rejected))(ctx)
    vim.fn.delete(root, "rf")
    t.assert_true(vim.deep_equal(reversed, { first, second }))
    t.assert_true(vim.deep_equal(forward, reversed))
  end)
end)
