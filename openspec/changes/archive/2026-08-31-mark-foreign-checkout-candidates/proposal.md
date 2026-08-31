## Why

**picker 会把其他 checkout 的同名文件混进候选，而两个 checkout 的目录结构完全一样，肉眼分不出来。**

用户实测（探针 `foreign-buffer`，08-26 16:45）：

```
key  = x:/work/checkout-old/source/game/module/private
data = { pinned = "X:/work/checkout-current" }
```

`pinned` 是当前 checkout（用户的设置正确），但被打开的 buffer 属于**旧 checkout**。
即**用户完全不知道自己打开了旧 checkout**。

### 为什么会认错

`shada` 的 oldfiles 里留着上个 checkout 的路径，而 `<leader><leader>`（smart picker）把 oldfiles
混进候选。两个 checkout 的相对路径**逐段相同**：

```
checkout-old/Source/Game/Module/Private/...
checkout-current/Source/Game/Module/Private/...
                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^ 完全一致
```

picker 通常按相对路径或文件名展示，区分两者的唯一信息只存在于 checkout 前缀。
在一屏候选里这不可能被稳定辨认 —— 这不是用户不小心，是界面没有提供可辨认的信息。

### 为什么后果比"打开错文件"严重

打开 foreign checkout 的 C++ 文件会连带一串**看起来像别的 bug** 的现象：

- active CDB 里没有该文件的编译命令 → clangd 用 fallback flags → 诊断噪声
- 没有 proven TU → C++ `gd` 报 `semantic-tu-unavailable`

用户 08-26 17:10 的探针正是 `semantic-tu-unavailable`（`generation_class=complete`：索引本身是
完整的）。**索引没问题、pin 没问题，只是这个 buffer 不属于该项目** —— 但从用户视角看就是
"gd 又坏了"。诊断成本极高：我自己也一度把它归因到语义层。

现有 `notify_foreign_buffer` 会警告，但（a）按目录 3 级去重、**每个目录只提示一次**，
（b）发生在**打开之后**。等价于"你已经掉进坑里了，顺便通知你一声"。

**Why now**：用户已因此误判过一次问题归属；且同一台机器上并存十余个同构 checkout，
复发概率很高。防线应当在**选择时**，而不是打开后。

## What Changes

- **picker 候选显式标注 foreign checkout**：当已 pin 项目时，来自 pin 项目/engine 之外的候选
  SHALL 带可见标记，使不同 checkout 的同名文件在一屏内可辨认。判定复用既有
  `CORE_RT.foreign_buffer_key`（同一份"是否属于当前项目"的谓词，不另写一套）。
- **默认可见但可降权/过滤**：默认 SHALL 保留这些候选（用户有时确实要跨 checkout 看代码），
  但 SHALL 提供配置将其降至列表末尾或完全过滤。MUST NOT 静默丢弃候选。
- **未 pin 项目时行为不变**：无 pin 即无"外部"概念，SHALL NOT 做任何标注或过滤。

## Impact

- Specs: `ue-code-search`（picker 候选的 checkout 归属可辨认性）
- Code: `lua/plugins/snacks.lua`（候选装饰/排序）；判定谓词从 `lua/ue.lua` 既有实现复用
- 回归: `ue_goto_behavior` `ue_paths` `utils` `smoke`；提交前全量
- **不在范围**：
  - 不改 `shada`/oldfiles 本身（那是 Neovim 的历史记录，跨 checkout 保留是合理的）
  - 不自动切换项目（项目选择是 manual-only，2026-07-14 决策）
  - 不改 `notify_foreign_buffer` 的打开后警告（它仍是最后一道防线）
- 风险：picker 装饰属热路径，装饰计算 MUST 廉价（字符串前缀比较，禁止 fs 调用），
  否则会违反 P6 —— 这正是 K17（projects picker 冻结数十秒）的教训。
