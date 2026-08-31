## 1. 假 ready 立即可证伪（先做：它是其余两条的判据基础）

- [x] 1.1 纯函数 `selection_is_self_evidencing(selection)`：要求非空
      `index_path` / `artifact_fingerprint` / `coverage_level`，且 `index_path` 文件存在。
- [x] 1.2 `semantic_index_snapshot` 在得出 `ready` 后应用该判据；矛盾则降级为非就绪 +
      可解释 reason（如 `ready-without-artifact-evidence`）。
- [x] 1.3 矛盾状态落 `utils.log`（可诊断），不得静默降级。
- [x] 1.4 用例：空 index_path / 空 fingerprint / 空 coverage / 文件不存在 → 全部非 ready；
      完整且文件存在 → ready。

## 2. manifest 随产物落盘（不再等全链路成功）

- [x] 2.1 把 manifest 写出从"全部成功"回调中提出：阶段的 controlled CDB + idx 产物存在即写。
- [x] 2.2 manifest 必须绑定 `generation_id` / `build_key` / `cdb_source_signature`。
- [x] 2.3 后续步骤（selection 提升 / clangd 重启 / 其他阶段）失败不得回滚已落盘 manifest。
- [ ] 2.4 用例：注入"产物已生成但提升失败" → 断言 manifest 已落盘且字段完整。

## 3. readiness 从磁盘 manifest 自愈

- [x] 3.1 纯函数：给定磁盘 manifest + 当前 generation/build_key/CDB 签名 → 判定
      `usable` / `stale` / `unusable`（fail closed）。
- [x] 3.2 `state` 账本缺失/类型错误/与磁盘不一致时，扫描该 tuple 的 manifest 重建 selection。
- [x] 3.3 重建后仍须通过第 1 条自证判据（不得用重建绕过 ready 门槛）。
- [x] 3.4 MUST NOT 因账本丢失提示重跑 UEPrepare。
- [x] 3.5 用例：账本为空 + manifest 匹配 → ready 且无 prepare 提示；
      manifest generation 不匹配 → stale；manifest 引用文件缺失 → 非就绪。

## 4. 行数门禁（不得抬高任何基线）

- [x] 4.1 `ue.lua` ≤ 10562；`_generation.lua` / `_build.lua` ≤ 800。
- [x] 4.2 超限时拆模块（候选 `lua/ue/index/_recover.lua`），不上调门禁。

## 5. 回归与验证纪律

- [x] 5.1 分范围：`index_generation` `cpp_semantic_index` `index_delivery` `clangd_commands`
      `ue_api` `stability`。
- [x] 5.2 提交前全量 `nvim --headless -l tests/run.lua`。
- [x] 5.3 **agent MUST NOT 启动真实 clangd 或触发真实索引构建**（上轮致用户机器卡死）；
      验证只用 fixture / 依赖注入。
- [ ] 5.4 为用户提供真实验收依据：看哪些文件、期望什么状态；不得要求用户执行额外命令。

## 6. 收尾

- [ ] 6.1 changelog 记一条，Validation 写明所跑范围与 spec 一致性处置。
- [ ] 6.2 sync specs → archive change。
- [ ] 6.3 明确记录**不在范围**的第四缺陷（indexer 自身失败：stats 长期 0、.idx 0 字节、
      旧 bucket 见 `exit 1` / `3221225477`），需单独立 change。

## 7. 事后更正（重要：我此前的诊断有误）

- [x] 7.1 **更正**：我先前断言"manifest 从未落盘"是**错的**。manifest 确实存在于
      `projects/<bucket>/clangd/<platform>/index/<project>.<phase>.idx.manifest.json`
      （14:37–14:38，1.4–2.3KB），我一直在错误的目录（`clangd/index/` 与
      `cdb/index/<platform>/compile_commands/`）下找，因此得出了错误结论。
- [x] 7.2 **更正**：`.idx` 文件 122–136 字节**不是残缺产物**，而是设计上的完成 marker
      （内容为 `{"schema":1,"index_kind":"controlled-background","entry_count":3445,...}`）。
      我此前把它当成"0 字节的坏索引"，也是错的。先前看到的 0 字节 `full.idx` 属于
      **legacy 路径** `clangd/index/`（7 月 24 日），与当前 tuple 无关。
- [x] 7.3 **更正**：当前 tuple 的账本**并未损坏**——`ledger_is_intact = true`，
      `index_selection` 完整（phase=full、coverage=full、fingerprint/index_path 均非空、
      freshness=fresh），且经真实 manifest 自比对 `classify = usable`，
      `selection_is_self_evidencing = true`，四个 readiness 条件对应的文件全部存在
      （index marker / background CDB / semantic CDB 20.2MB）。
- [x] 7.4 因此本 change 的三项修复**仍然正确且必要**（可证伪的 ready、manifest 随产物落盘、
      磁盘自愈），但它们**不是**用户当前 `gd` 仍失败的原因。真实原因尚未定位，
      需在用户真实会话中依据探针终态继续排查——**不得再由 agent 启动 clangd 复现**。
