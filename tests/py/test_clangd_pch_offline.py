"""Deterministic offline-PCH command and receipt tests; no native compiler runs."""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import clangd_pch_offline as tool


def command(*extra, source="Source.cpp", directory="/workspace"):
    return {"directory": directory, "file": source,
            "arguments": ["clang++", "-std=c++20", *extra, "-c", source]}


class CommandTests(unittest.TestCase):
    def test_prefix_stops_at_shared_pch_and_preserves_prior_headers(self):
        row = command("-include", "Definitions.h", "-include", "include/SharedPCH.Engine.h",
                      "-include", "Module.h")
        self.assertEqual(tool.prefix_headers(row), ["Definitions.h", "include/SharedPCH.Engine.h"])
        self.assertEqual(tool.prefix_headers(command("-include", r"include\PCH.Core.h")),
                         [r"include\PCH.Core.h"])
        self.assertEqual(tool.prefix_headers(command("-include", "Ordinary.h")), [])
        self.assertEqual(tool.prefix_headers(command("-include")), [])

    def test_context_ignores_tu_module_search_dirs_and_output_flags(self):
        original = command("-DMode=1", "-include", "PCH.Core.h", "-include", "ModuleA.h",
                           "-I", "module/a", "-Ijoined", "-MF", "one.d", "-MD", "-o", "one.o")
        other = command("-DMode=1", "-include", "PCH.Core.h", "-include", "ModuleB.h",
                        "-I", "module/b", "-MFtwo.d", "-MMD", "-o", "two.o", source="Other.cpp")
        self.assertEqual(tool.context_key(original), tool.context_key(other))
        self.assertEqual(tool.context_key(command()), "no-pch")

    def test_context_preserves_macro_case_target_language_prefix_and_directory(self):
        base = command("-DMode=1", "-target", "aarch64-linux-android", "-x", "c++",
                       "-include", "Before.h", "-include", "PCH.Core.h")
        variants = []
        for before, after in (("-DMode=1", "-DMODE=1"), ("-DMode=1", "-DMode=2"),
                              ("aarch64-linux-android", "x86_64-linux-gnu"),
                              ("c++", "c"), ("Before.h", "Different.h")):
            row = copy.deepcopy(base)
            row["arguments"] = [after if item == before else item for item in row["arguments"]]
            variants.append(row)
        row = copy.deepcopy(base)
        row["directory"] = "/other-workspace"
        variants.append(row)
        for row in variants:
            with self.subTest(row=row):
                self.assertNotEqual(tool.context_key(base), tool.context_key(row))

    def test_context_binds_overlay_contents_and_preserves_prefix_order(self):
        a = command("-include", "First.h", "-include", "Second.h", "-include", "PCH.Core.h",
                    "-ivfsoverlay", "vfs.json")
        b = copy.deepcopy(a)
        b["arguments"][3], b["arguments"][5] = b["arguments"][5], b["arguments"][3]
        self.assertNotEqual(tool.context_key(a), tool.context_key(b))
        self.assertNotEqual(tool.context_key(a, {"vfs.json": "aaa"}),
                            tool.context_key(a, {"vfs.json": "bbb"}))

    def test_producer_preserves_semantics_and_replaces_only_pch_input_and_outputs(self):
        row = command("-x", "c++", "-DMode=1", "-I", "module", "-include", "Before.h",
                      "-include", "PCH.Core.h", "-include", "After.h", "-include-pch", "old.pch",
                      "-MD", "-MMD", "-MF", "old.d", "-MFjoined.d", "-o", "old.o", "--")
        before = copy.deepcopy(row)
        args = tool.producer_args(row, "new.pch", tool.prefix_headers(row), "private-clang++")
        self.assertEqual(args, ["private-clang++", "-std=c++20", "-x", "c++-header", "-DMode=1",
                               "-I", "module", "-include", "Before.h", "-fparse-all-comments",
                               "-fretain-comments-from-system-headers", "-fno-pch-instantiate-templates",
                               "PCH.Core.h", "-o", "new.pch"])
        self.assertEqual(row, before)

    def test_driver_query_extracts_only_relevant_driver_settings(self):
        row = command("-I", "module", "-DLocal=1", "--sysroot=/sdk", "-isysroot", "/apple",
                      "--target=aarch64-linux-android", "-stdlib=libc++", "-nostdinc++",
                      "--no-standard-includes", "-specs=first", "--specs", "second",
                      "-x", "objective-c++-header")
        self.assertEqual(tool.driver_query_args(row),
                         ["clang++", "-E", "-v", "-x", "c++-header", "-nostdinc++", "-nostdinc",
                          "--sysroot", "/sdk", "-isysroot", "/apple", "-target", "aarch64-linux-android",
                          "--stdlib", "libc++", "-specs=first", "--specs", "second", "-"])

    def test_driver_query_handles_language_inference_joined_flags_and_last_value(self):
        self.assertEqual(tool.driver_query_args(command(source="source.c"))[4], "c")
        row = command("-xc++", "-isysroot/sdk", "-target", "old", "--target", "new", "-nostdinc")
        self.assertEqual(tool.driver_query_args(row),
                         ["clang++", "-E", "-v", "-x", "c++", "-nostdinc", "-isysroot", "/sdk",
                          "-target", "new", "-"])

    def test_parse_driver_output_requires_complete_search_and_excludes_builtin(self):
        output = ("Target: aarch64-linux-android\nnoise\n#include <...> search starts here:\n"
                  " /sdk/system\n /compiler/builtin\n /sdk/c++\nEnd of search list.\nignored\n")
        self.assertEqual(tool.parse_driver_output(output, " /compiler/builtin\n"),
                         {"target": "aarch64-linux-android", "includes": ["/sdk/system", "/sdk/c++"]})
        self.assertEqual(tool.parse_driver_output("#include <...> search starts here:\nEnd of search list.", ""),
                         {"target": "", "includes": []})
        with self.assertRaisesRegex(ValueError, "complete system include list"):
            tool.parse_driver_output("#include <...> search starts here:\n /sdk", "")

    def test_manifest_adds_driver_environment_and_keeps_original_untouched(self):
        row = command("-DMode=1", "--")
        row["output"] = "original.o"
        before = copy.deepcopy(row)
        result = tool.manifest_command(row, {"includes": ["/sdk/include"], "target": "aarch64"}, "/resource")
        self.assertEqual(result["arguments"],
                         ["clang++", "--driver-mode=g++", "-std=c++20", "-DMode=1", "-c",
                          "-isystem", "/sdk/include", "--target=aarch64", "-resource-dir=/resource",
                          "--", os.path.normpath("/workspace/Source.cpp")])
        self.assertEqual(result["output"], "original.o")
        self.assertEqual(result["heuristic"], "")
        self.assertEqual(row, before)

    def test_manifest_preserves_explicit_target_resource_and_driver_mode(self):
        row = command("--driver-mode=g++", "-target", "custom", "-resource-dir", "/custom")
        result = tool.manifest_command(row, {"includes": [], "target": "default"}, "/resource")
        self.assertEqual(result["arguments"].count("--driver-mode=g++"), 1)
        self.assertNotIn("--target=default", result["arguments"])
        self.assertNotIn("-resource-dir=/resource", result["arguments"])

    def test_manifest_rejects_response_files_ambiguous_main_file_and_unsupported_driver(self):
        for row in (command("@flags.rsp"), command("Source.cpp"),
                    {"directory": "/workspace", "file": "Source.cpp", "arguments": ["clang-cl", "Source.cpp"]}):
            with self.subTest(row=row), self.assertRaises(ValueError):
                tool.manifest_command(row, {"includes": [], "target": ""}, "/resource")

    def test_log_counts_records_unique_failed_tus_and_manifest_statuses(self):
        lines = ["manifest selection for /a.cpp: paired (context)",
                 "manifest selection for /b.cpp: fallback (command-mismatch)",
                 "manifest selection for /c.cpp: fallback (unlisted)",
                 "unrelated paired (ignored)",
                 "I[12:00] Failed to compile C:/path with spaces/a,b.cc, index may be incomplete",
                 "I[12:01] Failed to compile C:/path with spaces/a,b.cc, index may be incomplete",
                 "I[12:02] Failed to compile /b.cpp, index may be incomplete"]
        self.assertEqual(tool.log_counts(lines),
                         {"paired": 1, "mismatch": 1, "unlisted": 1, "compile_failure_count": 2,
                          "compile_failure_tus": ["C:/path with spaces/a,b.cc", "/b.cpp"]})
        self.assertEqual(tool.log_counts([])["compile_failure_tus"], [])

    def test_dependency_scan_replaces_pch_output_with_preprocess_listing(self):
        producer = ["clang++", "-x", "c++-header", "PCH.Core.h", "-o", "out.pch"]
        self.assertEqual(tool.dependency_scan_args(producer), ["clang++", "-x", "c++-header", "PCH.Core.h", "-M", "-MG"])
        with self.assertRaises(ValueError):
            tool.dependency_scan_args(["clang++", "PCH.Core.h"])

    def test_parse_depfile_handles_drive_letters_escapes_and_continuations(self):
        text = ("PCH.Core.o: D:\\Engine\\PCH.Core.h \\\r\n  D:\\Engine\\My\\ Dir\\A.h rel/B.h \\\n"
                "  C:/x/$$cash.h\n")
        self.assertEqual(tool.parse_depfile(text, "/work"), [
            os.path.normpath("D:\\Engine\\PCH.Core.h"), os.path.normpath("D:\\Engine\\My Dir\\A.h"),
            os.path.normpath("/work/rel/B.h"), os.path.normpath("C:/x/$cash.h")])
        self.assertEqual(tool.parse_depfile("", "/work"), [])

    def test_production_jobs_accept_more_than_two_and_reject_nonpositive(self):
        for value in ("1", "2", "8", "24"):
            self.assertEqual(tool.positive_jobs(value), int(value))
        for value in ("0", "-1"):
            with self.assertRaises(argparse.ArgumentTypeError):
                tool.positive_jobs(value)

    def test_process_memory_cap_is_configurable_and_defaults_to_16_gib(self):
        # R47c: one paired clangd -j12 over the full CDB peaks at 9.6 GB.
        for limit in (None, 8 << 30):
            resources = tool.Resources() if limit is None else tool.Resources(limit)
            resources.stop.set()
            self.assertEqual(resources.process_limit, limit or 16 << 30)


class IndexOrderTests(unittest.TestCase):
    def test_order_is_longest_first_by_nested_unity_members(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ("a.cpp", "b.cpp", "c.cpp", "plain.cpp"):
                (root / name).write_text("int x;\n", encoding="utf-8")
            (root / "SuperUnity.UBT.small.cpp").write_text('#include "a.cpp"\n', encoding="utf-8")
            (root / "SuperUnity.UBT.big.cpp").write_text('#include "b.cpp"\n#include "c.cpp"\n',
                                                         encoding="utf-8")
            (root / "wrapper.cpp").write_text(
                '#include "SuperUnity.UBT.small.cpp"\n#include "SuperUnity.UBT.big.cpp"\n', encoding="utf-8")
            self.assertEqual(tool.tu_cost(root / "wrapper.cpp"), 3)
            self.assertEqual(tool.tu_cost(root / "plain.cpp"), 1)
            self.assertEqual(tool.tu_cost(root / "missing.cpp"), 1)
            rows = [{"directory": str(root), "file": name, "arguments": []}
                    for name in ("plain.cpp", "SuperUnity.UBT.small.cpp", "wrapper.cpp", "SuperUnity.UBT.big.cpp")]
            order = tool.write_index_order(root, rows).read_text(encoding="utf-8").split()
            self.assertEqual([Path(p).name for p in order],
                             ["wrapper.cpp", "SuperUnity.UBT.big.cpp", "SuperUnity.UBT.small.cpp", "plain.cpp"])
            # The cheapest TU of each PCH context seeds its prefix shards first.
            seeded = tool.write_index_order(root, rows, ["a", "b", "a", "b"]).read_text(encoding="utf-8").split()
            self.assertEqual([Path(p).name for p in seeded],
                             ["SuperUnity.UBT.small.cpp", "plain.cpp", "wrapper.cpp", "SuperUnity.UBT.big.cpp"])


class ReceiptTests(unittest.TestCase):
    """Two-tier drift plan: reuse / delta (reader rebuilds stale shards) / full rerun."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pch_offline_receipt_")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.target = self.root / "index"
        self.target.mkdir()
        self.header = self.root / "Shared.h"
        self.private = self.root / "Private.h"
        for p in (self.header, self.private):
            p.write_text("int x;\n", encoding="utf-8")
        self.sources = [self.root / ("Tu%d.cpp" % i) for i in range(4)]
        for p in self.sources:
            p.write_text('#include "Shared.h"\n', encoding="utf-8")
        self.shard = self.target / "Tu0.cpp.idx"
        self.shard.write_bytes(b"valid-published-shard")
        self.report = {"ok": True, "skipped": False, "shards": 1, "fallback_count": 0}
        self.rows = {tool.norm(p): {"command": "c"} for p in self.sources}
        graph = {tool.norm(p): [tool.norm(self.header)] for p in self.sources}
        graph[tool.norm(self.sources[0])].append(tool.norm(self.private))
        self.receipt = {"version": 2, "identity": "id", "report": self.report, "graph": graph,
                        "rows": {k: dict(v, roots=[k]) for k, v in self.rows.items()},
                        "dependencies": {str(p): tool.path_stamp(p)
                                         for p in (self.header, self.private, *self.sources)},
                        "shards": {self.shard.name: tool.path_stamp(self.shard)}}

    def plan(self, rows=None, identity="id", threshold=0.5, receipt=None):
        return tool.drift_plan(self.receipt if receipt is None else receipt, identity, self.rows if rows is None else rows, self.target, threshold)

    def test_unchanged_inputs_reuse_previous_partial_report(self):
        mode, _, report = self.plan()
        self.assertEqual(mode, "reuse")
        self.assertEqual(report, dict(self.report, skipped=True, mode="reuse"))

    def test_small_drift_leaves_stale_shards_to_reader(self):
        self.private.write_text("int changed_private_header;\n", encoding="utf-8")
        mode, _, report = self.plan()
        self.assertEqual((mode, report["delta_affected_tus"], report["delta_changed_files"]), ("delta", 1, 1))

    def test_shared_header_drift_above_threshold_reruns_in_full(self):
        self.header.write_text("int changed_shared_header;\n", encoding="utf-8")
        mode, reason, report = self.plan()
        self.assertEqual((mode, report), ("full", None))
        self.assertIn("drift", reason)
        self.assertEqual(self.plan(threshold=1.0)[0], "delta")

    def test_command_changes_and_new_rows_count_as_affected(self):
        rows = dict(self.rows)
        rows[tool.norm(self.sources[1])] = {"command": "other"}
        self.assertEqual(self.plan(rows)[0], "delta")
        rows[tool.norm(self.root / "New1.cpp")] = {"command": "c"}
        rows[tool.norm(self.root / "New2.cpp")] = {"command": "c"}
        rows[tool.norm(self.root / "New3.cpp")] = {"command": "c"}
        self.assertEqual(self.plan(rows)[0], "full")

    def test_missing_published_shards_count_as_drift(self):
        self.shard.unlink()
        self.assertEqual(self.plan()[0], "full")

    def test_identity_change_and_corrupt_receipts_fail_closed_to_full(self):
        self.assertEqual(self.plan(identity="new-private-binary")[:2], ("full", "identity"))
        for receipt in ({}, {"identity": "id"}, {"identity": "id", "rows": None, "graph": {}}):
            self.assertEqual(self.plan(receipt=receipt)[0], "full")

    def test_first_error_reports_first_diagnostic_line(self):
        text = "\n".join(["In file included from a.h:1:",
                          "D:/e/Logs.h(11,12): error: redefinition of 'X'", "note: here", ""])
        self.assertEqual(tool.first_error(text), "D:/e/Logs.h(11,12): error: redefinition of 'X'")
        self.assertEqual(tool.first_error("warning: only"), "")

    def test_clean_tu_reaching_rejected_header_shard_falls_back(self):
        edges = {"a.cpp": {"x.h"}, "x.h": {"bad.h"}, "b.cpp": {"y.h"}, "y.h": {"x.h"}, "c.cpp": {"z.h"}}
        self.assertEqual(tool.reaching_sources(edges, ["a.cpp", "b.cpp", "c.cpp"], {"bad.h"}), ["a.cpp", "b.cpp"])
        self.assertEqual(tool.reaching_sources({"a.cpp": {"a.cpp"}}, ["a.cpp"], set()), [])

    def test_reverse_walk_reaches_through_includes_and_failed_contexts(self):
        edges = {"a.cpp": ["mid.h"], "mid.h": ["leaf.h"], "context:k": ["pch.h"], "b.cpp": []}
        roots = {"a": {"roots": ["a.cpp"]}, "b": {"roots": ["b.cpp", "context:k"]}}
        self.assertEqual(tool.affected_rows(edges, roots, {"leaf.h"}), {"a"})
        self.assertEqual(tool.affected_rows(edges, roots, {"pch.h"}), {"b"})
        self.assertEqual(tool.affected_rows(edges, roots, {"unrelated.h"}), set())


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pch_offline_publish_")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "new.idx"
        self.source.write_bytes(b"offline-shard")
        self.destination = self.root / "A.idx"

    def leftovers(self):
        return [p.name for p in self.root.iterdir() if ".new-" in p.name]

    def test_publish_replaces_and_skips_identical(self):
        self.destination.write_bytes(b"older")
        self.assertTrue(tool.publish_shard(self.source, self.destination))
        self.assertEqual(self.destination.read_bytes(), b"offline-shard")
        stamp = tool.path_stamp(self.destination)
        self.assertTrue(tool.publish_shard(self.source, self.destination))
        self.assertEqual(tool.path_stamp(self.destination), stamp)
        self.assertEqual(self.leftovers(), [])

    @unittest.skipUnless(os.name == "nt", "Windows sharing violation semantics")
    def test_reader_held_destination_is_reported_not_raised(self):
        self.destination.write_bytes(b"reader-copy")
        with open(self.destination, "rb"):
            self.assertFalse(tool.publish_shard(self.source, self.destination, attempts=2, delay=0.01))
        self.assertEqual(self.destination.read_bytes(), b"reader-copy")
        self.assertEqual(self.leftovers(), [])


class WriterLockTests(unittest.TestCase):
    def child_command(self, lock, *extra):
        script = ("import os, pathlib, sys, time\n"
                  "sys.path.insert(0, sys.argv[1])\n"
                  "import clangd_pch_offline as tool\n"
                  "try:\n"
                  "    descriptor = tool.acquire_writer_lock(sys.argv[2])\n"
                  "except RuntimeError:\n"
                  "    sys.exit(7)\n"
                  "if len(sys.argv) > 3:\n"
                  "    pathlib.Path(sys.argv[3]).write_text('locked', encoding='utf-8')\n"
                  "    time.sleep(30)\n"
                  "os.close(descriptor)\n")
        return [sys.executable, "-B", "-I", "-c", script, str(Path(tool.__file__).parent), str(lock), *extra]

    def test_real_python_process_cannot_enter_held_lock(self):
        with tempfile.TemporaryDirectory(prefix="pch_writer_lock_") as temporary:
            lock = Path(temporary) / "writer.lock"
            descriptor = tool.acquire_writer_lock(lock)
            try:
                result = subprocess.run(self.child_command(lock), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 7, result.stderr)
            finally:
                os.close(descriptor)
            self.assertTrue(lock.is_file(), "lock inode must survive unlock")
            result = subprocess.run(self.child_command(lock), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_killed_python_owner_releases_lock_without_finally(self):
        with tempfile.TemporaryDirectory(prefix="pch_writer_exit_") as temporary:
            lock = Path(temporary) / "writer.lock"
            ready = Path(temporary) / "ready"
            child = subprocess.Popen(self.child_command(lock, str(ready)), stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists(), "Python owner did not acquire its lock")
                child.kill()
                child.communicate(timeout=10)
                descriptor = tool.acquire_writer_lock(lock)
                os.close(descriptor)
                self.assertTrue(lock.is_file(), "owner exit must not unlink lock inode")
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=10)


class Tier1Tests(unittest.TestCase):
    """Absorbed Tier 1 groups: substitution, gate verdicts and reusable receipts."""

    def setUp(self):
        import cdb_background_batch as bg
        import pch_offline_tier1 as tier1
        self.bg, self.tier1, self.verified = bg, tier1, bg.verified
        self.env = {name: os.environ.pop(name, None) for name in ("NVIM_UE_BATCH_TIER", "NVIM_UE_TIER2")}
        self.temp = tempfile.TemporaryDirectory(prefix="pch_tier1_")
        root = self.root = Path(self.temp.name).resolve()
        source = root / "Source"
        source.mkdir()
        (source / "Shared.h").write_text("#define V 1\n", encoding="utf-8")
        self.members = []
        for name in ("alpha", "beta", "gamma", "delta"):
            member = source / (name + ".cpp")
            member.write_text('#include "Shared.h"\nint %s() { return V; }\n' % name, encoding="utf-8")
            self.members.append(member)
        self.clangd = sys.executable  # identity bytes only; never launched here
        entries = []
        for index, member in enumerate(self.members):
            wrapper = source / ("SuperUnity.UBT.%d.cpp" % index)
            wrapper.write_text("// Compiler-authored UBT unity membership; copied into nvim cache.\n"
                               '#include "' + member.as_posix() + '"\n', encoding="utf-8")
            entries.append({"directory": str(root), "file": str(wrapper),
                            "arguments": [self.clangd, "-std=c++17", "-c", str(wrapper)],
                            "nvim_ue_module_root": str(root / ("Module%d" % (index // 2))),
                            "nvim_ue_members": [self.verified.portable_member_path(str(member))]})
        self.entries = entries
        semantic = root / "full.semantic.json"
        semantic.write_text(json.dumps(entries), encoding="utf-8")
        self.plan_path = root / "plan.json"
        plan = bg.make_plan(semantic, root / "verified_batches", self.clangd)
        self.plan_path.write_text(json.dumps(plan), encoding="utf-8")
        self.groups = plan["groups"]
        self.rows = [{k: e[k] for k in ("directory", "file", "arguments")} for e in entries]
        self.rows.append(command(source=str(source / "Other.cpp"), directory=str(root)))

    def tearDown(self):
        for name, value in self.env.items():
            if value is not None:
                os.environ[name] = value
        self.temp.cleanup()

    def owners(self, state, skip_member=None):
        owner, shards = {}, {}
        for group in state["groups"]:
            for index, path in enumerate([group["wrapper"]] + list(group["expected"])):
                if path == skip_member:
                    continue
                name = "%s.%d.idx" % (group["id"][:8], index)
                owner[tool.norm(Path(path).resolve())] = name
                shards[name] = Path(name)
        return owner, shards

    def test_prepare_substitutes_each_ordinary_group_by_its_wrapper(self):
        rows, state = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        self.assertEqual([g["indexes"] for g in self.groups], [[0, 1], [2, 3]])
        self.assertEqual(len(state["groups"]), 2)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[-1], self.rows[-1])
        for row, group in zip(rows, state["groups"]):
            self.assertIn("SuperUnity.Tier1.Batch.", row["file"])
            self.assertTrue(Path(row["file"]).is_file())
            self.assertEqual(len(group["expected"]), 2)
        self.assertEqual(state["rows_substituted"], 4)

    def test_misaligned_published_row_is_skipped_unchanged(self):
        changed = copy.deepcopy(self.rows)
        changed[0]["arguments"] = changed[0]["arguments"][:1] + ["-std=c++20"] + changed[0]["arguments"][2:]
        rows, state = self.tier1.prepare(changed, self.plan_path, self.clangd, None)
        self.assertEqual(len(state["groups"]), 1)
        self.assertEqual(state["skipped"], {"tier1-original-row-not-published": 1})
        self.assertEqual(rows[:2], changed[:2])

    def test_accepted_receipt_is_reused_by_the_background_proof_cache(self):
        _, state = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        owner, shards = self.owners(state)
        verdicts, drop, mapping = self.tier1.judge(state, [], [], owner, shards)
        self.assertEqual(drop, set())
        self.assertTrue(all(v["reason"] == self.tier1.ACCEPTED for v in verdicts.values()))
        fields = self.tier1.commit(state, verdicts, "private-sha")
        self.assertEqual(sorted(fields["tier1_accepted_ids"]), sorted(g["id"] for g in self.groups))
        self.assertEqual(fields["tier1_rejected"], {})
        self.assertEqual(self.tier1.fallback_tus(state, verdicts, mapping, []), [])
        with self.verified.tier1_overlay_scope(True):
            for group in state["groups"]:
                cached, _ = self.verified._tier1_cached(
                    group["entries"], group["candidate"], group["body"], group["output"], group["key"],
                    group["inputs"], state["tool_sha256"], state["profile"], state["environment"])
                self.assertTrue(cached and cached["accepted"])
        _, again = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        self.assertTrue(all(group["cached"] for group in again["groups"]))
        for group in state["groups"]:
            output, metrics = self.verified.reuse_tier1(group["entries"], Path(group["output"]).parent,
                                                        self.clangd)
            self.assertEqual((metrics["batch_count"], metrics["cache_hits"], len(output)), (1, 1, 1))
            self.assertIn("SuperUnity.Tier1.Batch.", output[0]["file"])

    def test_skipped_offline_run_reports_only_revalidated_receipts(self):
        _, state = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        owner, shards = self.owners(state)
        first = state["groups"][0]["id"]
        verdicts, _, _ = self.tier1.judge(state, [], [], owner, shards)
        verdicts = {key: value for key, value in verdicts.items() if key == first}
        state_one = dict(state, groups=[g for g in state["groups"] if g["id"] == first])
        self.tier1.commit(state_one, verdicts, "private-sha")
        _, again = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        fields = self.tier1.cached_report(again)
        self.assertEqual(fields["tier1_accepted_ids"], [first])
        self.assertEqual((fields["tier1_cache_hits"], fields["tier1_unjudged"]), (1, 1))
    def test_missing_member_shard_rejects_group_and_falls_back_to_originals(self):
        _, state = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        first = state["groups"][0]
        owner, shards = self.owners(state, skip_member=first["expected"][1])
        verdicts, drop, mapping = self.tier1.judge(state, [], [], owner, shards)
        self.assertEqual(verdicts[first["id"]]["reason"], "tier1-main-shards-missing")
        self.assertFalse(verdicts[first["id"]]["accepted"])
        self.assertTrue(drop)
        self.assertTrue(all(name.startswith(first["id"][:8]) for name in drop))
        fields = self.tier1.commit(state, verdicts, "private-sha")
        self.assertEqual(fields["tier1_rejected"], {first["id"]: "tier1-main-shards-missing"})
        self.assertEqual(self.tier1.fallback_tus(state, verdicts, mapping, []), sorted(first["originals"]))
        self.assertEqual(list((Path(first["output"]) / "receipts").glob("receipt.*.json")), [])
        second = state["groups"][1]
        self.assertEqual(len(list((Path(second["output"]) / "receipts").glob("receipt.*.json"))), 1)

    def test_failed_wrapper_compile_maps_failure_to_original_rows(self):
        _, state = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        first = state["groups"][0]
        owner, shards = self.owners(state)
        verdicts, _, mapping = self.tier1.judge(state, [first["wrapper"]], [], owner, shards)
        self.assertEqual(verdicts[first["id"]]["reason"], "tier1-candidate-index-failed")
        self.assertEqual(self.tier1.fallback_tus(state, verdicts, mapping, [first["wrapper"]]),
                         sorted(first["originals"]))

    def test_failed_wrapper_retries_original_rows_and_covered_rows_leave_fallback(self):
        _, state = self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)
        first, second = state["groups"]
        owner, shards = self.owners(state, skip_member=second["expected"][0])
        verdicts, _, mapping = self.tier1.judge(state, [first["wrapper"]], [], owner, shards)
        self.assertEqual(verdicts[second["id"]]["reason"], "tier1-main-shards-missing")
        retry = self.tier1.retry_rows(state, verdicts)
        self.assertEqual(retry, self.rows[0:2])  # only the compile-failed group, original rows
        self.assertEqual(self.tier1.retry_rows(None, verdicts), [])
        covered = {self.tier1.source_key(retry[0])}
        expected = sorted(set(first["originals"][1:]) | set(second["originals"]))
        self.assertEqual(self.tier1.fallback_tus(state, verdicts, mapping, [first["wrapper"]], covered),
                         expected)

    def test_tier2_mode_refuses_absorption(self):
        os.environ["NVIM_UE_TIER2"] = "1"
        with self.assertRaises(ValueError):
            self.tier1.prepare(copy.deepcopy(self.rows), self.plan_path, self.clangd, None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
