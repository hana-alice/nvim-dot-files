## Why

**C++ `gd` 在头文件里把"我们没能缩小到唯一 TU"直接变成一个让用户挑 TU 的选择框，而且是在等待很久之后。**

用户实测（08-26 17:18 新会话，已装载全部先前修复）：

> gd 给几个提示之后好久才跳出 Module 选框，一样的

关键证据：**这次 `gd` 没有产生任何 `cpp-semantic-navigation` 探针记录**（最新仍是 17:10）。
说明它走的**不是** `query` 终态路径 —— 我先前修的 `summarize_unresolved` / `semantic_failure`
（`ambiguous-context` 误分类）与这条路径无关。真正的路径是 `catalog`：

```
lua/utils/ue_goto/semantic_client_actions.lua
  catalog_contexts → sidecar op="catalog"
  #contexts == 1              → dispatch（自动，不问）
  #contexts >  1              → vim.ui.select("Select proven translation-unit context")
                                 format_item = item.label = TU 文件名  ← 用户看到的 "Module 选框"
```

而 catalog 的 state 只按数量决定（`semantic_sidecar_catalog.lua`）：

```lua
local state = #wire == 0 and "unavailable"
  or (#wire == 1 and "resolved" or "ambiguous-context")
```

### 为什么这是缺陷而不是设计

非自包含头文件本来就会被**很多** TU include —— `VulkanResources.h` 被整个 VulkanRHI 模块的
TU 包含是正常现象，不是歧义。`>1 个候选 TU` 的含义是「**我们还没决定用哪个 TU 求值**」，
而不是「这个符号在不同 TU 里合法地指向不同实体」。

把前者呈现为选择框，等于**把系统本该自己完成的工作外包给用户**，而且用户没有任何依据做选择 ——
候选项是 TU 文件名（`VulkanRHI_3.cpp` 之类），与用户想跳转的 `WrapAroundAllocateMemory` 毫无
语义关联。用户连续多轮反馈"一样的"，正是因为无论选哪个都不解决问题。

C5 契约要求头文件"继承或选择 compiler-emitted dependency evidence 证明的 origin TU"，
`cpp-contextual-definition-navigation` 也要求 `ambiguous-context` 仅用于「同一位置在多个真实 TU
context 中**合法地解析为不同实体**」。当前实现两条都没做到：它在**求值之前**就按数量下结论，
从未尝试自动收敛。

### 为什么"好久"

`vim.ui.select` 之前会 `finish_progress(timer)`，也就是说提示是在 catalog 往返**完成之后**才弹。
catalog 需要扫描 dependency evidence 找出所有包含该头文件的 TU（用户在大型 UE 树上等到的就是
这段时间）。用户等了很久，换来的却是一个他无法判断的问题。

### 已排除的因素

- **不是"改动没装载"**：会话 17:18 启动，改动 16:50 落盘，且这次探针无新记录 —— 走的是另一条路径。
- **不是 foreign checkout**：本次会话没有新的 `foreign-buffer` 记录，用户在正确的 3.7 checkout 内。
- **不是缓存跨项目污染**（用户的第二个疑问）：已核对 `client.window_origin` 绑定
  `build_fingerprint` 且不匹配即失效；`state.window_contexts` 亦按 fingerprint 清理；
  持久缓存按 canonical project path 分桶（K43/C5b），`set_project` 走
  `invalidate_project_scoped_cache`。**这一层是对的，本 change 不动它。**

## What Changes

- **优先自动收敛，选择框成为最后手段**：多个候选 TU 时，系统 SHALL 先尝试用已有证据自动确定
  origin TU（继承的 window origin、subject 的 unity membership、以及在候选中求值后按 canonical
  USR 判断结果是否一致）。
- **结果一致即不打扰用户**：若多个候选 TU 求值后得到**同一** canonical USR / 同一 definition，
  SHALL 直接跳转，MUST NOT 提示选择 —— 这不是歧义。
- **仅在真实分歧时提示**：只有当候选 TU 求值后**确实得到不同实体**时才呈现选择，且提示 SHALL
  说明分歧所在（不同实体/位置），而不是只列 TU 文件名。
- **无法收敛时诚实失败**：既不能自动确定、也无法证明存在真实分歧时，SHALL 返回 `unavailable`
  并给出可执行原因，MUST NOT 用 TU 列表代替答案（P12）。

## Impact

- Specs: `cpp-contextual-definition-navigation`（catalog 阶段的收敛义务与提示门槛）
- Code: `lua/utils/ue_goto/semantic_client_actions.lua`（catalog → dispatch 决策）、
  `lua/utils/ue_goto/semantic_sidecar_catalog.lua`（state 不得只按数量下结论）
- 回归: `cpp_semantic_client` `cpp_semantic_context` `cpp_semantic_sidecar` `ue_goto_behavior`
  `index_delivery`；提交前全量
- **不在范围**：跨项目缓存隔离（已核对正确）、foreign checkout 标注（另有 change
  `mark-foreign-checkout-candidates`）、索引交付（`prove-index-readiness-from-disk`）
- 风险：
  - 在多个候选 TU 中求值会增加延迟 → 必须有上界（不得为收敛而无限扩大尝试范围），
    且 MUST 保持异步、不阻塞 UI（P6）。
  - MUST NOT 为"自动收敛"而按文件名/路径距离猜 TU —— 那是 P11/P12 明令禁止的启发式。
    收敛只能基于 compiler-emitted evidence 与 canonical USR 一致性。
