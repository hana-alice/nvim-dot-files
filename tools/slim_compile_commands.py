#!/usr/bin/env python3
"""
slim_compile_commands.py — 精简 UE 项目 compile_commands.json

优化:
  1. 剔除 .generated.h / .init.gen.c / gen.cpp 等自动生成条目
  2. 剔除 shader 文件 (usf/ush/hlsl/glsl 等) — clangd 不支持
  3. 剔除 Engine 目录的 C++ 文件 — 跳转靠 index 缓存，不需要反复 parse
  4. 剔除 Intermediate 目录的条目 — PCH 头文件定义条目
  5. 剔除 uetemp/ndk 等无关条目
  6. 统一 Definitions.*.h 为公共版本，让 clangd preamble 缓存可复用
  7. (可选) 精简 -I/-D 参数，移除不存在的目录

用法:
  python slim_compile_commands.py <path_to_compile_commands.json> [--dry-run] [--keep-engine]

备份：自动在同目录生成 compile_commands.json.slim-bak
       （与 prebuild_pch_v2.py 的 .pre-pch.bak 互不干扰）
"""

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

# --- 剔除规则 ---

SKIP_FILE_PATTERNS = [
    r"\.generated\.(h|cpp)$",
    r"\.init\.gen\.c(pp)?$",
    r"\.gen\.cpp$",
    r"gen\.cpp$",
    r"PerModuleInline\.gen$",
]
SKIP_FILE_RE = re.compile("|".join(SKIP_FILE_PATTERNS), re.IGNORECASE)

# Shader 后缀 — clangd 完全不支持
SHADER_EXTS = frozenset({
    "usf", "ush", "hlsl", "glsl", "frag", "vert", "metal", "hlsli", "comp",
    "sf", "cg",  # 罕见但可能出现
})

# Engine 路径识别 (大小写不敏感)
ENGINE_PATH_RE = re.compile(
    r"[/\\]Engine[/\\](?:Source|Plugins|Shaders|Content|Intermediate|Binaries)[/\\]",
    re.IGNORECASE,
)

# Intermediate 目录
INTERMEDIATE_RE = re.compile(r"[/\\]Intermediate[/\\]", re.IGNORECASE)

# uetemp 目录
# UETEMP_RE removed — see categorize_entry() comment. Engine roots are
# sometimes literally named "uetemp" (D:/project/uetemp), so blanket-skipping
# any path containing /uetemp/ was a false positive.


# NDK / SDK 系统路径
SDK_RE = re.compile(
    r"[/\\](?:Android[/\\]Sdk|ndk)[/\\]",
    re.IGNORECASE,
)


def categorize_entry(entry: dict) -> str:
    """返回条目类别: keep / skip_generated / skip_shader / skip_engine / skip_intermediate / skip_other"""
    f = entry.get("file", "").replace("\\", "/")
    basename = f.rsplit("/", 1)[-1]

    # 1. 自动生成文件
    if SKIP_FILE_RE.search(f):
        return "skip_generated"

    # 2. Shader
    ext = f.rsplit(".", 1)[-1].lower() if "." in f else ""
    if ext in SHADER_EXTS:
        return "skip_shader"

    # 3. Intermediate 目录 — 跳过 generated 头/源，但保留 UE 的 unity TU
    #    Module.<Mod>.cpp / Module.<Mod>.N_of_M.cpp / Module.<Mod>.gen.N_of_M.cpp
    #    都在 Intermediate/Build/.../<Mod>/ 下，是合法的 clangd cdb entry。
    if INTERMEDIATE_RE.search(f):
        if basename.startswith("Module.") and basename.endswith(".cpp"):
            pass  # fall through to keep
        else:
            return "skip_intermediate"

    # 4. (removed) UETEMP_RE — historically skipped /uetemp/ as a temp build
    #    cache; but engine roots are now sometimes literally named "uetemp"
    #    (D:/project/uetemp). The rule was a false positive; rely on
    #    INTERMEDIATE_RE and explicit Engine root scoping instead.

    # 5. NDK/SDK
    if SDK_RE.search(f):
        return "skip_sdk"

    # 6. Engine 目录
    if ENGINE_PATH_RE.search(f):
        return "skip_engine"

    return "keep"


# --- Definitions.*.h 统一 ---

def unify_definitions(entries: list) -> list:
    """去掉 -include Definitions.*.h，让 preamble 缓存可复用。"""
    modified = 0
    for e in entries:
        args = e.get("arguments", [])
        new_args = []
        skip_next = False
        changed = False
        for i, a in enumerate(args):
            if skip_next:
                skip_next = False
                continue
            if a == "-include" and i + 1 < len(args):
                nxt = args[i + 1].replace("\\", "/")
                if "/Definitions." in nxt:
                    skip_next = True
                    changed = True
                    continue
            new_args.append(a)
        if changed:
            e["arguments"] = new_args
            modified += 1

    if modified:
        print(f"  去掉 Definitions.*.h 的条目数: {modified}")
    return entries


# --- 精简 include 路径 (可选) ---

def prune_nonexistent_includes(entries: list, check_fs: bool = False) -> list:
    """移除指向不存在目录的 -I 参数。仅在 --prune-includes 时启用。"""
    if not check_fs:
        return entries

    # 缓存目录存在性检查
    dir_exists_cache = {}
    removed_total = 0

    for e in entries:
        args = e.get("arguments", [])
        new_args = []
        removed = 0
        i = 0
        while i < len(args):
            a = args[i]
            # -I/path 或 -I /path
            if a.startswith("-I"):
                if a == "-I" and i + 1 < len(args):
                    # -I <dir>
                    d = args[i + 1].replace("\\", "/")
                    if d not in dir_exists_cache:
                        # 转换为可检查的路径
                        check = d
                        if check[1:3] == ":/":
                            check = "/mnt/" + check[0].lower() + check[2:]
                        dir_exists_cache[d] = os.path.isdir(check)
                    if dir_exists_cache[d]:
                        new_args.append(a)
                        new_args.append(args[i + 1])
                    else:
                        removed += 1
                    i += 2
                    continue
                else:
                    # -I/path
                    d = a[2:].replace("\\", "/")
                    if d not in dir_exists_cache:
                        check = d
                        if len(check) > 2 and check[1:3] == ":/":
                            check = "/mnt/" + check[0].lower() + check[2:]
                        dir_exists_cache[d] = os.path.isdir(check)
                    if dir_exists_cache[d]:
                        new_args.append(a)
                    else:
                        removed += 1
                    i += 1
                    continue
            new_args.append(a)
            i += 1

        if removed > 0:
            e["arguments"] = new_args
            removed_total += removed

    if removed_total:
        print(f"  移除不存在的 -I 目录: {removed_total} (总计)")
        print(f"  目录检查缓存大小: {len(dir_exists_cache)}")
    return entries


def strip_unnecessary_flags(entries: list) -> list:
    """剥离 clangd indexing 不需要的编译参数，缩短命令行。

    保留: -I, -D, -include, -include-pch, -std=, -x, -target, --target,
          -f 语义相关 (rtti, exceptions, modules, char8_t 等), 源文件路径
    移除: -W* (诊断由 .clangd 控制), -O* (优化), -g* (调试信息),
          -c (隐含), -o <file> (输出), -fcolor-diagnostics, -ffunction-sections,
          -fdata-sections, -fvisibility*, -fmessage-length, -fmacro-backtrace-limit,
          -fdiagnostics-*, -MF/-MD/-MT (依赖跟踪)
    """
    # -f flags that affect code semantics (MUST keep)
    KEEP_F_PREFIXES = (
        '-frtti', '-fno-rtti',
        '-fexceptions', '-fno-exceptions',
        '-fmodules', '-fcxx-modules', '-fno-modules',
        '-fchar8_t', '-fno-char8_t',
        '-fshort-wchar', '-fno-short-wchar',
        '-fshort-enums', '-fno-short-enums',
        '-fms-extensions', '-fno-ms-extensions',
        '-fms-compatibility', '-fno-ms-compatibility',
        '-fdelayed-template-parsing', '-fno-delayed-template-parsing',
        '-fsized-deallocation', '-fno-sized-deallocation',
        '-faligned-allocation', '-fno-aligned-allocation',
        '-fpic', '-fPIC', '-fpie', '-fPIE',
    )
    # Flags to strip entirely
    STRIP_PREFIXES = ('-W', '-O')
    STRIP_EXACT = {'-c', '-g', '-g0', '-g1', '-g2', '-g3', '-ggdb',
                   '-gdwarf', '-gdwarf-2', '-gdwarf-3', '-gdwarf-4', '-gdwarf-5'}
    # Flags that consume the next argument
    STRIP_WITH_NEXT = {'-o', '-MF', '-MT', '-MQ'}
    # -f flags to strip (non-semantic)
    STRIP_F_PREFIXES = (
        '-fcolor-', '-fdiagnostics-', '-ffunction-section', '-fdata-section',
        '-fvisibility', '-fmessage-length', '-fmacro-backtrace-limit',
        '-fno-profile', '-fprofile', '-fstack-protector', '-fno-stack-protector',
        '-faddrsig', '-fno-addrsig', '-fuse-ld', '-flto', '-fno-lto',
        '-fsave-optimization', '-fno-save-optimization', '-fcoverage',
        '-ftime-trace', '-fcrash-diagnostics',
    )

    total_removed = 0
    for e in entries:
        args = e.get("arguments", [])
        new_args = []
        i = 0
        removed = 0
        while i < len(args):
            a = args[i]

            # Strip -o <file>, -MF <file>, etc.
            if a in STRIP_WITH_NEXT:
                removed += 2
                i += 2
                continue

            # Strip -MD, -MMD (standalone, no arg)
            if a in ('-MD', '-MMD', '-MP'):
                removed += 1
                i += 1
                continue

            # Strip -W*, -O*
            if any(a.startswith(p) for p in STRIP_PREFIXES):
                removed += 1
                i += 1
                continue

            # Strip exact matches
            if a in STRIP_EXACT:
                removed += 1
                i += 1
                continue

            # Strip non-semantic -f flags (but keep semantic ones)
            if a.startswith('-f') or a.startswith('-fno-'):
                if any(a.startswith(p) for p in KEEP_F_PREFIXES):
                    new_args.append(a)
                elif any(a.startswith(p) for p in STRIP_F_PREFIXES):
                    removed += 1
                    i += 1
                    continue
                else:
                    new_args.append(a)  # unknown -f flag: keep it safe
            else:
                new_args.append(a)
            i += 1

        if removed > 0:
            e["arguments"] = new_args
            total_removed += removed

    if total_removed:
        avg = total_removed / len(entries) if entries else 0
        print(f"  剥离无用编译参数: {total_removed} 个 (avg {avg:.0f}/entry)")
    return entries


def main():
    parser = argparse.ArgumentParser(description="精简 compile_commands.json")
    parser.add_argument("path", help="compile_commands.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="只打印统计，不修改文件")
    parser.add_argument("--keep-engine", action="store_true",
                        help="保留 Engine 目录的 C++ 文件 (默认剔除)")
    parser.add_argument("--prune-includes", action="store_true",
                        help="移除指向不存在目录的 -I 参数 (较慢，需要文件系统检查)")
    args = parser.parse_args()

    path = os.path.abspath(args.path)
    if not os.path.isfile(path):
        print(f"文件不存在: {path}", file=sys.stderr)
        sys.exit(1)

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    original_count = len(data)
    original_size = os.path.getsize(path)

    # 分类统计
    stats = {}
    kept = []
    for e in data:
        cat = categorize_entry(e)
        if args.keep_engine and cat == "skip_engine":
            cat = "keep"
        stats[cat] = stats.get(cat, 0) + 1
        if cat == "keep":
            kept.append(e)

    print(f"原始条目: {original_count}")
    print(f"原始大小: {original_size / 1048576:.1f} MB")
    print()
    for cat in ["keep", "skip_generated", "skip_shader", "skip_engine",
                 "skip_intermediate", "skip_sdk"]:
        count = stats.get(cat, 0)
        if count > 0:
            pct = count * 100 / original_count
            marker = " ✓" if cat == "keep" else " ✗"
            print(f"  {cat:20s}: {count:6d} ({pct:5.1f}%){marker}")

    removed = original_count - len(kept)
    print(f"\n保留: {len(kept)} | 剔除: {removed} ({removed*100/original_count:.1f}%)")

    # 统一 Definitions —— 已禁用：删除 -include Definitions.<Module>.h 会导致
    # PCH 缺失 UE_BUILD_DEVELOPMENT / WITH_EDITOR 等关键 build configuration
    # 宏，clangd 加载 PCH 后宏环境不匹配 → AST 失效 → 所有 UE 类型显示
    # "unknown type name 'int32'/'TCHAR'" 等，整片代码飘红。
    # preamble 缓存复用的小优化不值得 correctness 损失。
    # kept = unify_definitions(kept)

    # 剥离 clangd 不需要的编译参数
    kept = strip_unnecessary_flags(kept)

    # 精简 include 路径
    if args.prune_includes:
        print("\n检查 -I 目录存在性...")
        kept = prune_nonexistent_includes(kept, check_fs=True)

    if args.dry_run:
        est_size = original_size * len(kept) / original_count
        print(f"\n预估新大小: {est_size / 1048576:.1f} MB")
        print("(dry-run 模式，未修改文件)")
        return

    if removed == 0 and not args.prune_includes:
        # Even with no entries removed, flags were stripped — always write
        pass

    # 备份 (使用不同后缀，不覆盖 PCH 脚本的备份)
    bak = path + ".slim-bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print(f"\n备份: {bak}")
    else:
        print(f"\n备份已存在: {bak}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(kept, f, ensure_ascii=False)

    new_size = os.path.getsize(path)
    print(f"新大小: {new_size / 1048576:.1f} MB (减少 {(1 - new_size/original_size)*100:.0f}%)")
    print("完成。重启 clangd 使生效。")

    # 同步到 Engine 目录 (如果存在)
    parent = os.path.dirname(path)
    engine_cc = os.path.join(parent, "Engine", "compile_commands.json")
    if os.path.isfile(engine_cc):
        shutil.copy2(path, engine_cc)
        print(f"已同步到: {engine_cc}")


if __name__ == "__main__":
    main()
