# Verification evidence (sanitized)

Date: 2026-08-05

## Read-only active-workspace smoke

The smoke consumed the active Android Development CDB plus compiler-emitted
`.d/.o.rsp/unity` artifacts. It did not write engine or project sources. Stored
results intentionally contain only case labels, basename+line targets, truncated
USR hashes, timings, counts, and process memory.

| Case | Canonical USR hash | Semantic target | Result |
|---|---:|---|---|
| nested two-argument call (null) | `5d67a4354da68a7b` | `VulkanCommandBuffer.cpp:645` | resolved |
| nested two-argument call (address) | `5d67a4354da68a7b` | `VulkanCommandBuffer.cpp:645` | resolved |
| no-argument call | `65ed3e51ef6f4162` | `VulkanCommandBuffer.h:421` | resolved |

The two nested calls therefore resolve to the same compiler identity. The
no-argument call resolves to a different identity. Exit code was 0 and the smoke
reported `PASS` for all three cases.

## Performance observations

- Cold parse: 8,953 ms.
- Same-TU cursor queries: `warm`, reported below the integer-millisecond clock
  resolution; TU count remained 1 and no compiler process was spawned per query.
- Content-changing overlay reparse: 15,437 ms; canonical USR and target remained
  unchanged for the semantically identical edit.
- Exact rg prefilter over the normal broad active-build roots found one artifact;
  catalog construction took 1,998 ms and still parsed/verified the artifact before
  accepting provenance.
- Process RSS/working-set observations were not monotonic across warm queries:
  1.924 GB (cold), 2.427 GB (warm at another location), 2.189 GB (warm), 2.189 GB
  (repeat warm). Overlay reparse reached 2.888 GB.

The RSS data does **not** prove a missing TU disposal leak; it is process-wide and
includes libclang AST/preamble pages and allocator behavior. It does prove that a
single UE TU is large. The resulting guardrails are therefore evidence-based:
default live-TU capacity 1, 30-second idle eviction, explicit LRU/evict regression,
no repeated reparse when only document version changes, and no diagnostics payload
on successful queries. The high reparse working set remains a known cost, not a
claimed solved memory reduction.

## Automated evidence

- Real libclang fixtures cover no-arg, same-arity/different-type, default args,
  cv/ref, templates, ADL, inherited overloads, macro-dependent multiple contexts,
  invalid semantic contexts, changed overlays, LRU/eviction, and `.d/.rsp/unity`
  reconstruction.
- Request-token regression covers buffer contents, cursor, newer action token, and
  the move-away-then-back case.
- Source proof regression requires membership in the explicitly selected active
  shard and a merged clangd CDB that is not older than the shard/selection manifest.
  It deliberately gives the raw shard and merged CDB different argv, verifies that
  the post-processed merged command is used, and rejects a source absent from the
  active shard before carrying the proven context across a source-to-header jump.
- Live Neovim verification reproduced the original source call at
  `VulkanCommands.cpp:250`: `prove` returned `resolved`, and real `gd` landed at
  `VulkanCommandBuffer.h:421` without an unavailable notification.
- Process lifecycle regression stops the sidecar during startup with a queued
  request and proves that pending work drains without restarting the process.
- C++ `gd` regression asserts zero definition-cache, csearch, or GTAGS calls on both
  resolved and invalid compiler-identity paths.
