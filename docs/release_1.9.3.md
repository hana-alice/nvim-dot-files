# hana-alice/nvim 1.9.3 — 语义导航的模块归属与生命周期

> 日期：2026-09-09
> 类型：Patch（内部结构与正确性修复，保留公共命令和导航策略）
> Git tag：待显式授权；本轮未提交或打 tag。

## 版本摘要

修复架构审查的八项问题：导航与报告混合、环境读取隐式失效、transport/action 共享状态、
声明冒充 definition evidence、进度与终态重复归属、reload 未释放旧实例、native 组件相互安装、
宿主工具路径 hash 与实际编译器身份混淆。source/clangd 与 header/proven-TU 的证明流程保持独立。

## 归档工作记录

### 2026-09-09 — Give semantic evidence, editor actions and native resources explicit owners

**Task**
- Fix all confirmed architecture findings while preserving prior semantic repairs, references behavior and public commands.

**Implemented**
- Extracted `semantic_report.lua`, `lsp_transport.lua`, `clangd_adapter.lua` and `compat_navigation.lua`; `provider.lua` remains a stable forwarding API, and `lsp_fallback.lua` owns routing and commands.
- `semantic_navigation.lua` owns final freshness checks, progress, terminal reporting and lineage after successful jumps. Superseded actions cannot replace the newest Explain; disposed references callbacks cannot update quickfix or start GTAGS.
- `ui.lua` gives each progress handle its own native float, buffer and eight-second timer. Clear/finish and explicit reset never discover windows by title or text. `compat_navigation.lua` retains the new action's handle when an older callback completes.
- Extracted `semantic_environment.lua` for read-only snapshots and `semantic_session.lua` for actual handshake identity. `semantic_client.lua` composes separate action/transport state, performs environment invalidation and disposes old instances before reload.
- Tool path or file signature changes restart the sidecar; build-only changes evict caches. Every native response is associated with its actual compiler session; mismatched handshakes never become ready.
- `semantic_sidecar.lua` explicitly composes independent TU store, catalog and definition resolver objects. Each component cleans its own resources and receives dependencies explicitly.
- `semantic_protocol.lua` now distinguishes identity evidence from definition evidence: resolved query requires canonical USR and a valid location; resolved lookup requires canonical USR and an actual definition.
- Updated architecture/lifecycle regressions, including tests which previously inspected bodies in their old files. The warm-cache read spy now intercepts the new definition owner.

**Pitfalls / Gotchas**
- Compiler evidence is not a successful editor action; lineage must wait until the destination opens successfully.
- `package.loaded` eviction alone leaves old processes, queued restarts and asynchronous references callbacks alive.
- Architectural extraction invalidated old source-text assertions. Their replacement must retain behavioral guarantees rather than merely change expected spelling or skip failures.
- An action-owned cleanup callback did not prove window ownership: a final source check found `clear()` still swept all progress windows. Direct multi-window regression is required to verify the actual deletion scope.

**Validation**
- Final full regression with an explicit real LLVM `UE_CLANGD`: **1566/1566**, 0 failed, exit 0 (`nvim --headless -l tests/run.lua`).
- Targeted results: navigation including real clangd and owned-window checks 33/33; client 29/29; native sidecar 26/26; index delivery 88/88; UI responsiveness 20/20. Smoke 97/97; Lua static analysis 192 files, OK; structure 75/75; `git diff --check` passed.
- First full integration run: 1553/1561, 8 failures from assertions tied to old module ownership or pre-jump lineage timing. Replacing those assertions with the corresponding behavioral contracts produced 1561/1561 before the final progress-window ownership repair.
- Independent reviews covered native ownership/protocol, navigation/references and client/session lifecycle. They found the stale cache spy and references callbacks after disposal; both were corrected.
- Independent headless UI checks verified repeated clear/finish/reset safety, preservation of the newer window and zero residual nofile buffers. The dedicated notice regression covers actual windows, not mocked cleanup calls.
- Spec consistency: synchronized `cpp-contextual-definition-navigation`, architecture deep dive, overview and knowledge-base index; strict spec validation passed.

**Follow-ups**
- Live navigation/performance in a large UE checkout and native macOS/Linux execution are not covered by the Windows fixture run. The running editor has not been hot-reloaded by this change.
- Compiler replacement detection uses realpath, size and mtime (including nanoseconds), not full binary hashes; replacement preserving all those fields is not detected.
- No new dependencies. No commit, push or tag performed.
