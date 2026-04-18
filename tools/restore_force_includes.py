#!/usr/bin/env python3
"""
restore_force_includes.py — undo the unify_definitions damage.

Background
----------
UBT 真实编译会用 /FI <BuildSettings/Definitions.h> 注入 UE_BUILD_DEVELOPMENT /
WITH_EDITOR 等关键宏，再用 /FI <Module>/Definitions.<Module>.h 注入 module
specific 配置（UE_IS_ENGINE_MODULE 等）。

slim_compile_commands.py 之前的 unify_definitions() 把 -include
Definitions.<Module>.h 全删了"为了 preamble 缓存复用"，结果：
  - PCH 编译时缺 UE_BUILD_DEVELOPMENT → SharedPCH.CoreUObject.Cpp20.pch
    内部 #if UE_BUILD_DEVELOPMENT 等于 0 → 实际类型如 int32/TCHAR 没注入
  - clangd 加载 PCH 后缺宏 → AST 报 "unknown type name 'int32'"

修复
----
为 CDB 里每个 .cpp 重新塞回 -include：
  1. -include <engine_root>/Engine/Intermediate/Build/Win64/x64/<Target>/<Configuration>/BuildSettings/Definitions.h
  2. -include <engine_root>/Engine/Intermediate/Build/Win64/x64/<Target>/<Configuration>/<Module>/Definitions.<Module>.h
     （从对应的 .obj.rsp 文件抓 /FI 路径，权威来源）

用法
----
  python restore_force_includes.py <PROJ_DRIVE>/UEProj/Engine/compile_commands.json
"""
import json
import os
import re
import shutil
import sys
from pathlib import Path

FI_RE = re.compile(r'/FI"([^"]+)"')


def build_rsp_index(build_root: str):
    """Pre-index all .cpp.obj.rsp files under build_root by basename and module.
    Returns dict: { (module_name, basename): rsp_path }.
    Targets are prioritized: UnrealEditor > UnrealGame > others.
    Configurations: Development > DebugGame > Debug > Test > Shipping."""
    idx = {}
    if not os.path.isdir(build_root):
        return idx
    plat_dir = os.path.join(build_root, "Win64", "x64")
    if not os.path.isdir(plat_dir):
        return idx

    # Sort targets: UnrealEditor first (matches what UE devs use day-to-day)
    target_priority = {
        "UnrealEditor": 0, "UnrealGame": 1, "UnrealClient": 2,
        "UnrealServer": 3, "ShaderCompileWorker": 9,
    }
    cfg_priority = {
        "Development": 0, "DebugGame": 1, "Debug": 2,
        "Test": 3, "Shipping": 4,
    }

    targets = sorted(
        [t for t in os.listdir(plat_dir) if os.path.isdir(os.path.join(plat_dir, t))],
        key=lambda t: (target_priority.get(t, 5), t),
    )
    for tgt in targets:
        tgt_dir = os.path.join(plat_dir, tgt)
        cfgs = sorted(
            [c for c in os.listdir(tgt_dir) if os.path.isdir(os.path.join(tgt_dir, c))],
            key=lambda c: (cfg_priority.get(c, 5), c),
        )
        for cfg in cfgs:
            cfg_dir = os.path.join(tgt_dir, cfg)
            for module in os.listdir(cfg_dir):
                mod_dir = os.path.join(cfg_dir, module)
                if not os.path.isdir(mod_dir):
                    continue
                try:
                    files = os.listdir(mod_dir)
                except OSError:
                    continue
                for f in files:
                    if f.endswith(".cpp.obj.rsp"):
                        base = f[:-len(".cpp.obj.rsp")]
                        rsp_path = os.path.join(mod_dir, f).replace("\\", "/")
                        key = (module, base)
                        if key not in idx:
                            idx[key] = rsp_path
                        mod_key = (module, "__module__")
                        if mod_key not in idx and f.startswith("Module."):
                            idx[mod_key] = rsp_path
    return idx


def find_obj_rsp_indexed(cpp_path: str, rsp_index: dict):
    """Use the pre-built index to locate the rsp for a cpp."""
    cpp_basename = os.path.splitext(os.path.basename(cpp_path))[0]
    p = Path(cpp_path)
    module_name = None
    for parent in p.parents:
        if parent.name in ("Public", "Private", "Internal", "Classes"):
            module_name = parent.parent.name
            break
    if not module_name:
        # Try direct parent's name
        if p.parent.parent.name in ("Source",):
            module_name = p.parent.name
    if not module_name:
        return None
    # Exact match first
    rsp = rsp_index.get((module_name, cpp_basename))
    if rsp:
        return rsp
    # Fall back to first Module.*.cpp.obj.rsp for the module (unity build)
    return rsp_index.get((module_name, "__module__"))


def find_obj_rsp(cpp_path: str, build_root: str):
    """Given a .cpp path, find the matching .obj.rsp file under
    Intermediate/Build/.../<Module>/. Returns abs path or None."""
    cpp_basename = os.path.splitext(os.path.basename(cpp_path))[0]

    # Module name = parent of Public/Private/Internal/Classes containing the cpp
    p = Path(cpp_path).resolve()
    module_name = None
    for parent in p.parents:
        # Walk up until we find a directory whose parent is .../Source/Runtime|Editor|Developer|...
        gp = parent.parent
        if gp.name in ("Source",) or gp.parent.name in ("Source",):
            module_name = parent.name
            break
        if parent.name in ("Public", "Private", "Internal", "Classes"):
            module_name = parent.parent.name
            break

    if not module_name:
        return None

    # Search Intermediate/Build/Win64/x64/UnrealEditor/Development/<Module>/<basename>.cpp.obj.rsp
    # and similar variants
    candidates = []
    for cfg in ("Development", "Debug", "DebugGame", "Test", "Shipping"):
        for tgt in ("UnrealEditor", "UnrealGame", "UnrealServer", "UnrealClient"):
            d = os.path.join(build_root, "Win64", "x64", tgt, cfg, module_name)
            if os.path.isdir(d):
                rsp = os.path.join(d, f"{cpp_basename}.cpp.obj.rsp")
                if os.path.isfile(rsp):
                    return rsp.replace("\\", "/")
                # Module.<Module>.N.cpp variant (unity-style names)
                for f in os.listdir(d):
                    if f.endswith(".cpp.obj.rsp") and f.startswith("Module."):
                        candidates.append(os.path.join(d, f).replace("\\", "/"))

    # Fall back to first matching Module.*.cpp.obj.rsp in any matching module dir
    if candidates:
        return candidates[0]
    return None


def extract_force_includes(rsp_path: str, source_dir: str):
    """Read a .obj.rsp and return list of /FI paths as absolute (forward-slash)."""
    out = []
    try:
        with open(rsp_path, encoding="utf-8", errors="replace") as f:
            content = f.read()
    except Exception:
        return out
    for m in FI_RE.finditer(content):
        path = m.group(1).replace("\\", "/")
        # Skip SharedPCH headers — those become -include-pch later
        if "SharedPCH" in path or "/PCH." in path:
            continue
        # Resolve relative to source_dir (UBT writes paths relative to engine/Source)
        if not (len(path) > 1 and path[1] == ":") and not path.startswith("/"):
            path = os.path.normpath(os.path.join(source_dir, path)).replace("\\", "/")
        out.append(path)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cdb_path = sys.argv[1]
    if not os.path.isfile(cdb_path):
        print(f"CDB not found: {cdb_path}", file=sys.stderr)
        sys.exit(1)

    cdb_path = os.path.abspath(cdb_path).replace("\\", "/")
    engine_dir = os.path.dirname(cdb_path)  # .../Engine
    build_root = os.path.join(engine_dir, "Intermediate", "Build").replace("\\", "/")

    if not os.path.isdir(build_root):
        print(f"Intermediate/Build dir not found: {build_root}", file=sys.stderr)
        sys.exit(1)

    bak = cdb_path + ".pre-restore-fi.bak"
    if not os.path.exists(bak):
        shutil.copy2(cdb_path, bak)
        print(f"backup → {bak}")

    print("indexing .obj.rsp files (one-time scan) ...")
    rsp_index = build_rsp_index(build_root)
    print(f"  indexed {len(rsp_index)} (module, basename) entries")

    with open(cdb_path) as f:
        cdb = json.load(f)

    print(f"entries: {len(cdb)}")
    modified, unchanged, no_rsp = 0, 0, 0

    for e in cdb:
        cpp = e["file"].replace("\\", "/")
        args = e["arguments"]
        directory = e.get("directory", engine_dir + "/Source").replace("\\", "/")

        # Skip if already has -include for Definitions.h
        existing_includes = []
        for i, a in enumerate(args):
            if a == "-include" and i + 1 < len(args):
                existing_includes.append(args[i + 1].replace("\\", "/"))
        if any("Definitions" in p for p in existing_includes):
            unchanged += 1
            continue

        rsp = find_obj_rsp_indexed(cpp, rsp_index)
        if not rsp:
            no_rsp += 1
            continue

        fi_paths = extract_force_includes(rsp, directory)
        if not fi_paths:
            no_rsp += 1
            continue

        # Insert -include <path> pairs before the source file (last arg)
        # Find insert position: before -include-pch if present, else before last arg
        new_args = []
        inserted = False
        for i, a in enumerate(args):
            if not inserted and a == "-include-pch":
                for p in fi_paths:
                    new_args.append("-include")
                    new_args.append(p)
                inserted = True
            new_args.append(a)
        if not inserted:
            # No -include-pch: prepend before the source file (last arg)
            insert_at = len(new_args) - 1
            for j, p in enumerate(fi_paths):
                new_args.insert(insert_at + 2 * j, "-include")
                new_args.insert(insert_at + 2 * j + 1, p)

        e["arguments"] = new_args
        modified += 1

    print(f"modified: {modified}, unchanged: {unchanged}, no rsp: {no_rsp}")

    with open(cdb_path, "w") as f:
        json.dump(cdb, f, indent=1)
    print(f"wrote {cdb_path}")


if __name__ == "__main__":
    main()
