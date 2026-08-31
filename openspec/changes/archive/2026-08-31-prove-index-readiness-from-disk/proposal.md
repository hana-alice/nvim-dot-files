## Why

**索引就绪状态只存在于一本易损的账本里，而 spec 要求的磁盘自证从未真正落盘。**
后果：账本一坏，261MB 的受控 CDB 就"不存在"，用户唯一的出路是重跑 388 秒的 `UEPrepare`。
用户直接质问「为什么还要 prepare？」—— 这个质问是对的。

### 缺陷 1：readiness 只信 `state`，不看磁盘证据

`semantic_index_snapshot`（`lua/ue/index/_generation.lua:601`）的判定链：

```lua
local selected  = state.index_selection                      -- 内存/单文件账本
local artifact  = state.index_artifacts[selected.phase]
if artifact.artifact_fingerprint ~= selected.artifact_fingerprint then artifact = nil end
```

它只读 `state`。而 `openspec/specs/cpp-semantic-index-coverage`
（Scenario: *Prepared tuple artifacts survive a Nvim restart*）明确要求：

> selection、**manifest**、controlled CDB、semantic CDB 与源 CDB 签名仍可证明为 ready 时，
> clangd SHALL 直接消费这些持久化工件
> **系统 MUST NOT 因新的 Lua 进程尚未执行 `UEPrepare` 而要求重复 prepare**

manifest（`<idx>.manifest.json`，含 `generation_id` / `build_key` / `cdb_source_signature`）
正是为此设计的磁盘自证。**但它从未落盘**：全机 `find -name "*manifest*"` 只有一个无关的
shards manifest。写 manifest 的代码（`_build.lua:606`）挂在"全链路成功"的回调里，
那条路径从未真正走完。

于是形成死循环：唯一真相在最易失的地方，而设计上本该存在的磁盘证据不存在。

实测现场（当前 tuple `Android-Test`）：

```
controlled CDB   full 261MB / hot 41MB / current 1MB   （14:38 真实产出）
manifest         不存在
stats            {full_runs:0, hot_runs:0, current_runs:0}   ← 一次成功都没记录
.idx             7 月 24 日的旧物，full.idx 为 0 字节
```

### 缺陷 2：`ready` 允许自相矛盾（假就绪）

我在 14:38 观察到 `verdict=ready`，但同一份 `index_selection` 里
`index_path=''`、`artifact_fingerprint=''`、`coverage_level=''`。

**这是一个可以自证矛盾却被放过的状态**：报 ready 却没有任何指向产物的证据。我据此误判
"索引已交付"，而真实的下游（idx 产出 / manifest 落盘）从未完成。假 ready 比诚实的
not-ready 有害得多 —— 它让"交付"这件事变得不可证伪，也是我上一轮误判的直接原因。

### 缺陷 3：交付是全有或全无，中途成果不留痕

manifest 写入、`stats` 递增、selection 提升全部挂在同一个"全部成功"回调里。任一环未走完
就什么都不留 —— 即使某个阶段的产物已经正确生成。这与 K41 要求 gate 消费**持久化** tuple
artifact readiness 直接冲突：产物在盘上，却没有任何自证它属于哪个 generation。

**Why now**：用户已按习惯链路走了多轮，每次都被要求重跑 prepare。根因不是索引过期，
而是**证据链断裂**：能自证的东西没写出来，写出来的东西不可信。

## What Changes

- **manifest 必须随产物落盘，而非等全链路成功**：任一阶段的 controlled CDB 与 idx 产物确实
  生成后，SHALL 立即写入绑定 `generation_id` / `build_key` / `cdb_source_signature` 的 manifest。
  manifest 是"这份产物属于哪个 build"的自证，不得依赖后续步骤是否成功。
- **readiness SHALL 可从磁盘证据重建**：`state` 账本缺失或损坏时，系统 SHALL 扫描该 tuple 的
  manifest，用 generation/build_key/CDB 签名校验后重建 selection，MUST NOT 因账本丢失而要求
  重跑 prepare。校验不通过时继续 defer（fail closed）。
- **`ready` SHALL 可证伪**：报 `ready` 时 selection MUST 携带非空 `index_path` /
  `artifact_fingerprint` / `coverage_level`，且对应文件存在。内部矛盾的 ready SHALL 降级为
  非就绪并可观测，MUST NOT 静默通过。

## Impact

- Specs: `cpp-semantic-index-coverage`（manifest 落盘时机、磁盘自愈、ready 自证）
- Code: `lua/ue/index/_build.lua`（manifest 落盘时机）、`lua/ue/index/_generation.lua`
  （readiness 自证与自愈）、可能新增 `lua/ue/index/_recover.lua`（若 `_generation` 触及 800 行上限）
- 回归: `index_generation` `cpp_semantic_index` `index_delivery` `clangd_commands` `ue_api`；
  跨 ue.lua 接缝 → 提交前全量
- **验证纪律（用户明确要求）**：
  - 本轮 MUST NOT 由 agent 启动真实 clangd 或触发真实索引构建 —— 上一轮如此操作导致用户机器
    卡死，且因脚本自身 bug 未换回任何信息。
  - agent 侧验证 SHALL 使用 fixture / 依赖注入的 headless 回归。
  - 真实端到端验收 SHALL 由用户在自身会话中沿习惯链路
    （set platform → set project → build → `:UEPrepare`）完成；agent SHALL 提供明确的判断依据
    （看哪些文件、期望什么状态）而非要求用户执行额外命令。
- 已知但**不在本 change 范围**：`stats` 长期为 0、`.idx` 为一月前 0 字节文件，提示
  clangd-indexer 那一步自身可能失败（旧 bucket 曾见 `exit 1` 与 indexer `3221225477`）。
  那是第四个独立缺陷，需单独立 change；本 change 只修证据链，不掩盖该失败 —— 相反，
  manifest 落盘与 ready 自证会让它更早暴露。
- 风险：`ue.lua` 处于单调下降 ratchet（10562），`_generation.lua` 已 770/800、
  `_build.lua` 728/800 —— 新增逻辑须评估是否拆分模块，不得抬高任何门禁。
