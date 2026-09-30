# hana-alice/nvim 1.9.1 — 语义跳转正确性修复

> 日期：2026-09-09
> 类型：Patch
> Git tag：待显式授权；本轮未提交或打 tag。

## 版本摘要

修复六项独立复现的语义跳转问题：恢复 AST 的错误答案、跨模块目标缓存、失败的 module lookup 被回退覆盖、协议列编码、相对路径以及在途依赖版本。同步修正多上下文部分失败的聚合和非 C++ 缓存的编码传递。

## 验证与边界

- 最终全量回归：1535/1535，0 failed；包含真实 LLVM fixture 和编辑后保存用例。
- 真实 LLVM sidecar fixture 22/22，client 22/22；目标编码与协调器回归 13/13；兼容缓存多实例回归 19/19。
- 旧 smoke 97/97；Lua 静态检查 186 文件通过；spec 严格验证通过。
- 大型 UE 工程的实际导航延迟和 macOS/Linux 原生运行未在本轮复测。拒绝不完整 AST 会暴露原先被隐藏的编译上下文问题。
- 运行中的 Neovim 尚未重启或热加载这些改动。

## 归档工作记录

### 2026-09-09 — Reject unproven C++ navigation results and preserve exact destinations

**Task**
- Fix the six independently reproduced semantic-navigation review findings.

**Implemented**
- `semantic_sidecar_tu.lua` rejects error/fatal diagnostic ASTs and reparses failed TUs so newly available includes can restore correct overload resolution.
- `semantic_sidecar_definition.lua` binds cached destinations to the subject and refuses partial parse/shim evidence; `semantic_sidecar.lua` requires all selected contexts to resolve before reporting agreement.
- `semantic_sidecar_libclang.lua` resolves cursor and dependency paths against the compile directory.
- `semantic_navigation.lua` permits clangd assistance only for explicitly missing module contexts; `jumper.lua` converts protocol columns using the destination encoding.
- `cache.lua` preserves encoding and rejects ambiguous legacy entries; `csearch_fallback.lua` labels byte columns as UTF-8.
- `semantic_client_actions.lua` freezes action overlays and rejects results after dependency edits, saves or overlay-set changes, including initially clean loaded buffers edited and saved during a request.

**Pitfalls / Gotchas**
- Real LLVM tests require an explicit compatible `UE_CLANGD` when default discovery cannot find a matching libclang; skipped fixtures are not proof of semantic correctness.
- Incomplete ASTs and partial scans no longer establish unique targets; no new dependencies or fallback heuristics were introduced.

**Validation**
- Final `nvim --headless -l tests/run.lua` with a real compatible `UE_CLANGD`: 1535/1535, 0 failed, exit 0. This includes semantic context/client/sidecar, navigation/encoding, utils, platform boundaries, structure and legacy jumper coverage.
- `scripts/headless_smoke.lua`: 97/97; `scripts/lint_no_bare_globals.lua`: 186 files, OK; `git diff --check`: passed. No formatter dependency was installed; StyLua is unavailable on this host.
- Spec consistency: expanded `cpp-contextual-definition-navigation` with encoding, overlay freshness, failed-AST recovery, module cache boundaries, relative paths and incomplete-lookup scenarios; strict validation passed.

**Follow-ups**
- Native macOS/Linux execution, live UE navigation, commit and tag are outside this validation run.
