## 1. 固定现状证据（先复现，避免再次误诊）

- [x] 1.1 记录：本次 `gd` **未产生** `cpp-semantic-navigation` 探针 → 走 catalog 路径，
      与先前修复的 `query` 终态分类无关。
- [x] 1.2 定位提示来源：`semantic_client_actions.lua` 的
      `vim.ui.select("Select proven translation-unit context")`，`format_item` 展示
      `item.label`（TU 文件名）——即用户所说的 "Module 选框"。
- [x] 1.3 定位 state 来源：`semantic_sidecar_catalog.lua` 仅按 `#wire` 数量决定
      `resolved`/`ambiguous-context`，未做任何收敛尝试。
- [ ] 1.4 补一条失败用例锁住当前错误行为（多候选且结果一致时仍提示）。

## 2. 自动收敛（核心）

- [x] 2.1 继承路径优先：已证明适用于该 subject 的 window origin lineage 直接使用（现已部分实现，
      需确认在多候选时不被跳过）。
- [x] 2.2 在候选 TU 中求值并比较 canonical USR + definition location；全部一致 → 直接跳转。
- [x] 2.3 收敛尝试范围设上界（不得为收敛无限扩大），保持异步、不阻塞 UI（P6）。
- [x] 2.4 MUST NOT 引入文件名/路径/顺序启发式（P11/P12）。

## 3. 提示门槛与展示

- [x] 3.1 仅在求值后确有不同实体/位置时才 `vim.ui.select`。
- [x] 3.2 展示改为包含实体与目标位置，不再只给 TU 文件名。
- [x] 3.3 无法收敛且无法证明分歧 → `unavailable` + 可执行 reason（不给 TU 列表）。

## 4. 回归

- [x] 4.1 用例：多候选且一致 → 直接跳转、无提示。
- [x] 4.2 用例：多候选且不一致 → ambiguous + 展示含实体信息。
- [x] 4.3 用例：无法收敛 → unavailable，且不呈现候选列表。
- [x] 4.4 用例：收敛判据不含文件名/路径启发式（扫描实现）。
- [x] 4.5 分范围 `cpp_semantic_client` `cpp_semantic_context` `cpp_semantic_sidecar`
      `ue_goto_behavior` `index_delivery`；提交前全量。
- [x] 4.6 **agent MUST NOT 启动真实 clangd / 索引构建验证**（沿用用户约束）。

## 5. 收尾

- [x] 5.1 门禁：`ue.lua` ≤10562；改动文件 ≤800 行。
- [ ] 5.2 changelog + spec 一致性处置。

## 6. 实现要点与关键发现

- [x] 6.1 **关键发现**：sidecar 的 `handle_query` **早就支持多 context**，并已用
      `by_identity` + `unique_definition_keys` 做收敛判定。客户端却一直只传
      `{ 单个 context }`，白白浪费该能力。所以本次修复**不是新增启发式**，
      而是让客户端真正使用编译器已具备的判定 —— 符合 C5「identity 由 canonical USR 决定」。
- [x] 6.2 收敛语义链（读实现确证）：N 个 context 都解析到同一 canonical identity 且同一
      definition → `#identities == 1` 且 `#unique_definition_keys == 1` → `state="resolved"`
      → 客户端直接跳转，**不弹任何选择框**。
- [x] 6.3 只有 `#unique_definition_keys > 1`（同 identity 多 definition）或
      `#resolved > 1`（多 identity）才返回 `ambiguous-context`，此时才提示，
      且选项展示 `TU → 目标文件:行`，不再只给 TU 文件名。
- [x] 6.4 sidecar 生命周期确认：经 `vim.fn.jobstart(progpath --headless -l script)` 启动，
      是 nvim 的子进程，**随 Neovim 退出而终止**，重启即加载新代码（上一轮"重启无效"是因为
      改动晚于会话启动，而非 sidecar 缓存）。
- [x] 6.5 收敛回调保留 stale 校验（`snapshot_is_current`）与 `note_origin`
      （成功后记住 proven TU，后续导航跳过 catalog 的扫描代价）。

## 7. 仍需真机确认（agent 不自行启动 clangd）

- [ ] 7.1 用户在真实会话验证：`VulkanResources.h:1167` 的 `WrapAroundAllocateMemory`
      `gd` 是否**直接跳到** `VulkanRHI.cpp:3594`。
- [ ] 7.2 若仍未跳转，预期会得到**明确 reason**（如 `target-is-current-declaration`
      或某个 provider/context reason）而**不再是 TU 选择框**；该 reason 指向下一层问题。
