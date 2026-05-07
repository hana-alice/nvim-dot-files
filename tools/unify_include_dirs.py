#!/usr/bin/env python3
"""
unify_include_dirs.py — 聚类统一同 PCH 组文件的 -I 目录以复用 clangd preamble

问题: UE 每个模块的 compile_commands 条目有不同的 -I 目录集,
      导致 clangd 为同 PCH 组的文件重复构建 preamble (各 ~1.9s)
      例: 最大 PCH 组 2527 个项目文件有 99 种 -I 变体

方案: 贪心聚类 — 把 -I 相似的变体合并, 控制每个文件的额外 overhead
      --max-overhead=50 表示合并后每个文件最多增加 50 个 -I dirs
      
      数据: 4.2ms / extra -I dir (实测), 50 dirs = +0.21s overhead
      原始: 99 variants, avg 151 dirs, 1.93s preamble
      聚类后: ~10 variants, avg ~170 dirs, ~2.0s preamble, 但 90% 更少的 preamble 重建

只处理项目文件, engine 条目保持原样

用法:
  python unify_include_dirs.py <compile_commands.json> [--dry-run] [--max-overhead 50]

必须在 slim_compile_commands.py 和 prebuild_pch_v2.py 之后运行
"""

import argparse
import json
import os
import re
import shutil
import sys
from collections import defaultdict

# Engine / non-project path patterns
ENGINE_RE = re.compile(
    r"[/\\]Engine[/\\](?:Source|Plugins|Shaders|Content|Intermediate|Binaries)[/\\]",
    re.IGNORECASE,
)
SKIP_RE = re.compile(
    r"[/\\](?:Intermediate|uetemp)[/\\]|[/\\](?:Android[/\\]Sdk|ndk)[/\\]",
    re.IGNORECASE,
)
SHADER_EXTS = frozenset({
    "usf", "ush", "hlsl", "glsl", "frag", "vert", "metal", "hlsli", "comp",
})


def is_project_file(filepath):
    """判断是否为项目文件 (非 engine/shader/intermediate)"""
    f = filepath.replace("\\", "/")
    ext = f.rsplit(".", 1)[-1].lower() if "." in f else ""
    if ext in SHADER_EXTS:
        return False
    if ENGINE_RE.search(f) or SKIP_RE.search(f):
        return False
    return True


def get_pch_name(args):
    for a in args:
        if '.pch' in a:
            return a.rsplit('/', 1)[-1].rsplit('\\', 1)[-1]
    return None


def extract_i_dirs(args):
    """提取所有 -I 目录路径"""
    dirs = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-I' and i + 1 < len(args):
            dirs.append(args[i + 1])
            i += 2
        elif a.startswith('-I') and len(a) > 2:
            dirs.append(a[2:])
            i += 1
        else:
            i += 1
    return dirs


def replace_i_dirs(args, new_i_args):
    """替换编译参数中的 -I 为新的统一列表"""
    result = []
    inserted = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-I' and i + 1 < len(args):
            if not inserted:
                result.extend(new_i_args)
                inserted = True
            i += 2
        elif a.startswith('-I') and len(a) > 2:
            if not inserted:
                result.extend(new_i_args)
                inserted = True
            i += 1
        else:
            result.append(a)
            i += 1
    return result


def greedy_cluster_overhead(variants, max_overhead):
    """贪心聚类: 限制每个变体被合并后的最大 overhead (额外 -I dirs 数量)

    关键改进: 不是限制 union 的绝对大小, 而是限制每个成员的 overhead。
    这防止小变体 (100 dirs) 被大变体 (492 dirs) 吸收。

    Args:
        variants: list of {'dirs': set, 'indices': list[int], 'count': int}
        max_overhead: 合并后每个成员最多增加的 -I 数量

    Returns:
        list of {'dirs': set, 'indices': list[int], 'count': int, 'n_variants': int,
                 'max_member_overhead': int}
    """
    # Sort by dir count ascending — similar-size variants merge better
    variants_sorted = sorted(variants, key=lambda v: len(v['dirs']))
    clusters = []

    for v in variants_sorted:
        best_cluster = None
        best_overhead = float('inf')

        for c in clusters:
            union = c['dirs'] | v['dirs']
            # Max overhead for any existing member
            overhead_existing = len(union) - len(c['dirs'])
            # Overhead for the new variant
            overhead_new = len(union) - len(v['dirs'])
            # Worst case overhead for this merge
            worst_overhead = max(overhead_existing + c['max_member_overhead'], overhead_new)

            if worst_overhead <= max_overhead and worst_overhead < best_overhead:
                best_cluster = c
                best_overhead = worst_overhead

        if best_cluster is not None:
            overhead_new = len(best_cluster['dirs'] | v['dirs']) - len(v['dirs'])
            overhead_existing = len(best_cluster['dirs'] | v['dirs']) - len(best_cluster['dirs'])
            best_cluster['max_member_overhead'] = max(
                best_cluster['max_member_overhead'] + overhead_existing,
                overhead_new
            )
            best_cluster['dirs'] = best_cluster['dirs'] | v['dirs']
            best_cluster['indices'].extend(v['indices'])
            best_cluster['count'] += v['count']
            best_cluster['n_variants'] += 1
        else:
            clusters.append({
                'dirs': set(v['dirs']),
                'indices': list(v['indices']),
                'count': v['count'],
                'n_variants': 1,
                'max_member_overhead': 0,
            })

    return clusters


# NOTE: 历史上这里曾有一个 `collapse_intermediate_inc()`,
# 把每个 entry 里 N 个 `-I.../Intermediate/.../Inc/<Module>` 折叠成单个
# `-I.../Intermediate/.../Inc` 父目录, 试图节省 preamble 时间。
#
# 这是一个 BUG, 已于 [本次提交] 移除。原因:
#   1) `-I` 不递归: 给 `-I.../Inc/` 看不到 `Inc/Engine/X.generated.h`,
#      clangd 在 UObject-heavy TU (如 StaticMeshRender.cpp) 上会冒出
#      "X.generated.h not found" + 大批继承断裂的假 diagnostics。
#   2) "*.generated.h 文件名全局唯一" 的假设在 UE 大型项目里不成立,
#      跨模块同名是常见现象, 折叠会真的丢路径。
#
# 它当时之所以没立刻爆: PCH 共享 + 同 commit 的聚类让大部分 TU 走 PCH
# 预热的 include path, generated.h 走 PCH 缓存命中而非直接 #include 解析,
# 把问题潜伏掉了 — 直到 PCH miss 的 TU 暴露。
#
# 如果未来真要再做"压 -I"的优化, 必须在 module 这一层 (`Inc/<Module>`)
# 之上再判断, 不能折到 `Inc/`。最简单的选择: 不要做这件事。


def main():
    parser = argparse.ArgumentParser(description="聚类统一项目文件的 -I 目录")
    parser.add_argument("path", help="compile_commands.json 路径")
    parser.add_argument("--dry-run", action="store_true", help="只打印统计")
    parser.add_argument("--max-overhead", type=int, default=50,
                        help="每个文件最多增加的 -I 目录数 (默认 50, ~0.2s preamble)")
    parser.add_argument("--include-engine", action="store_true",
                        help="也处理 Engine 文件 (用于纯引擎项目)")
    parser.add_argument("--no-collapse", action="store_true",
                        help=argparse.SUPPRESS)  # deprecated noop, kept for backwards compat
    args = parser.parse_args()

    path = os.path.abspath(args.path)
    if not os.path.isfile(path):
        print(f"文件不存在: {path}", file=sys.stderr)
        sys.exit(1)

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    original_size = os.path.getsize(path)

    # Pass 0 (Intermediate/Inc 折叠) 已被永久移除 — 那个折叠会让 clangd
    # 在 UObject-heavy TU 上找不到 *.generated.h。详见本文件顶部的 NOTE。
    if args.no_collapse:
        # 历史 flag, pipeline.lua 里以前会传 — 留个空壳避免老调用炸。
        pass

    # Group entries by PCH
    pch_groups = defaultdict(list)  # pch_name -> [(idx, dirs_tuple)]
    project_count = 0
    engine_count = 0

    for idx, entry in enumerate(data):
        filepath = entry.get("file", "")
        is_proj = is_project_file(filepath)
        if not is_proj and not args.include_engine:
            engine_count += 1
            continue
        if is_proj:
            project_count += 1
        else:
            engine_count += 1
        entry_args = entry.get("arguments", [])
        pch = get_pch_name(entry_args)
        if pch:
            dirs = extract_i_dirs(entry_args)
            pch_groups[pch].append((idx, tuple(sorted(dirs))))

    processed = project_count + (engine_count if args.include_engine else 0)
    skipped = engine_count if not args.include_engine else 0
    print(f"总条目: {len(data)} (处理: {processed}, 跳过: {skipped})")
    print(f"PCH 组: {len(pch_groups)}")
    print(f"max-overhead: {args.max_overhead} dirs (~{args.max_overhead * 4.2 / 1000:.1f}s preamble)")
    print()

    total_original_variants = 0
    total_new_variants = 0
    total_unified = 0

    for pch_name, entries_data in sorted(pch_groups.items(), key=lambda x: -len(x[1])):
        # Build variant groups
        variant_map = defaultdict(list)  # dirs_tuple -> [idx]
        for idx, dirs_key in entries_data:
            variant_map[dirs_key].append(idx)

        original_variants = len(variant_map)
        total_original_variants += original_variants

        if original_variants <= 1:
            total_new_variants += 1
            print(f"  {pch_name}: {len(entries_data)} files, 已统一 ✓")
            continue

        # Build variant objects for clustering
        variants = []
        for dirs_key, indices in variant_map.items():
            variants.append({
                'dirs': set(dirs_key),
                'indices': indices,
                'count': len(indices),
            })

        # Apply greedy clustering with overhead limit
        clusters = greedy_cluster_overhead(variants, args.max_overhead)
        new_variants = len(clusters)
        total_new_variants += new_variants

        # Compute stats
        avg_original = sum(len(dirs_t) for _, dirs_t in entries_data) / len(entries_data)
        max_cluster_dirs = max(len(c['dirs']) for c in clusters)
        avg_cluster_dirs = sum(len(c['dirs']) * c['count'] for c in clusters) / len(entries_data)

        print(f"  {pch_name}: {len(entries_data)} files, "
              f"{original_variants} → {new_variants} 变体, "
              f"avg -I: {avg_original:.0f} → {avg_cluster_dirs:.0f}, "
              f"max -I: {max_cluster_dirs}")

        # Show per-cluster detail for large groups
        if len(entries_data) >= 50:
            for ci, c in enumerate(sorted(clusters, key=lambda x: -x['count'])):
                print(f"    聚类 {ci}: {c['count']} files, {len(c['dirs'])} dirs, "
                      f"{c['n_variants']} 变体合并, max-overhead={c['max_member_overhead']}")

        total_unified += sum(c['count'] for c in clusters if c['n_variants'] > 1)

        if not args.dry_run:
            for c in clusters:
                if c['n_variants'] <= 1:
                    continue
                unified_i_args = [f"-I{d}" for d in sorted(c['dirs'])]
                for idx in c['indices']:
                    data[idx]["arguments"] = replace_i_dirs(
                        data[idx]["arguments"], unified_i_args
                    )

    print()
    print(f"项目 preamble 变体: {total_original_variants} → {total_new_variants}")
    print(f"统一了 {total_unified} 条目的 -I 目录")

    if args.dry_run:
        print("(dry-run, 未修改文件)")
        return

    if total_unified == 0:
        print("无需修改")
        return

    # Backup
    bak = path + ".pre-unify.bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print(f"备份: {bak}")

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)

    new_size = os.path.getsize(path)
    print(f"原始: {original_size / 1048576:.1f} MB → 新: {new_size / 1048576:.1f} MB"
          f" ({new_size / original_size:.1f}x)")
    print("完成。重启 clangd 使生效。")


if __name__ == "__main__":
    main()
