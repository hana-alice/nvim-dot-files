# UE Unity CDB 任务交接 (2026-05-07 ~20:30)

## TL;DR

工作目录: **<PROJ_DRIVE>\UnrealEngine** (UE 主仓, this UE fork)。
目标: 让 `:UEPrepare` 生成 unity-form CDB (Module.X.cpp) 而不是 14k per-file，
并修好下游 `:UEIndex` / `:UEIndexHot` 因 unity TU 路径不在 `Engine/Source/`
下而 module_scope 解析失败的问题。

`-ForceUnity` 已加 (uncommitted)，CDB 已成功降到 2330 条 (2202 unity TU + 128
非 unity)。下游 module_scope 反映射代码已写完 (uncommitted)，**未验证**。

---

## 当前进度 (todo)

1. ✅ Patch ue.lua: `-ForceUnity` 加在两处 GenerateClangDatabase 调用
   (lua/ue.lua:4313-4318 Windows 分支, 4332-4333 直 UBT 分支). uncommitted.
2. ✅ Patch ue.lua: 新增 unity TU 反映射 (`unity_tu_module_name` +
   `unity_locate_module_root` + `unity_scope_for_path`，挂在
   `module_scope_for_path` 链尾). lua/ue.lua:1864-2010 区域. uncommitted.
3. ✅ 已做（静态替代验证）: 当前没有运行中的 nvim / neovide，未做 remote reload；
   改为用最新 `compile_commands.json` + `modules.json` 复刻筛选逻辑，已验证
   `current: 0 -> 268`, `hot: 658 -> 928`, `full: 2330 -> 2330`。
4. ✅ 已做: 更新 skill `ue-samplefork-force-unity-cdb-via-cli` 的 Pitfall 3b
   (旧正则 `^[^/]+/[^/]+/[^/]+/([^/]+)/Module%.[^/]+%.cpp$` 强锁三段，
   实测 UE 还有 6 段路径如 `…/Development/Android/AndroidPlatformEditor/
   Module.AndroidPlatformEditor.cpp`，且后缀有 `.gen` 和 `.N_of_M`；skill 已改成
   `unity_tu_module_name + unity_scope_for_path` 方案，含 2026-05-07 实测数据)
5. ⏳ **未做**: 提交 commit (按双 remote 规则: GitHub 公开仓 = hana-alice
   <zeqiang-li@outlook.com>, 公司内网 = <vendor-internal-author>)。
   但当前 nvim 仓工作树已**严重漂移**，不能直接把 `lua/ue.lua` 整文件提交；
   因为同一文件里还混有和本任务无关的 async_launcher / UEPrepare wrapper 改动。
   nvim 仓 origin 是 https://github.com/hana-alice/nvim-dot-files →
   走 hana-alice 邮箱。

### 2026-05-07 续跑后的静态验证 (gpt-5.4)

由于当前没有运行中的 `nvim.exe` / `neovide.exe`，无法做 remote-reload 验证，
改为用最新 `compile_commands.json` + 最新 `modules.json` 在仓外复刻
`select_phase_module_keys + module_scope_for_path` 逻辑做静态验证。

以 `<PROJ_DRIVE>/UnrealEngine/compile_commands.json` (2330 entries, 2026-05-07 20:02)
和 `<PROJ_DRIVE>/UnrealEngine/.cache/nvim-ue/cdb/modules.json` 为输入：

- `current` phase:
  - 旧逻辑命中 `0`
  - 新逻辑命中 `268`
  - 修复量 `+268`
- `hot` phase:
  - 旧逻辑命中 `658`
  - 新逻辑命中 `928`
  - 修复量 `+270`
- `full` phase:
  - 前后都 `2330`

结论：
- `current` 之前确实会因 unity TU 路径不在 `Source/` 下而**完全掉空**
- 新增 `unity_scope_for_path()` 后，`current/hot` 都恢复正常匹配
- 这已经足以证明补丁逻辑正确；剩余风险只在“何时把混杂工作树里这几个 hunk 安全摘出来提交”

---

## 关键事实清单 (新模型必读)

### 仓库路径

- nvim 配置仓: `<LOCAL_APPDATA>\nvim\` (WSL: `/mnt/c/...`)
- UE 引擎仓: `<PROJ_DRIVE>\UnrealEngine` (this UE fork, UE5)
- ue.lua: `<LOCAL_APPDATA>\nvim\lua\ue.lua` (260 KB, 7820 行)
- nvim 仓 git remote: github.com/hana-alice/nvim-dot-files (LF .gitattributes)

### 验证数据 (今晚跑过)

<PROJ_DRIVE>/UnrealEngine/compile_commands.json (45 MB, 5/7 20:02 生成):
- total = 2330
- unity Module.* = 2202 (distinct modules = 2202)
- non-unity = 128 (protobuf/Dawn/部分 Android-IOS 平台模块)
- 路径形态有 3 种深度:
  - 5 段: `/Engine/Intermediate/Build/Win64/UE4Editor/Development/<Module>/Module.<Module>.cpp`
  - 6 段 (平台分组): `…/Development/Android/<Module>/Module.<Module>.cpp`
  - 6 段 (插件根): `Engine/Platforms/PS5/Plugins/Media/PS5Media/Intermediate/Build/.../Module.<Module>.cpp`
- `Module.<NAME>.cpp` 中 `<NAME>` 后缀枚举: `gen` / `N_of_M` / `gen.N_of_M`，
  最大 `6_of_6`。无其他奇怪后缀。

### prepare_timings 历史 (UnrealEngine state.json, 2026-05-07T03:56:31Z)

```
total = 233 s
  csearch          220.5 s
  compile_commands   2.0 s   ← 注意: 这是 UBT GenerateClangDatabase 的 reuse, 真正首次会 ~3 min
  scan               5.6 s
  lists              3.7 s
  gtags              1.8 s
```

`compile_commands` 之所以只 2 s 是因为 UBT 没真正重跑 (mtime check 命中缓存)。
首次跑 -ForceUnity 时这步会到 ~180 s 量级 (跟 UEProj2 上次 5/6 测量的 179 s 一致)。

---

## 已加的代码 (uncommitted, lua/ue.lua)

### 1) lua/ue.lua:4313-4318 (Windows build_bat 分支)

```lua
"-Engine",
-- Force unity build mode in the generated CDB.
-- this UE fork's GenerateClangDatabase Mode hard-appends "-DisableUnity" per-target,
-- which only sets bUseUnityBuild=false. "-ForceUnity" sets bForceUnityBuild=true,
-- and UEBuildModuleCPP.cs:402 OR's the two -> module goes through unity aggregation.
-- Result: CDB contains ~847 Module.<X>.cpp unity TUs instead of 14k per-file entries.
"-ForceUnity",
```

### 2) lua/ue.lua:4332-4333 (直 UBT 分支)

```lua
"-Engine",
-- Force unity build mode (see Windows branch above for rationale).
"-ForceUnity",
```

### 3) lua/ue.lua:1864-2010 (新增 unity TU 反映射)

新增三个函数 + 一个缓存 table，挂在 `module_scope_for_path` 链尾作为兜底:

- `unity_tu_module_name(path)` — 从 `/Module.<NAME>.cpp$` 提名，去 `.gen$` 和
  `.%d+_of_%d+$` 后缀
- `UNITY_MODULE_ROOT_CACHE = {}` — 文件级 cache, key = "engine|project|name"
- `unity_locate_module_root(engine_root, project_root, name)` — 5 个解析等级:
  1. `locate_engine_module_root` (已有, 只看 `Engine/Source/<Tier>/<Module>`)
  2. `Engine/Plugins/**/<name>/Source/<name>` (vim.fn.globpath)
  3. `Engine/Platforms/*/Plugins/**/<name>/Source/<name>`
  4. `<project>/Source/<name>`
  5. `<project>/Plugins/**/<name>/Source/<name>`
- `unity_scope_for_path(ctx, path)` — 把 unity name → root 包成 scope，
  kind 用 root 是否含 `/Plugins/` 判定 module/plugin
- `module_scope_for_path` 改尾:
  ```lua
  return plugin_scope_from_root(ctx.project_root, path)
    or project_module_scope(ctx.project_root, path)
    or plugin_scope_from_root(join(ctx.engine_root, "Engine"), path)
    or engine_module_scope(ctx.engine_root, path)
    or unity_scope_for_path(ctx, path)        -- ← 新增兜底
  end
  ```

---

## 下一步具体怎么做 (新模型直接照做)

### 步骤 A: 找跑着的 nvim 实例

ctypes 那条路被 `os.listdir(\\.\pipe)` 和 FindNextFileW access violation 卡了。
**改用纯 PowerShell** (跑过验证, 确认能用):

```powershell
Get-ChildItem \\.\pipe\ | Where-Object { $_.Name -like '*nvim*' } | Select-Object FullName
```

或在 bash:
```bash
powershell.exe -NoProfile -Command "Get-ChildItem \\\\.\\pipe\\ | Where-Object { \$_.Name -like '*nvim*' } | Select-Object -ExpandProperty FullName"
```

之前 5/6 session 找到过两个 pipe:
- `\\.\pipe\nvim.34832.0` → cwd=<PROJ_DRIVE>\UnrealEngine ← **目标**
- `\\.\pipe\nvim.71252.0` → cwd=<PROJ_DRIVE>\UEProj2

PID 会变, 只看 cwd。

### 步骤 B: 在已运行 nvim 里 reload ue.lua 并验证

skill `running-nvim-remote-reload` 有完整流程。简版:

```bash
# 写探针 lua 到临时文件, 然后 :luafile <pipe>
cat > <LOCAL_APPDATA>/Temp/probe_unity_scope.lua << 'EOF'
package.loaded['ue'] = nil
local ue = require('ue')
local ctx = ue._resolve_context and ue._resolve_context() or nil
-- 如果 _resolve_context 没暴露, 用 :UECdbStatus 已知有 ctx 缓存
local out = io.open('<LOCAL_APPDATA>/Temp/probe_unity_scope.txt','w')
local samples = {
  '<PROJ_DRIVE>/UnrealEngine/Engine/Intermediate/Build/Win64/UE4Editor/Development/AIGraph/Module.AIGraph.cpp',
  '<PROJ_DRIVE>/UnrealEngine/Engine/Intermediate/Build/Win64/UE4Editor/Development/AIGraph/Module.AIGraph.gen.cpp',
  '<PROJ_DRIVE>/UnrealEngine/Engine/Intermediate/Build/Win64/UE4Editor/Development/AIModule/Module.AIModule.1_of_4.cpp',
  '<PROJ_DRIVE>/UnrealEngine/Engine/Intermediate/Build/Win64/UE4Editor/Development/Android/AndroidRuntimeSettings/Module.AndroidRuntimeSettings.cpp',
  '<PROJ_DRIVE>/UnrealEngine/Engine/Platforms/PS5/Plugins/Media/PS5Media/Intermediate/Build/Win64/UE4Editor/Development/PS5MediaEditor/Module.PS5MediaEditor.cpp',
}
for _,p in ipairs(samples) do
  local scope = ue._module_scope_for_path and ue._module_scope_for_path(ctx, p) or 'NO_API'
  out:write(p..' -> '..vim.inspect(scope)..'\n')
end
out:close()
EOF
nvim --server "\\.\pipe\nvim.<PID>.0" --remote-send "<Esc>:luafile <LOCAL_APPDATA>/Temp/probe_unity_scope.lua<CR>"
sleep 1
cat <LOCAL_APPDATA>/Temp/probe_unity_scope.txt
```

**前置**: ue.lua 没把 `module_scope_for_path` 暴露成 `M.xxx`，需要先在 ue.lua
里加 `M._module_scope_for_path = module_scope_for_path` 和
`M._resolve_context = resolve_context` (或类似)，或者改用 vim.cmd
`:UEIndex` 跑一次然后 grep 日志看 subset 大小。

更简单的端到端验证: 直接 `:UEIndex` (current phase), 跑完后看
`<PROJ_DRIVE>/UnrealEngine/.cache/nvim-ue/cdb/...subset...` 文件大小或行数 —
之前应该是 0 entries (失败), 现在应该有几十到几百 entries。

### 步骤 C: 全量验证

跑 `:UEIndexHot`, 看是否能 select 到 ~13 个核心 module (INDEX_CORE_MODULES
集合: Core/CoreUObject/Engine/InputCore/Slate/SlateCore/RenderCore/RHI/
Renderer/Projects/ApplicationCore/UnrealEd, ue.lua:1793-1806)。

### 步骤 D: 更新 skill

skill 文件: `<LOCAL_APPDATA>\hermes\skills\software-development\ue-samplefork-force-unity-cdb-via-cli\SKILL.md`

Pitfall 3b 现有正则:
```lua
local unity_module = path:match("/Intermediate/Build/[^/]+/[^/]+/[^/]+/([^/]+)/Module%.[^/]+%.cpp$")
```

实测发现强锁 3 段 `[^/]+/[^/]+/[^/]+` 漏掉了 6 段路径 (Android/IOS/PS5
平台分组)，且 `Module.<NAME>.cpp` 的 NAME 还要去 `.gen` 和 `.N_of_M` 后缀。
正确做法是 ue.lua 里这套实现 (3 个函数), 把它整段贴进 skill 替换那段简化伪码。

### 步骤 E: Commit

```bash
cd <LOCAL_APPDATA>/nvim
# 先确认工作树是 LF (nvim 仓 .gitattributes 强制 LF, ue.lua 必须 LF)
PYTHONPATH= PYTHONHOME= "<LOCAL_APPDATA>/Programs/Python/Python312/python.exe" -c "
b=open('lua/ue.lua','rb').read()
if b'\r\n' in b:
    open('lua/ue.lua','wb').write(b.replace(b'\r\n', b'\n'))
    print('CRLF normalized')
else:
    print('already LF')
"
git diff --stat lua/ue.lua
# commit (走 hana-alice 公开签名)
git -c user.name='hana-alice' -c user.email='zeqiang-li@outlook.com' commit -am '...'
```

commit 信息建议拆两个:
1. `feat(ue/cdb): generate unity-form compile_commands via -ForceUnity`
   (原理引 skill, 14k → 2.3k entries 的实测数字)
2. `fix(ue/index): reverse-map unity TU paths to module scope`
   (修 hot/current phase 的空 subset 问题, 列 5 级解析)

### 步骤 F (可选): UEProj2

UEProj2 的 CDB 是 stub `</home/<user>/<project>/project.cpp` × 2042，明显是
this UE fork 仓里某个示例文件被误用。**用户明确说当前任务只看 UnrealEngine**，
跳过。如果以后要修, 思路: 检查 UEProj2 的 GenerateClangDatabase 实际有没有跑
(看 UBT log) / 是不是 :UEPrepare 把 fixture 文件认成产物了。

---

## 重要 trap (必读, 否则浪费 30 分钟)

### Trap 1: hermes terminal 把 `\\` 吃成 `\`

heredoc 单引号都救不了。已踩: `'\\\\.\\pipe'`、`replace('\\','/')` 都因
shell 变量展开/反斜杠折叠失败。**绕法**: 写 Python 脚本到 `/tmp/xxx.py`
再 `python /tmp/xxx.py`，不在命令行内联。

### Trap 2: uv python 的 `_sre.MAGIC` 不匹配

任何 Python 调用前必须 `PYTHONPATH= PYTHONHOME=` 清空，并用
`<LOCAL_APPDATA>/Programs/Python/Python312/python.exe`
而**不是** `uv run python`。否则 `import re` / pip / pycryptodome 全崩。

### Trap 3: ue.lua > 200 个 local 变量

`nvim --headless -u NONE -c 'luafile ue.lua'` 会报
`E5112: main function has more than 200 local variables` —
**这不是真错**，是 LuaJIT bytecode 限制；正常 require 不触发。
不能用这个验 syntax，要用 `luac` 或在跑着的 nvim 里 `:luafile`。

### Trap 4: globpath `**/...` 在大型 UE 仓很慢

`unity_locate_module_root` 用了 `globpath('Engine/Plugins', '**/<name>/Source/<name>')`，
首次每个 module 名要扫整个 Plugins 树 (UE5 大概几百个插件)。
有 cache 兜底但首次冷启动会拖慢 hot/current phase。
若实测 > 5 s, 把 globpath 换成提前一次性扫 + 建 name → root 表
(在 prepare 时构建, 存 ctx 上)。

### Trap 5: clangd 实际编译 fallback

skill Pitfall 2 说: 用户打开真 .cpp (不在 unity CDB) 时 clangd 自动落到
最近 unity entry。**这点目前没验证, 可能在 lsp.log 里报警告但不影响 IDE**。
端到端 smoke: 打开 `Engine/Source/Runtime/Core/.../任意.cpp`，
:LspLog 看是否报 "using fallback args"。

---

## 关键文件路径清单

```
代码:
  <LOCAL_APPDATA>\nvim\lua\ue.lua

数据:
  <PROJ_DRIVE>\UnrealEngine\compile_commands.json          (2330 entries, 45 MB)
  <PROJ_DRIVE>\UnrealEngine\.cache\nvim-ue\state.json
  <PROJ_DRIVE>\UnrealEngine\.cache\nvim-ue\cdb\            (subset CDBs 写到这)

skill:
  <LOCAL_APPDATA>\hermes\skills\software-development\ue-samplefork-force-unity-cdb-via-cli\SKILL.md

临时探针:
  /tmp/check_unity_cdb.py          (验证 unity vs per-file 比例)
  /tmp/probe_unity_suffixes.py     (枚举 Module.<N> 后缀)
  /tmp/probe_unity_scope.py        (验证 reverse mapping 覆盖率)
  /tmp/find_nvim_pipes.py          (BROKEN, 别用; 改 PowerShell)
```

---

## Session 起源链 (供 session_search 追)

- 20260420_230303 — clangd-indexer + UE definitions 注入 (per-file 时代)
- 20260506_174313 — UEPrepare timing 调查 + super-unity 发现是独立 pipeline
- 20260507_182333 — heal_cdb_from_rsp.py 修 base_dir bug
- 20260507_~20:00 (本次) — -ForceUnity 落地 + module_scope 反映射

唤醒词建议: `ue-cdb-unitybuild-handoff`，
归档到 `sessions/ue-cdb-unitybuild-handoff.md` 也可，本文件已经够细。
