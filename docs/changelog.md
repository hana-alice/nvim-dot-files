# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)

## Unreleased

### 2026-08-27 — Keep clangd discovery retries callable after history reconciliation

**Task**

消除合入重写后的 origin 时由全量回归暴露的 `vim.defer_fn` 异步回调错误。

**Implemented**

- `clangd_resource_controller.discover_with_retry` 按 Neovim API 的 `(fn, timeout)` 顺序安排有界重试。
- 回归注入使用同一真实签名，避免测试 mock 反向固化实现错误。
- 既有 host-resource-discipline 可观察契约不变；这是实现对现有 spec 的一致性修复，无 delta spec。

**Pitfalls / Gotchas**

- 原全量统计仍显示全绿，但 `vim.wait` 期间的 scheduled callback 已打印 `fn: expected callable, got number`；
  只看最终 pass 计数会漏掉异步错误。

**Validation**

- 定向 `nvim --headless -l tests/run.lua clangd_resource`：10/10；全量回归：1324/1324，且不再出现
  scheduled callback 异常。
- 现有 host resource OpenSpec 契约未变化；本次只修正实现与测试替身的 Neovim API 调用顺序。

**Follow-ups**

- 无。
