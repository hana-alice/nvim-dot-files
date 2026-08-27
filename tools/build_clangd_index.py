#!/usr/bin/env python3
"""
build_clangd_index.py - 为 clangd 生成受控 BackgroundIndex CDB 或 legacy .idx

NOTE: 这个脚本现在**只服务 :UEIndexHot / :UEIndexCurrent**，输入是
per-file 的小子集 CDB（几百到几千 TU）。:UEIndexFull 走 build_full_cdb.py
（rsp + inject + compiler-authored UBT unity wrappers + controlled
BackgroundIndex/clangd-indexer 一条龙）。

默认仍可生成旧的 clangd-indexer `.idx`。传入
`--background-output` 时改为输出“compiler-authored UBT unity wrappers +
exact per-file fallback”的受控 CDB，交给 clangd 自己的 BackgroundIndex
生成 shard。这是跨 TU 函数体定义的权威路径；
clangd 22 的 monolithic External.File 在实测中只返回头文件声明。

流程:
  1. 读取 compile_commands.json（已 inject 过 -D 的 per-file 子集）
  2. 调用 clangd-indexer --executor=all-TUs 生成 .idx
  3. 输出到 .cache/nvim-ue/clangd/index/<project>.idx

用法:
  python build_clangd_index.py <PROJ_DRIVE>/UEProj/compile_commands.json
  python build_clangd_index.py <PROJ_DRIVE>/UEProj/compile_commands.json --jobs=8
  python build_clangd_index.py <PROJ_DRIVE>/UEProj/compile_commands.json --server

选项:
  --jobs=N        并行 worker 数 (默认: CPU核心数)
  --server        生成后自动启动 clangd-index-server
  --port=N        index server 端口 (默认: 50051)
  --indexer=PATH  clangd-indexer 路径
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

TOOLS_DIR = str(Path(__file__).resolve().parent)
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

from cdb_argv import normalize_cdb


def find_clangd_indexer():
    """Find clangd-indexer executable."""
    candidates = [
        r"C:\Program Files\LLVM\bin\clangd-indexer.exe",
        r"C:\Program Files (x86)\LLVM\bin\clangd-indexer.exe",
    ]
    # Also check PATH
    for c in candidates:
        if os.path.isfile(c):
            return c
    # Try PATH
    import shutil
    found = shutil.which("clangd-indexer") or shutil.which("clangd-indexer.exe")
    if found:
        return found
    return None


def find_clangd_index_server():
    """Find clangd-index-server executable."""
    candidates = [
        r"C:\Program Files\LLVM\bin\clangd-index-server.exe",
        r"C:\Program Files (x86)\LLVM\bin\clangd-index-server.exe",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    import shutil
    return shutil.which("clangd-index-server") or shutil.which("clangd-index-server.exe")


def detect_project_root(cdb_path):
    """Detect project root from compile_commands.json location."""
    cdb_dir = os.path.dirname(os.path.abspath(cdb_path))
    # If compile_commands.json is in engine root, that's the project root
    return cdb_dir


def main():
    parser = argparse.ArgumentParser(description="Build clangd offline index")
    parser.add_argument("compile_commands", help="Path to compile_commands.json")
    parser.add_argument("--jobs", "-j", type=int, default=0,
                        help="Number of parallel workers (default: CPU count, max 24)")
    parser.add_argument("--server", action="store_true",
                        help="Start clangd-index-server after building")
    parser.add_argument("--port", type=int, default=50051,
                        help="Index server port (default: 50051)")
    parser.add_argument("--indexer", default=None,
                        help="Path to clangd-indexer executable")
    parser.add_argument("--output", "-o", default=None,
                        help="Output .idx file path")
    parser.add_argument("--background-output", default=None,
                        help="Write the controlled BackgroundIndex CDB here and write a "
                             "small marker to --output; do not run indexer")
    parser.add_argument("--no-super-unity", action="store_true",
                        help="Disable compiler-authored unity wrapping and keep "
                             "the subset in exact per-file form. Only use for "
                             "debugging controlled BackgroundIndex behavior.")
    args = parser.parse_args()

    cdb_path = os.path.abspath(args.compile_commands)
    if not os.path.isfile(cdb_path):
        print(f"ERROR: {cdb_path} not found", file=sys.stderr)
        return 1

    # The controlled BackgroundIndex route deliberately does not use
    # clangd-indexer. Resolve it only for the legacy .idx mode.
    indexer = None
    if not args.background_output:
        indexer = args.indexer or find_clangd_indexer()
        if not indexer:
            print("ERROR: clangd-indexer not found. Install from:", file=sys.stderr)
            print("  https://github.com/clangd/clangd/releases", file=sys.stderr)
            return 1

    project_root = detect_project_root(cdb_path)

    # Output path
    # Cache layout v3: idx lives under <project>/.cache/nvim-ue/clangd/index
    # (was: <project>/.clangd-index). Single-root cache.
    idx_dir = os.path.join(project_root, ".cache", "nvim-ue", "clangd", "index")
    os.makedirs(idx_dir, exist_ok=True)
    project_name = os.path.basename(project_root)
    idx_path = args.output or os.path.join(idx_dir, f"{project_name}.idx")
    # When --output points outside the auto-detected idx_dir, ensure that
    # parent dir exists too. Otherwise the open() at line 143 raises
    # FileNotFoundError after the inject step has already mutated the CDB
    # — leaving a broken pipeline state with no .idx file written.
    out_parent = os.path.dirname(idx_path)
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)

    # Count entries
    with open(cdb_path, "r", encoding="utf-8") as f:
        cdb = json.load(f)
    try:
        structured, converted = normalize_cdb(cdb)
    except (OSError, ValueError) as error:
        print(f"ERROR: cannot normalize input CDB: {error}", file=sys.stderr)
        return 1
    if converted or any("command" in entry for entry in cdb):
        normalized_tmp = cdb_path + f".normalize.tmp.{os.getpid()}"
        with open(normalized_tmp, "w", encoding="utf-8", newline="\n") as target:
            json.dump(structured, target, ensure_ascii=False, separators=(",", ":"))
        os.replace(normalized_tmp, cdb_path)
    cdb = structured
    print(f"compile_commands.json: {len(cdb)} entries")
    print(f"Structured argv: {len(cdb)} entries; command converted: {converted}")
    print(f"Project root: {project_root}")
    print(f"Output: {idx_path}")
    print(f"Mode: {'controlled-background' if args.background_output else 'legacy-idx'}")
    if indexer:
        print(f"Indexer: {indexer}")

    # NOTE: previously this script supported --use-unity / --use-super-unity
    # to convert the per-file CDB into Module.<X>.cpp / SuperUnity.<PCH>.<N>.cpp
    # wrapper TUs in-process. Those code paths now live in build_full_cdb.py
    # (which is the single entry for :UEIndexFull). This script is now reserved
    # for hot/current phases — small per-module subsets whose controlled
    # BackgroundIndex wrapping is delegated to build_hot_super_unity_cdb.py.

    # CRITICAL: Inject Definitions.<Module>.h #defines as explicit -D into CDB.
    # clangd-indexer's disableUnsupportedOptions() strips -include-pch, which
    # makes the Build.h:47 #error UE_BUILD_DEBUG fire on ~97% of UE TUs and
    # produces a useless index. We expand the .h file's #defines into -D args
    # so the indexer sees the macros without needing PCH support.
    #
    # ORDER MATTERS: inject MUST run BEFORE compiler-authored unity wrapping. Inject's
    # get_module_from_filepath only understands `Module.<X>.cpp` paths; the
    # wrapper `SuperUnity.<PCH>.<N>.cpp` files emitted later would all
    # return None → 0 -D injected → indexer hits #error on every TU. By
    # injecting first, the wrapper step's per-chunk -I/-D/-U union (see
    # build_super_unity_cdb.py) then carries the per-module DLLEXPORT macros
    # into each wrapper TU.
    inject_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inject_definitions_to_cdb.py")
    if os.path.isfile(inject_script):
        print("\n[inject] Injecting Definitions.h #defines into CDB...")
        rc = subprocess.call([sys.executable, "-I", inject_script, cdb_path])
        if rc != 0:
            print(f"  WARN: inject_definitions_to_cdb returned {rc}")
        # Re-read CDB after injection (size may have grown)
        with open(cdb_path, "r", encoding="utf-8") as f:
            cdb = json.load(f)
        print(f"  CDB size after inject: {len(cdb)} entries, {os.path.getsize(cdb_path)/1024/1024:.1f} MB")
    else:
        print(f"  WARN: {inject_script} not found, skipping injection")
        print(f"  (Indexer will likely fail on ~97% of UE TUs without it.)")

    # Build index
    # CRITICAL: clangd-indexer's positional arg is a SOURCE file used as a
    # filter, NOT the CDB itself. The CDB is found by searching for
    # `compile_commands.json` in cwd-or-parent (ClangTool default). If we
    # pass `hot.json` as positional, indexer ignores it as filter and falls
    # back to <cwd-or-ancestor>/compile_commands.json — i.e. the FULL base
    # CDB — silently indexing all 14334 TUs instead of our 2979-entry hot
    # subset. Workaround: stage the subset as `compile_commands.json` in a
    # private dir and `cd` there.
    stage_dir = os.path.join(os.path.dirname(idx_path), f"_stage_{os.path.basename(idx_path)}")
    os.makedirs(stage_dir, exist_ok=True)
    staged_cdb = os.path.join(stage_dir, "compile_commands.json")
    shutil.copyfile(cdb_path, staged_cdb)
    print(f"  Staged subset CDB at: {staged_cdb}")

    # Controlled BackgroundIndex wrapping: use compiler-authored active-build
    # UBT unity groups when they can be proven against this subset CDB, and
    # keep all unmatched files exact per-file. See
    # build_hot_super_unity_cdb.py for the current grouping contract.
    super_ready = False
    if not args.no_super_unity:
        super_script = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "build_hot_super_unity_cdb.py",
        )
        if os.path.isfile(super_script):
            print("\n[background-cdb] wrapping compiler-authored unity groups...")
            super_cdb = os.path.join(stage_dir, "compile_commands.super.json")
            rc = subprocess.call([
                sys.executable, "-I", super_script,
                staged_cdb, super_cdb,
                "--super-dir", os.path.join(stage_dir, "super_unity_cpps"),
            ])
            if rc == 0 and os.path.isfile(super_cdb):
                # Swap the staged CDB for the controlled BackgroundIndex one.
                # The result contains wrapper entries only where active-build
                # UBT unity evidence exists, and exact per-file entries
                # everywhere else.
                shutil.move(super_cdb, staged_cdb)
                print(f"  swapped CDB → controlled BackgroundIndex form")
                super_ready = True
            else:
                if args.background_output:
                    print(f"  ERROR: controlled background requires compiler-authored unity output (rc={rc})",
                          file=sys.stderr)
                    return 1
                print(f"  WARN: controlled background wrapping step failed (rc={rc}), "
                      f"falling back to per-file mode")
        else:
            if args.background_output:
                print(f"  ERROR: controlled background requires {super_script}", file=sys.stderr)
                return 1
            print(f"  WARN: {super_script} not found, "
                  f"falling back to per-file mode")
    else:
        if args.background_output:
            print("ERROR: --background-output cannot be combined with --no-super-unity",
                  file=sys.stderr)
            return 1
        print("\n[background-cdb] compiler-authored unity wrapping disabled, per-file mode")

    if args.background_output:
        background_path = os.path.abspath(args.background_output)
        os.makedirs(os.path.dirname(background_path), exist_ok=True)
        with open(staged_cdb, "r", encoding="utf-8") as source:
            background_cdb = json.load(source)
        if not super_ready or not background_cdb or any(
            not entry.get("file") or not isinstance(entry.get("arguments"), list)
            for entry in background_cdb
        ):
            print("ERROR: refusing malformed controlled background CDB", file=sys.stderr)
            return 1
        background_tmp = background_path + f".tmp.{os.getpid()}"
        with open(background_tmp, "w", encoding="utf-8", newline="\n") as target:
            json.dump(background_cdb, target, ensure_ascii=False, separators=(",", ":"))
        os.replace(background_tmp, background_path)

        marker = {
            "schema": 1,
            "index_kind": "controlled-background",
            "cdb_name": os.path.basename(background_path),
            "entry_count": len(background_cdb),
            "unity_entry_count": sum(
                "super_unity_cpps" in str(entry.get("file", "")).replace("\\", "/")
                for entry in background_cdb
            ),
        }
        marker_tmp = idx_path + f".tmp.{os.getpid()}"
        with open(marker_tmp, "w", encoding="utf-8", newline="\n") as target:
            json.dump(marker, target, ensure_ascii=False, separators=(",", ":"))
        os.replace(marker_tmp, idx_path)
        print(f"\nControlled BackgroundIndex CDB: {background_path}")
        print(f"  Controlled entries: {len(background_cdb)}")
        return 0

    cmd = [indexer, "--executor=all-TUs"]
    # If user didn't specify --jobs, default to CPU count clamped to [8, 24].
    # Empirically clangd-indexer's own default greatly under-uses the box on
    # multi-core Windows machines (we observed ~2.4 files/sec on a 24-core
    # machine — implies ~6-8 workers actually busy). Forcing the flag fixes it.
    effective_jobs = args.jobs
    if effective_jobs <= 0:
        try:
            effective_jobs = max(8, min(24, os.cpu_count() or 8))
        except Exception:
            effective_jobs = 8
    cmd.append(f"--execute-concurrency={effective_jobs}")
    print(f"  indexer concurrency: {effective_jobs}")
    cmd.append(staged_cdb)

    print(f"\nBuilding index... (this may take a while)")
    t0 = time.time()

    with open(idx_path, "wb") as out_f:
        proc = subprocess.Popen(
            cmd,
            stdout=out_f,
            stderr=subprocess.PIPE,
            cwd=stage_dir,
        )
        # Stream stderr for progress
        processed = 0
        for line in proc.stderr:
            line_str = line.decode("utf-8", errors="replace").rstrip()
            if line_str.startswith("["):
                processed += 1
                if processed % 100 == 0 or processed <= 5:
                    elapsed = time.time() - t0
                    rate = processed / elapsed if elapsed > 0 else 0
                    print(f"\r  {line_str}  ({rate:.1f} files/sec)", end="", flush=True)
            elif "error" in line_str.lower() and processed < 10:
                # Show first few errors
                print(f"\n  WARN: {line_str[:200]}", file=sys.stderr)

        proc.wait()

    elapsed = time.time() - t0
    idx_size = os.path.getsize(idx_path)

    print(f"\n\nDone in {elapsed:.1f}s")
    print(f"  Processed: {processed} files ({processed/elapsed:.1f} files/sec)")
    print(f"  Index size: {idx_size/1024/1024:.1f} MB")
    print(f"  Output: {idx_path}")

    if proc.returncode != 0:
        print(f"\n  WARNING: indexer exited with code {proc.returncode}")
        print("  (Some files may have had errors, but index is still usable)")

    # Generate .clangd snippet for External index
    print(f"\n--- .clangd config snippet ---")
    print(f"Index:")
    print(f"  External:")
    print(f"    File: {idx_path}")
    print(f"    MountPoint: {project_root}")
    print(f"--- end snippet ---")

    # Optionally start server
    if args.server:
        server = find_clangd_index_server()
        if not server:
            print("\nERROR: clangd-index-server not found", file=sys.stderr)
            return 1
        addr = f"0.0.0.0:{args.port}"
        print(f"\nStarting clangd-index-server on {addr}...")
        print(f"  {server} {idx_path} {project_root} --server-address={addr}")
        print(f"\n  Connect clangd with: --remote-index-address=localhost:{args.port}")
        os.execv(server, [server, idx_path, project_root, f"--server-address={addr}"])

    return 0


if __name__ == "__main__":
    sys.exit(main())
