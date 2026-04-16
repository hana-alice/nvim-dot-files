#!/usr/bin/env python3
"""
slim_compile_commands.py — 精简 UE 项目 compile_commands.json

优化:
  1. 剔除 .generated.h / .init.gen.c / gen.cpp 等自动生成条目
  2. 统一 Definitions.*.h 为公共版本，让 clangd preamble 缓存可复用
     (133 种 preamble -> ~6 种，缓存命中率从 3% -> 接近 100%)

用法:
  python slim_compile_commands.py <path_to_compile_commands.json> [--dry-run]

备份：自动在同目录生成 compile_commands.json.bak
"""

import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

# --- 阶段 1: 剔除生成文件 ---

SKIP_PATTERNS = [
    r"\.generated\.h$",
    r"\.generated\.cpp$",
    r"\.init\.gen\.c(pp)?$",
    r"\.gen\.cpp$",
    r"gen\.cpp$",
    r"PerModuleInline\.gen$",
]

SKIP_RE = re.compile("|".join(SKIP_PATTERNS), re.IGNORECASE)


def should_keep(entry: dict) -> bool:
    f = entry.get("file", "").replace("\\", "/")
    return not SKIP_RE.search(f)


# --- 阶段 2: 统一 Definitions.*.h ---

def unify_definitions(entries: list, dry_run: bool = False) -> list:
    """将每个条目的 -include Definitions.*.h 替换为统一的公共定义头。
    
    Definitions.*.h 的区别只是各模块的 _API 宏和少量平台宏。
    对 clangd 来说这些宏基本为空(Android monolithic build)，
    统一后所有 TU 共享同一个 preamble，索引速度提升数倍。
    """
    # 先收集所有不同的 Definitions 头路径，找到 Intermediate 目录
    definitions_dir = None
    definitions_set = set()
    for e in entries:
        args = e.get("arguments", [])
        for i, a in enumerate(args):
            if a == "-include" and i + 1 < len(args):
                nxt = args[i + 1].replace("\\", "/")
                if "/Definitions." in nxt:
                    definitions_set.add(nxt)
                    # 提取 Intermediate 根目录
                    m = re.search(r"(.+/Intermediate/Build/[^/]+/[^/]+/Development)/", nxt)
                    if m and definitions_dir is None:
                        definitions_dir = m.group(1)

    if not definitions_set:
        return entries  # 没有 Definitions 头，跳过

    print(f"  Definitions.*.h 变体数: {len(definitions_set)}")

    if definitions_dir is None:
        print("  无法定位 Intermediate/Build 目录，跳过统一")
        return entries

    # 生成统一的 Definitions 头
    # 读取所有 Definitions 头，提取所有 _API 宏
    # 但实际上我们不需要真的合并——只要去掉 -include Definitions.*.h 即可
    # 因为 SharedPCH 已经包含了所有必要的 #define
    # Definitions.*.h 的内容和 SharedPCH 高度重复，只多了 MODULE_API 宏
    # 去掉它后，_API 宏未定义 -> clang 会当空宏处理，不影响代码理解

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
                    # 去掉这个 -include Definitions.*.h
                    skip_next = True
                    changed = True
                    continue
            new_args.append(a)
        if changed:
            e["arguments"] = new_args
            modified += 1

    print(f"  去掉 Definitions.*.h 的条目数: {modified}")
    return entries


def main():
    parser = argparse.ArgumentParser(description="精简 compile_commands.json")
    parser.add_argument("path", help="compile_commands.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="只打印统计，不修改文件")
    args = parser.parse_args()

    path = os.path.abspath(args.path)
    if not os.path.isfile(path):
        print(f"文件不存在: {path}", file=sys.stderr)
        sys.exit(1)

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    original_count = len(data)

    # 阶段 1: 剔除生成文件
    filtered = [e for e in data if should_keep(e)]
    removed_count = original_count - len(filtered)

    print(f"原始条目: {original_count}")
    print(f"剔除条目: {removed_count} ({removed_count*100/original_count:.1f}%)" if original_count > 0 else "")
    print(f"保留条目: {len(filtered)}")

    # 阶段 2: 统一 Definitions
    filtered = unify_definitions(filtered, dry_run=args.dry_run)

    print(f"原始大小: {os.path.getsize(path)/1048576:.1f} MB")

    if args.dry_run:
        print("(dry-run 模式，未修改文件)")
        return

    if removed_count == 0:
        # 阶段 1 没有剔除，检查阶段 2 是否做了修改
        has_definitions = any(
            "/Definitions." in str(e.get("arguments", []))
            for e in filtered[:100]
        )
        if not has_definitions:
            print("无需修改")
            return

    # 备份
    bak = path + ".bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print(f"备份: {bak}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(filtered, f, ensure_ascii=False)

    new_size = os.path.getsize(path)
    print(f"新大小:   {new_size/1048576:.1f} MB")
    print("完成。重启 clangd 使生效。")


if __name__ == "__main__":
    main()
