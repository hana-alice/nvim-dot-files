#!/usr/bin/env python3
"""
build_full_cdb.py — Single source of truth for clangd CDB on Unreal Engine.

ARCHITECTURE (v2 — two-artefact split):
  LSP and clangd-indexer have OPPOSITE needs:
    - LSP must answer goto-def / completion / diagnostics on the EXACT buffer
      the user is editing → it needs the per-file entry for that .cpp/.h.
      If LSP only sees super-TUs, it returns multiple symbol candidates
      (the same UClass appears in 13 different super-TU translation units).
    - clangd-indexer parses every TU in the CDB exhaustively. Per-file with
      14k+ TUs takes ~165 minutes. Super-unity (13 fat TUs) takes ~50s for
      the same symbol coverage.

  Therefore we produce TWO CDBs from one input:
    1. <out_active>          — per-file entries only (LSP)
    2. <out_active>.indexer  — super-unity entries only (clangd-indexer)
                                (path lives next to active CDB so the
                                 :UEIndexFull command can stage it)

PIPELINE:
  raw UBT compile_commands.json (per-file)
    │
    ├── replace_i_with_rsp.py        — fix -I list from .Shared.rsp
    ├── inject_definitions_to_cdb.py — inject Definitions.h #defines as -D
    │      ↓
    │   (per-file CDB, post-fix) → write to <out_active>     [LSP artefact]
    │      ↓
    ├── build_unity_cdb.py           — derive throwaway unity CDB
    └── build_super_unity_cdb.py     — group unity → ~13 super-TUs
           ↓
        (super-only CDB) → write to <out_active>.indexer     [indexer artefact]

USAGE:
  python build_full_cdb.py <raw_perfile_cdb> <out_active> [--no-rsp] [--max-mods=50]
                          [--idx-output <path>] [--indexer <path>] [--jobs N]

  When --idx-output is passed, after producing the sidecar this also runs
  clangd-indexer on the sidecar and writes the .idx file to the given path.
  This is the single entry point the :UEIndexFull command uses; passing
  --idx-output makes lua a one-shot caller (no separate indexer step).

EXIT 0 on success.

DESIGN HISTORY:
  v1 (deprecated): appended super-TUs to per-file in ONE CDB. LSP saw both,
    indexer saw both. Worked for indexer but indexer treated each entry as
    its own TU (--executor=all-TUs) → 14347 TUs → ~110 minutes, defeating
    the entire point of super-unity. The 50s commit (181c4ee) actually used
    a 13-entry-only CDB; that the same CDB also drove LSP was an accident
    of the old single-pipeline design that hurt LSP precision.
  v2 (this): two artefacts. ue.lua's :UEIndexFull stages the .indexer file
    as compile_commands.json into a temp dir before running clangd-indexer,
    leaving the active CDB (per-file) untouched for LSP.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def run(cmd, **kw):
    print(f"  $ {' '.join(cmd)}", flush=True)
    t0 = time.time()
    rc = subprocess.call(cmd, **kw)
    print(f"  ← exit {rc} in {time.time()-t0:.1f}s", flush=True)
    return rc


def load_cdb(p):
    with open(p, 'r', encoding='utf-8') as f:
        return json.load(f)


def write_cdb(p, data):
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(data, f)


def atomic_write(dst, data, label=''):
    dst_dir = os.path.dirname(dst)
    if dst_dir:
        os.makedirs(dst_dir, exist_ok=True)
    tmp = dst + '.tmp'
    write_cdb(tmp, data)
    if os.path.exists(dst):
        bak = dst + '.bak.' + str(int(time.time()))
        try:
            shutil.copyfile(dst, bak)
            print(f'[backup] {label or dst} → {bak}')
        except OSError as e:
            print(f'  WARN: backup failed: {e}')
    os.replace(tmp, dst)
    sz = os.path.getsize(dst) / 1024 / 1024
    print(f'[done] wrote {dst} ({sz:.1f} MB)')


def find_clangd_indexer(explicit=None):
    if explicit and os.path.isfile(explicit):
        return explicit
    for c in (
        r'C:\Program Files\LLVM\bin\clangd-indexer.exe',
        r'C:\Program Files (x86)\LLVM\bin\clangd-indexer.exe',
    ):
        if os.path.isfile(c):
            return c
    return shutil.which('clangd-indexer') or shutil.which('clangd-indexer.exe')


def run_clangd_indexer(sidecar_cdb, idx_out, indexer_exe, jobs=0):
    """Run clangd-indexer on a SIDECAR CDB; write .idx to idx_out.

    clangd-indexer's positional arg is treated as a SOURCE filter, not a CDB.
    The CDB is found via ClangTool default (`compile_commands.json` in
    cwd-or-ancestor). To make it pick OUR sidecar, we copy it as
    `compile_commands.json` into a private stage dir and cd there.
    Without this workaround the indexer silently falls back to whatever
    compile_commands.json sits next to the engine root (the per-file CDB).
    """
    out_parent = os.path.dirname(idx_out)
    if out_parent:
        os.makedirs(out_parent, exist_ok=True)
    stage_dir = os.path.join(out_parent or '.', f'_stage_{os.path.basename(idx_out)}')
    os.makedirs(stage_dir, exist_ok=True)
    staged = os.path.join(stage_dir, 'compile_commands.json')
    shutil.copyfile(sidecar_cdb, staged)
    print(f'[indexer] staged sidecar → {staged}')

    if jobs <= 0:
        try:
            jobs = max(8, min(24, os.cpu_count() or 8))
        except Exception:
            jobs = 8
    cmd = [indexer_exe, '--executor=all-TUs', f'--execute-concurrency={jobs}', staged]
    print(f'[indexer] {" ".join(cmd)}')

    t0 = time.time()
    with open(idx_out, 'wb') as out_f:
        proc = subprocess.Popen(cmd, stdout=out_f, stderr=subprocess.PIPE, cwd=stage_dir)
        processed = 0
        for raw in proc.stderr:
            line = raw.decode('utf-8', errors='replace').rstrip()
            if line.startswith('['):
                processed += 1
                if processed % 100 == 0 or processed <= 5:
                    rate = processed / max(1e-9, time.time() - t0)
                    print(f'\r  {line}  ({rate:.1f} files/sec)', end='', flush=True)
            elif 'error' in line.lower() and processed < 10:
                print(f'\n  WARN: {line[:200]}', file=sys.stderr)
        proc.wait()
    elapsed = time.time() - t0
    sz = os.path.getsize(idx_out) / 1024 / 1024
    print(f'\n[indexer] done in {elapsed:.1f}s, {processed} TUs, {sz:.1f} MB → {idx_out}')
    if proc.returncode != 0:
        print(f'  WARN: indexer exited with code {proc.returncode} (idx still usable)')
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('input_cdb', help='Raw per-file UBT compile_commands.json')
    ap.add_argument('output_cdb', help='Output ACTIVE per-file CDB (for LSP)')
    ap.add_argument('--no-rsp', action='store_true',
                    help='Skip replace_i_with_rsp step (faster, less accurate -I)')
    ap.add_argument('--no-inject', action='store_true',
                    help='Skip inject_definitions step (only for debugging)')
    ap.add_argument('--no-super', action='store_true',
                    help='Skip super-unity sidecar; only produce per-file active CDB')
    ap.add_argument('--max-mods', type=int, default=50,
                    help='Max modules per super-unity TU (default 50)')
    ap.add_argument('--keep-staging', action='store_true',
                    help='Keep intermediate staging dir for inspection')
    ap.add_argument('--idx-output', default=None,
                    help='If set, run clangd-indexer on the sidecar and write '
                         '.idx to this path. Single-shot mode for :UEIndexFull.')
    ap.add_argument('--indexer', default=None,
                    help='clangd-indexer executable path (auto-probed if omitted)')
    ap.add_argument('--jobs', '-j', type=int, default=0,
                    help='clangd-indexer concurrency (default: clamp(8, cpu, 24))')
    args = ap.parse_args()

    src = os.path.abspath(args.input_cdb)
    dst_active = os.path.abspath(args.output_cdb)
    dst_indexer = dst_active + '.indexer'
    if not os.path.isfile(src):
        print(f'ERROR: input not found: {src}', file=sys.stderr)
        return 1

    tools = os.path.dirname(os.path.abspath(__file__))
    py = sys.executable

    stage = tempfile.mkdtemp(prefix='build_full_cdb_')
    print(f'[stage] {stage}', flush=True)
    work = os.path.join(stage, 'compile_commands.json')
    shutil.copyfile(src, work)
    print(f'[input] {len(load_cdb(work))} per-file entries', flush=True)

    # ---- Step 1: replace -I with rsp truth (per-file CDB; in-place)
    if not args.no_rsp:
        rsp = os.path.join(tools, 'replace_i_with_rsp.py')
        if os.path.isfile(rsp):
            print('\n[1/4] replace_i_with_rsp')
            rc = run([py, '-I', rsp, work])
            if rc != 0:
                print(f'  WARN: replace_i_with_rsp returned {rc} (continuing)')
        else:
            print(f'\n[1/4] replace_i_with_rsp SKIPPED ({rsp} not found)')
    else:
        print('\n[1/4] replace_i_with_rsp SKIPPED (--no-rsp)')

    # ---- Step 2: inject Definitions.h #defines (per-file CDB; in-place)
    if not args.no_inject:
        inj = os.path.join(tools, 'inject_definitions_to_cdb.py')
        if os.path.isfile(inj):
            print('\n[2/4] inject_definitions_to_cdb')
            rc = run([py, '-I', inj, work])
            if rc != 0:
                print(f'  WARN: inject_definitions_to_cdb returned {rc} (continuing)')
        else:
            print(f'\n[2/4] inject_definitions_to_cdb SKIPPED ({inj} not found)')
    else:
        print('\n[2/4] inject_definitions_to_cdb SKIPPED (--no-inject)')

    perfile = load_cdb(work)
    print(f'[after inject] {len(perfile)} per-file entries')

    # ---- ARTEFACT 1: write per-file active CDB (for LSP) ----
    print('\n[active] writing per-file CDB for LSP')
    atomic_write(dst_active, perfile, label='active CDB')

    if args.no_super:
        print('[skip super-unity sidecar (--no-super)]')
        if not args.keep_staging:
            shutil.rmtree(stage, ignore_errors=True)
        return 0

    # ---- Step 3: derive throwaway unity CDB (input to super-unity)
    unity_cdb = os.path.join(stage, 'compile_commands.unity.json')
    bu = os.path.join(tools, 'build_unity_cdb.py')
    if not os.path.isfile(bu):
        print(f'\nERROR: build_unity_cdb.py missing → no super-unity sidecar', file=sys.stderr)
        return 1
    print('\n[3/4] build_unity_cdb (intermediate, throwaway)')
    rc = run([py, '-I', bu, work, unity_cdb])
    if rc != 0 or not os.path.isfile(unity_cdb):
        print(f'ERROR: build_unity_cdb failed (rc={rc})', file=sys.stderr)
        return 1
    print(f'[unity] {len(load_cdb(unity_cdb))} unity TUs')

    # ---- Step 4: build super-unity TUs from the unity CDB
    super_cdb = os.path.join(stage, 'compile_commands.super.json')
    bs = os.path.join(tools, 'build_super_unity_cdb.py')
    if not os.path.isfile(bs):
        print(f'\nERROR: build_super_unity_cdb.py missing', file=sys.stderr)
        return 1
    print('\n[4/4] build_super_unity_cdb')
    rc = run([py, '-I', bs, unity_cdb, super_cdb, str(args.max_mods)])
    if rc != 0 or not os.path.isfile(super_cdb):
        print(f'ERROR: build_super_unity_cdb failed (rc={rc})', file=sys.stderr)
        return 1
    super_entries = load_cdb(super_cdb)
    print(f'[super-unity] {len(super_entries)} super-TUs')

    # ---- ARTEFACT 2: write super-only indexer CDB ----
    # The super-TU entries reference .cpp files in <stage>/super_unity_cpps/.
    # Move that dir to a stable location next to the active CDB BEFORE we
    # rewrite paths, so the indexer can find the actual .cpp files later.
    dst_dir = os.path.dirname(dst_active)
    stable_super_dir = os.path.join(dst_dir, 'super_unity_cpps')
    src_super_dir = os.path.join(stage, 'super_unity_cpps')
    if os.path.isdir(src_super_dir):
        if os.path.isdir(stable_super_dir):
            shutil.rmtree(stable_super_dir, ignore_errors=True)
        shutil.copytree(src_super_dir, stable_super_dir)
        print(f'[super_cpps] {stable_super_dir}')

        # Patch super-TU paths from staging to stable
        from_dir = src_super_dir.replace('/', '\\')
        to_dir = stable_super_dir.replace('/', '\\')
        patched = 0
        for e in super_entries:
            if from_dir in e.get('file', ''):
                e['file'] = e['file'].replace(from_dir, to_dir)
                patched += 1
            new_args = []
            for a in e.get('arguments', []):
                if isinstance(a, str) and from_dir in a:
                    a = a.replace(from_dir, to_dir)
                new_args.append(a)
            e['arguments'] = new_args
        if patched:
            print(f'[patched] {patched} super-TU file paths to stable dir')

    print('\n[indexer] writing super-only CDB for clangd-indexer')
    atomic_write(dst_indexer, super_entries, label='indexer CDB')

    if not args.keep_staging:
        shutil.rmtree(stage, ignore_errors=True)
    else:
        print(f'[stage kept] {stage}')

    print(f'\n[summary]')
    print(f'  active  (LSP)     : {dst_active}    {len(perfile)} entries')
    print(f'  indexer (clangd)  : {dst_indexer}    {len(super_entries)} entries')

    # ---- OPTIONAL Step 5: run clangd-indexer on the sidecar ----
    if args.idx_output:
        idx_out = os.path.abspath(args.idx_output)
        indexer_exe = find_clangd_indexer(args.indexer)
        if not indexer_exe:
            print('\nERROR: --idx-output set but clangd-indexer not found', file=sys.stderr)
            return 1
        print(f'\n[5/5] running clangd-indexer → {idx_out}')
        rc = run_clangd_indexer(dst_indexer, idx_out, indexer_exe, jobs=args.jobs)
        if rc != 0:
            return rc

    return 0


if __name__ == '__main__':
    sys.exit(main())
