"""Tier 1 SuperUnity absorption for clangd_pch_offline.

The background proof plan's ordinary Tier 1 groups are placed into the offline
paired input as their compiler-authored wrapper. The same private PCH clangd
run then decides the three proof gates (compile_success, main_shards_complete,
members_equal). Accepted groups are written as ordinary schema 1 Tier 1
receipts under the group's own store, keyed for the OFFICIAL reader clangd, so
the background proof's cache-only collect reuses them without re-indexing.
Rejected or uncertain groups write nothing reusable: their original UBT rows
stay in the published CDB for the official reader and later background proof.
"""
import concurrent.futures
import os
from pathlib import Path
import shutil

PREPARE_THREADS = 4
QUALIFIER = "private-pch-clangd"
ACCEPTED = "tier1-compile-shards-members-accepted"
_SPECIAL = ("packing", "fallback_of", "upgrade_of", "schedule_role", "recipe", "strict_recipe")


def norm(value):
    value = str(value).replace("\\", "/")
    return value.lower() if os.name == "nt" else value


def source_key(row):
    return norm(Path(row["directory"], row["file"]).resolve())


def _native(row):
    return {field: row.get(field) for field in ("directory", "file", "arguments")}


def _short(error):
    return str(error).split(":", 1)[0].strip()[:80] or type(error).__name__


def prepare(rows, plan_path, clangd, server_profile):
    """Return (rows with accepted/candidate wrappers substituted, state)."""
    import cdb_background_batch as bg
    verified = bg.verified
    state = dict(groups=[], skipped={}, plan_group_count=0)
    def skip(reason):
        state["skipped"][reason] = state["skipped"].get(reason, 0) + 1
    if verified.tier2_enabled() or bg._mode() != "1":
        raise ValueError("tier1-absorption-requires-tier1-mode")
    executable = Path(shutil.which(str(clangd)) or str(clangd))
    replace, dropped, used = {}, set(), set()
    with verified.tier1_overlay_scope(True):
        plan, entries = bg._load_plan(plan_path, server_profile)
        tool_hash = verified._tier1_blob_sha("tool", executable.read_bytes())
        profile = verified.normalize_server_profile(server_profile)
        environment = verified._compiler_environment(profile)
        state.update(tool_sha256=tool_hash, profile=profile, environment=environment,
                     plan_group_count=len(plan["groups"]))
        positions = {}
        for index, row in enumerate(rows):
            positions.setdefault(source_key(row), []).append(index)
        def evaluate(group):
            # One synchronous Tier 1 read view per group: the shared 7 MB owned
            # overlay is read once (and re-verified at exit) instead of per entry.
            with verified._tier1_overlay_read_view():
                return evaluate_group(group)
        def evaluate_group(group):
            if any(name in group for name in _SPECIAL):
                return "tier1-not-ordinary"
            try:
                _, selected = bg._group(plan, entries, group["id"])
                if len(selected) < 2 or not all(verified._is_ubt(entry) for entry in selected):
                    raise ValueError("tier1-not-ubt-batch")
                indexes = []
                for entry in selected:
                    hits = positions.get(source_key(entry), [])
                    if len(hits) != 1 or _native(rows[hits[0]]) != verified._native(entry):
                        raise ValueError("tier1-original-row-not-published")
                    indexes.append(hits[0])
                output = Path(group["store"]).resolve() / "tier1"
                inputs = verified._tier1_inputs(selected)
                candidate, body = verified._tier1_candidate_spec(selected, output / "assets")
                key = verified._tier1_cache_key(selected, candidate, tool_hash, profile, environment)
                cached, _ = verified._tier1_cached(selected, candidate, body, output, key, inputs,
                                                   tool_hash, profile, environment)
                if cached and not cached["accepted"]:
                    raise ValueError("tier1-cached-rejection")
                if not cached:
                    candidate = verified._tier1_candidate(selected, output / "assets")
                    members_equal, expected = verified._tier1_members_match(selected, candidate)
                    if not members_equal:
                        raise ValueError("tier1-membership-mismatch")
                else:
                    expected = [path for entry in selected for path in verified._tier1_ubt_members(entry)]
            except (OSError, ValueError, KeyError, TypeError) as error:
                return _short(error)
            return (group, selected, indexes, output, inputs, candidate, body, key, cached, expected)
        # Groups are independent and file-open bound (R50: ~35 s serial, 23.6 s
        # with 4 threads, identical state; 8+ threads slower). Results keep plan
        # order, so overlap resolution below is unchanged. The overlay policy
        # module is loaded lazily; load it once before threads share it.
        verified._owned_overlay_policy()
        with concurrent.futures.ThreadPoolExecutor(max_workers=PREPARE_THREADS) as pool:
            results = list(pool.map(evaluate, plan["groups"]))
        for result in results:
            if isinstance(result, str):
                skip(result)
                continue
            group, selected, indexes, output, inputs, candidate, body, key, cached, expected = result
            if used.intersection(indexes):
                skip("tier1-original-row-overlap")
                continue
            used.update(indexes)
            replace[min(indexes)] = verified._native(candidate)
            dropped.update(index for index in indexes if index != min(indexes))
            state["groups"].append(dict(id=group["id"], entries=selected, candidate=candidate, body=body,
                                        key=key, inputs=inputs, output=output, cached=bool(cached),
                                        expected=expected, wrapper=str(Path(candidate["file"]).resolve()),
                                        originals=[str(Path(e["directory"], e["file"]).resolve())
                                                   for e in selected],
                                        original_rows=[rows[index] for index in indexes]))
    substituted = [replace.get(index, row) for index, row in enumerate(rows) if index not in dropped]
    state["rows_substituted"] = len(rows) - len(substituted) + len(replace)
    return substituted, state


def judge(state, compile_failures, producer_failures, shard_owner, shards):
    """Decide gates from the finished private run.

    Returns (verdicts, shard names to withhold, {wrapper: TUs the reader indexes
    instead}). A cached acceptance stays authoritative (header edits
    intentionally do not invalidate Tier 1 receipts), so after a failed private
    run the reader indexes the wrapper itself; an unqualified group falls back
    to its original UBT rows.
    """
    failed, producer = ({norm(Path(p).resolve()) for p in values} for values in (compile_failures, producer_failures))
    verdicts, drop, fallback = {}, set(), {}
    for group in state["groups"]:
        wrapper = norm(group["wrapper"])
        gates = dict(compile_success=False, main_shards_complete=False, members_equal=True)
        missing = []
        if wrapper in producer:
            reason = "tier1-producer-failed"
        elif wrapper in failed or shard_owner.get(wrapper) not in shards:
            reason = "tier1-candidate-index-failed"
        else:
            gates["compile_success"] = True
            missing = [p for p in group["expected"] if shard_owner.get(norm(Path(p).resolve())) not in shards]
            if missing:
                reason = "tier1-main-shards-missing"
            else:
                gates["main_shards_complete"] = True
                reason = ACCEPTED
        passed = reason == ACCEPTED
        accepted = group["cached"] or passed
        verdicts[group["id"]] = dict(accepted=accepted, reason=reason, gates=gates, missing=len(missing))
        fallback[wrapper] = [group["wrapper"]] if accepted else list(group["originals"])
        if not passed:
            owned = [wrapper] + [norm(Path(p).resolve()) for p in group["expected"]]
            drop.update(shard_owner[path] for path in owned if path in shard_owner)
    return verdicts, drop, fallback


def retry_rows(state, verdicts):
    """Original UBT rows of wrappers that failed to compile, for an offline retry.

    Members that conflict inside one wrapper (R50: explicit specialization after
    instantiation, duplicate STAT symbols) compile as their own UBT rows, which
    the reader would otherwise rebuild without PCH. Cached acceptances keep the
    wrapper; other rejections keep the plain fallback.
    """
    return [row for group in (state["groups"] if state else [])
            if not verdicts[group["id"]]["accepted"]
            and verdicts[group["id"]]["reason"] == "tier1-candidate-index-failed"
            for row in group["original_rows"]]


def fallback_tus(state, verdicts, mapping, failures, covered=()):
    """Reader-visible TUs that the private run did not cover.

    covered: original rows an offline retry indexed cleanly (normalized paths).
    """
    result = set()
    for path in failures:
        result.update(mapping.get(norm(Path(path).resolve()), [path]))
    for group in state["groups"] if state else []:
        verdict = verdicts[group["id"]]
        if verdict["reason"] != ACCEPTED:
            result.update(mapping[norm(group["wrapper"])])
    covered = set(covered)
    return sorted(path for path in result if norm(Path(path).resolve()) not in covered)


def cached_report(state):
    """Report fields when the offline run is skipped (reuse/delta).

    Without a fresh private run nothing new is qualified; only groups whose
    current receipt prepare re-validated may be collected.
    """
    cached = [group["id"] for group in state["groups"] if group["cached"]]
    return dict(tier1_groups=len(state["groups"]), tier1_plan_groups=state["plan_group_count"],
                tier1_accepted_ids=cached, tier1_rejected={}, tier1_cache_hits=len(cached),
                tier1_unjudged=len(state["groups"]) - len(cached),
                tier1_rows_substituted=state.get("rows_substituted", 0), tier1_skipped=state["skipped"])


def commit(state, verdicts, private_sha):
    """Write reusable receipts for newly accepted groups; return report fields."""
    import cdb_background_batch as bg
    verified = bg.verified
    accepted, rejected, cache_hits = [], {}, 0
    with verified.tier1_overlay_scope(True):
        def write(group):
            verdict = verdicts[group["id"]]
            gates = dict(verdict["gates"])
            try:
                with verified._tier1_overlay_read_view():
                    verified._tier1_postcheck(group["entries"], group["candidate"], group["inputs"],
                                              state["environment"], state["profile"], gates)
                receipt = {"schema": 1, "tier": 1, "reusable": True, "cache_key": group["key"],
                           "accepted": True, "reason": ACCEPTED, "gates": gates, "inputs": group["inputs"],
                           "graph_result": None,
                           "compile_result": {"indexing_complete": True, "exit_code": 0,
                                              "compile_failure_count": 0, "shard_had_errors": False},
                           "original_entries": [verified._native(entry) for entry in group["entries"]],
                           "candidate": verified._native(group["candidate"]),
                           "candidate_sha256": verified._sha(group["body"].encode("utf-8")),
                           "members": group["candidate"].get("nvim_ue_members", []),
                           "tool_sha256": state["tool_sha256"], "server_profile": state["profile"],
                           "compiler_environment": state["environment"],
                           "qualified_by": {"tool": QUALIFIER, "sha256": private_sha}}
                verified._tier1_write_receipt(group["output"], receipt, {})
            except (OSError, ValueError, KeyError, TypeError) as error:
                return "tier1-receipt-unavailable: " + _short(error)
            return None
        # Each new receipt lives in its group's own store and its checks are
        # file-IO bound like prepare (R50 cold12: 36.6 s serial for 272 groups).
        # Results keep plan order, so the report is unchanged.
        fresh = [group for group in state["groups"]
                 if verdicts[group["id"]]["accepted"] and not group["cached"]]
        verified._owned_overlay_policy()
        with concurrent.futures.ThreadPoolExecutor(max_workers=PREPARE_THREADS) as pool:
            errors = dict(zip((group["id"] for group in fresh), pool.map(write, fresh)))
        for group in state["groups"]:
            verdict = verdicts[group["id"]]
            if verdict["accepted"] and group["cached"]:
                cache_hits += 1
                accepted.append(group["id"])
                continue
            if not verdict["accepted"]:
                rejected[group["id"]] = verdict["reason"]
                continue
            if errors[group["id"]]:
                rejected[group["id"]] = errors[group["id"]]
                continue
            accepted.append(group["id"])
    return dict(tier1_groups=len(state["groups"]), tier1_plan_groups=state["plan_group_count"],
                tier1_accepted_ids=accepted, tier1_rejected=rejected, tier1_cache_hits=cache_hits,
                tier1_rows_substituted=state.get("rows_substituted", 0), tier1_skipped=state["skipped"])
