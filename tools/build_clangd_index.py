#!/usr/bin/env python3
"""
build_clangd_index.py - 为 clangd 离线预建索引

使用 clangd-indexer 预先索引所有 TU，生成 .idx 文件。
配合 .clangd 的 Index.External.File 或 clangd-index-server 使用，
可跳过后台索引，大幅加速 clangd 启动体验。

流程:
  1. 读取 compile_commands.json
  2. 调用 clangd-indexer --executor=all-TUs 生成 .idx
  3. 输出到 .clangd-index/<project>.idx

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
import subprocess
import sys
import time
from pathlib import Path


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
                        help="Number of parallel workers (default: CPU count)")
    parser.add_argument("--server", action="store_true",
                        help="Start clangd-index-server after building")
    parser.add_argument("--port", type=int, default=50051,
                        help="Index server port (default: 50051)")
    parser.add_argument("--indexer", default=None,
                        help="Path to clangd-indexer executable")
    parser.add_argument("--output", "-o", default=None,
                        help="Output .idx file path")
    args = parser.parse_args()

    cdb_path = os.path.abspath(args.compile_commands)
    if not os.path.isfile(cdb_path):
        print(f"ERROR: {cdb_path} not found", file=sys.stderr)
        return 1

    # Find tools
    indexer = args.indexer or find_clangd_indexer()
    if not indexer:
        print("ERROR: clangd-indexer not found. Install from:", file=sys.stderr)
        print("  https://github.com/clangd/clangd/releases", file=sys.stderr)
        return 1

    project_root = detect_project_root(cdb_path)

    # Output path
    idx_dir = os.path.join(project_root, ".clangd-index")
    os.makedirs(idx_dir, exist_ok=True)
    project_name = os.path.basename(project_root)
    idx_path = args.output or os.path.join(idx_dir, f"{project_name}.idx")

    # Count entries
    with open(cdb_path, "r", encoding="utf-8") as f:
        cdb = json.load(f)
    print(f"compile_commands.json: {len(cdb)} entries")
    print(f"Project root: {project_root}")
    print(f"Output: {idx_path}")
    print(f"Indexer: {indexer}")

    # Build index
    cmd = [indexer, "--executor=all-TUs", cdb_path]
    if args.jobs > 0:
        # clangd-indexer doesn't have -j flag, it uses all CPUs by default
        pass

    print(f"\nBuilding index... (this may take a while)")
    t0 = time.time()

    with open(idx_path, "wb") as out_f:
        proc = subprocess.Popen(
            cmd,
            stdout=out_f,
            stderr=subprocess.PIPE,
            cwd=project_root,
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
