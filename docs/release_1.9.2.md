# hana-alice/nvim 1.9.2 — 定义证据、诊断与请求调度

> 日期：2026-09-09
> 类型：Patch
> Git tag：待显式授权；本轮未提交或打 tag。

## 版本摘要

修复第二轮扫描确认的六项问题：聚合完整 compiler identities，区分声明和定义，拒绝无效目标，显示实际诊断，串行调度 sidecar 请求，并限制目标缓存大小。

## 验证与边界

- 最终全量回归：1547/1547，0 failed，退出码 0（明确指定真实 LLVM）。
- 指定真实 LLVM 后，导航与编码专项 22/22、client 24/24、sidecar 23/23；smoke 97/97；Lua 静态检查 186 文件通过。
- 无 body 的声明不再自动跳转并宣称成功；编译器报告多个 USR 的 dependent/alias/macro 位置明确拒绝首项猜测。
- 队列取消不强杀正在运行的解析；已发送请求仍受硬 deadline 保护。排队请求不消耗执行期限。
- 真实大 UE 项目的导航延迟与 macOS/Linux 原生运行未在本轮复测；当前编辑器实例未热加载改动。

## 归档工作记录

### 2026-09-09 — Complete source identity evidence and bound semantic work

**Task**
- Fix the six follow-up findings: symbol identity arrays, declaration-only answers, missing destinations, hidden diagnostics, queue deadlines and unbounded destination caching.

**Implemented**
- `provider.lua` aggregates every canonical identity and preserves declaration/definition evidence; `semantic_navigation.lua` requires definition role evidence and exposes bounded, redacted explanations.
- `jumper.lua` rejects unavailable targets, directories (including loaded directory buffers) and invalid arguments before modifying the source window or jumplist; loaded unsaved file buffers remain valid.
- `semantic_client_runtime.lua` serializes dispatch, starts deadlines only on send, and drops stale queued actions through `semantic_client_actions.lua`; restart startup failure drains callbacks instead of leaving a suspended queue.
- `semantic_sidecar_definition.lua` uses an independent destination LRU limit (default 128), exposed in sidecar metrics and configurable through `UE_SEMANTICD_MAX_LOOKUP_ENTRIES`.
- Added real clangd role/identity fixtures and regression coverage for Explain redaction, native queue ordering/restart/stop, invalid targets and destination LRU.
- Removed obsolete, duplicated readiness commentary from `semantic_navigation.lua`; the module remains within the existing 800-line gate without changing behavior or raising the limit.

**Pitfalls / Gotchas**
- `textDocument/definition` may return a declaration. Successful navigation now requires same-identity definition evidence, including non-function definitions such as types, fields and variables.
- Raw compiler messages may contain quoted POSIX/UNC paths; redaction must preserve useful standard diagnostic severity/message while removing private paths.
- Previously queued requests had no execution timer after serialization; restart failures must explicitly complete them.

**Validation**
- Final `nvim --headless -l tests/run.lua` with a real compatible `UE_CLANGD`: 1547/1547, 0 failed, exit 0. Targeted tests reproduced each reviewed defect before the repair.
- The first full run passed 1546/1547; the only failure was the navigation module's file-size gate. The obsolete-comment cleanup restored the limit, and the focused stability gate passed 10/10 before the final full rerun.
- `scripts/headless_smoke.lua`: 97/97; `scripts/lint_no_bare_globals.lua`: 186 files, OK; `git diff --check` passed.
- Spec consistency: expanded `cpp-contextual-definition-navigation`; strict validation passed. Architecture documentation now describes identity evidence, dispatch deadlines, detailed explanations and destination cache limits.

**Follow-ups**
- Native non-Windows runs, live UE performance, commit and tag are outside this validation run.
