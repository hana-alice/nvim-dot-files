#!/usr/bin/env python3
"""
prebuild_pch_v2.py - 为 clangd 预编译 SharedPCH/PCH 头文件

完整流程:
  1. 分析 compile_commands.json 中的 PCH 分组
  2. 为每个 PCH 生成 .rsp (response file) + 编译 .bat 脚本
  3. 修改 compile_commands.json: -include X.h -> -include-pch X.pch
  4. 路径全部用正斜杠（避免 clangd/clang driver 转义问题）

用法:
  python prebuild_pch_v2.py <PROJ_DRIVE>/UEProj/compile_commands.json
  然后在 Windows cmd 执行生成的 build_pch.bat
"""
import json
import os
import re
import shutil
import sys
from collections import defaultdict
from pathlib import PurePosixPath


def wsl_to_win(p):
    """WSL 路径 -> Windows 路径"""
    if p.startswith("/mnt/"):
        return p[5].upper() + ":" + p[6:]
    return p


def to_forward_slash(p):
    return p.replace("\\", "/")


def _resolve_pch_header(raw_path, directory):
    """Normalize a PCH header path (may use backslashes / be relative)
    into an absolute forward-slash path. directory is the cdb entry's
    'directory' field (already forward-slashed)."""
    p = to_forward_slash(raw_path).strip().strip('"')
    # Windows absolute D:/ etc.
    if len(p) > 1 and p[1] == ':':
        return p
    if p.startswith('/') and not p.startswith('/mnt/'):
        # POSIX abs (rare on UE), keep as-is
        return p
    if directory:
        return os.path.normpath(os.path.join(directory, p)).replace('\\', '/')
    return p


def _detect_pch_in_args(args, directory):
    """Detect a PCH header reference in either clang form (-include X.h)
    or clang-cl / MSVC form (/Yu<path>, /Yu "<path>", or split /Yu <path>).
    Returns (form, header_arg_index, header_path_abs, header_path_raw) or None.

    form: 'clang' for -include, 'cl-yu' for /Yu joined, 'cl-yu-split' for /Yu split.
    header_arg_index: position in args of the path-bearing argument
        (for clang & cl-yu-split it's the SECOND arg; for cl-yu joined it's the
         single /Yu<path> arg).
    """
    for j, a in enumerate(args):
        # Clang form: -include X.h  (we only treat SharedPCH./PCH. as PCH)
        if a == '-include' and j + 1 < len(args):
            nxt = to_forward_slash(args[j + 1])
            if 'SharedPCH.' in nxt or '/PCH.' in nxt:
                abs_h = _resolve_pch_header(args[j + 1], directory)
                return ('clang', j + 1, abs_h, args[j + 1])
        # MSVC/clang-cl JOINED form: /Yu<path> or /Yu"<path>"
        elif a.startswith('/Yu') and a != '/Yu':
            raw = a[3:]  # strip /Yu
            nxt = to_forward_slash(raw)
            if 'SharedPCH.' in nxt or '/PCH.' in nxt or nxt.endswith('.h'):
                abs_h = _resolve_pch_header(raw, directory)
                return ('cl-yu', j, abs_h, raw)
        # MSVC/clang-cl SPLIT form: /Yu <path>
        elif a == '/Yu' and j + 1 < len(args):
            nxt = to_forward_slash(args[j + 1])
            if 'SharedPCH.' in nxt or '/PCH.' in nxt or nxt.endswith('.h'):
                abs_h = _resolve_pch_header(args[j + 1], directory)
                return ('cl-yu-split', j + 1, abs_h, args[j + 1])
    return None


def extract_pch_groups(entries):
    """按 SharedPCH/PCH 头文件分组，解析相对路径为绝对路径.
    支持 -include (clang) 和 /Yu (clang-cl/MSVC) 两种 PCH 引用形式."""
    groups = defaultdict(lambda: {"indices": [], "sample_args": None,
                                   "original_header": None, "abs_header": None,
                                   "form": None})
    for i, e in enumerate(entries):
        args = e.get("arguments", [])
        directory = to_forward_slash(e.get("directory", ""))
        det = _detect_pch_in_args(args, directory)
        if det is None:
            continue
        form, _idx, abs_h, raw_h = det
        # 用 basename 作 key（不同目录可能有相同 PCH）
        basename = PurePosixPath(abs_h).stem
        key = basename
        groups[key]["indices"].append(i)
        if groups[key]["sample_args"] is None:
            groups[key]["sample_args"] = args[:]
            groups[key]["original_header"] = raw_h
            groups[key]["abs_header"] = abs_h
            groups[key]["form"] = form
    return groups


def resolve_path(p, directory):
    """如果路径是相对路径，基于 directory 解析为绝对路径（正斜杠）"""
    p = to_forward_slash(p)
    # Windows 绝对路径: D:/... 或 /开头
    if len(p) > 1 and p[1] == ":":
        return p
    if p.startswith("/"):
        return p
    # 相对路径 -> 绝对
    return os.path.normpath(os.path.join(directory, p)).replace("\\", "/")


def extract_compile_flags(args, directory="", form="clang", drop_pch_header=None):
    """Extract flags needed to (re-)compile a PCH from a sample compile entry.

    form='clang'  : drop -include, -x c++, -o, etc. caller will append
                    `-x c++-header -o <out> <header>` and call clang++.
    form='cl-yu'  : drop /Yu* /Yc* /Fp* and /FI<drop_pch_header>. Keep all
                    other cl-style flags. caller will append `/Yc<header>
                    /Fp<output> /c <header>` and call clang-cl.

    drop_pch_header (str or None): when form='cl-yu', any /FI argument that
        references this header (raw, before backslash normalization) is
        dropped — UE often duplicates the PCH as both /Yu and /FI.
    """
    flags = []
    skip_next = False
    resolve_next = False  # next arg is a path that needs resolving
    drop_pch_header_norm = (to_forward_slash(drop_pch_header).strip().strip('"').lower()
                            if drop_pch_header else None)
    for i, a in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if resolve_next:
            resolve_next = False
            if directory:
                a = resolve_path(a, directory)
            flags.append(a)
            continue
        # 跳过不需要的参数 (clang form)
        if a in ("-c", "-o", "-MF", "-MT", "-MQ", "-MD", "-MMD",
                  "-Werror", "-no-canonical-prefixes"):
            if a in ("-o", "-MF", "-MT", "-MQ"):
                skip_next = True
            continue
        # cl form: drop /c /Fo<...> /Fd<...> /MD /MT /MDd /MTd-style outputs
        if form == 'cl-yu':
            # cl-style PCH directives — we will re-emit our own
            if a.startswith('/Yu') or a.startswith('/Yc') or a.startswith('/Fp'):
                if a in ('/Yu', '/Yc', '/Fp'):
                    skip_next = True
                continue
            # /FI<header> when it duplicates the PCH header — drop too
            if a.startswith('/FI') and a != '/FI' and drop_pch_header_norm:
                raw = a[3:].strip().strip('"')
                if to_forward_slash(raw).lower() == drop_pch_header_norm:
                    continue
            if a == '/FI' and i + 1 < len(args) and drop_pch_header_norm:
                if to_forward_slash(args[i + 1]).strip().strip('"').lower() == drop_pch_header_norm:
                    skip_next = True
                    continue
            # cl: /c (compile only), /Fo<obj>, /Fd<pdb>, /Fa, /Fe, /diagnostics:
            if a == '/c':
                continue
            if a.startswith('/Fo') or a.startswith('/Fd') or a.startswith('/Fa') or a.startswith('/Fe'):
                continue
            # /sourceDependencies (MSBuild dep tracking)
            if a.startswith('/sourceDependencies'):
                if a == '/sourceDependencies':
                    skip_next = True
                continue
        # -fdiagnostics-format 连写或分写
        if a == "-fdiagnostics-format" or a.startswith("-fdiagnostics-format="):
            if a == "-fdiagnostics-format":
                skip_next = True
            continue
        if a.startswith("-o") and len(a) > 2:
            continue
        # 跳过源文件（最后一个参数是 .cpp/.c/.mm/.m）
        if i == len(args) - 1:
            ext = PurePosixPath(to_forward_slash(a)).suffix.lower()
            if ext in (".cpp", ".c", ".cc", ".cxx", ".mm", ".m"):
                continue
        # 跳过 -include (我们在末尾单独加 PCH 头)  (clang form only)
        if form == 'clang' and a == "-include":
            skip_next = True
            continue
        # 跳过编译器路径（第一个参数）
        if i == 0:
            continue
        # 跳过 -x c++ (我们会在末尾加 -x c++-header)
        if a == "-x" and i + 1 < len(args) and args[i + 1] in ("c++", "c"):
            skip_next = True
            continue
        # 分写的路径参数: -I path, -isystem path, -imsvc path, --sysroot path
        if a in ("-I", "-isystem", "-imsvc", "--sysroot", "-isysroot"):
            flags.append(a)
            resolve_next = True
            continue
        # 解析连写路径型参数的相对路径
        if directory:
            a = _resolve_flag_path(a, directory)
        flags.append(a)
    return flags


def _resolve_flag_path(flag, directory):
    """解析 -I, -isystem, --sysroot=, -imsvc 等 flag 中的相对路径"""
    # -Ipath (连写)
    for prefix in ("-I", "-isystem", "-imsvc"):
        if flag.startswith(prefix) and len(flag) > len(prefix) and flag[len(prefix)] != "=":
            path_part = flag[len(prefix):]
            return prefix + resolve_path(path_part, directory)
    # --sysroot=path, -isysroot=path 等
    for prefix in ("--sysroot=", "-isysroot=", "--gcc-toolchain="):
        if flag.startswith(prefix):
            path_part = flag[len(prefix):]
            return prefix + resolve_path(path_part, directory)
    # -I path, -isystem path 这种分写的已经在 caller 里处理了（它们是独立参数）
    # 纯路径参数（前一个 flag 是 -I 等，这种情况 flag 本身就是路径）
    # 不以 - 开头的、看起来像路径的
    if not flag.startswith("-") and ("/" in flag or ".." in flag):
        return resolve_path(flag, directory)
    return flag


def _flatten_split_path_flags(flags):
    """Merge split path flags (-I path -> -Ipath) for response files.
    clang-cl reads each rsp line as a separate token and breaks on split
    `-I path` form. Joined `-Ipath` (or `/I path`) works in both drivers.
    """
    out = []
    JOIN_PREFIXES = ('-I', '-isystem', '-imsvc', '-isysroot')
    i = 0
    while i < len(flags):
        a = flags[i]
        if a in JOIN_PREFIXES and i + 1 < len(flags):
            out.append(a + flags[i + 1])
            i += 2
            continue
        if a == '--sysroot' and i + 1 < len(flags):
            out.append(f'--sysroot={flags[i + 1]}')
            i += 2
            continue
        out.append(a)
        i += 1
    return out


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <compile_commands.json>")
        sys.exit(1)

    cc_path = os.path.abspath(sys.argv[1])
    with open(cc_path) as f:
        data = json.load(f)

    groups = extract_pch_groups(data)
    print(f"条目: {len(data)}, PCH 种类: {len(groups)}")
    if not groups:
        print("没有 SharedPCH/PCH 条目")
        return

    # 提取 directory (所有条目通常相同)
    first_group = next(iter(groups.values()))
    first_idx = first_group["indices"][0]
    default_directory = to_forward_slash(data[first_idx].get("directory", ""))

    cc_dir = os.path.dirname(cc_path)
    pch_dir = os.path.join(cc_dir, ".clangd-pch")
    os.makedirs(pch_dir, exist_ok=True)

    # Windows 路径 (正斜杠)
    pch_dir_win = to_forward_slash(wsl_to_win(pch_dir))

    # Detect dominant form: count entries per form
    forms_seen = {}
    for info in groups.values():
        forms_seen[info.get('form', 'clang')] = forms_seen.get(info.get('form', 'clang'), 0) + len(info['indices'])
    print(f"PCH refs by form: {forms_seen}")

    bat_lines = [
        "@echo off",
        'set "CLANG_GCC=C:\\Program Files\\LLVM\\bin\\clang++.exe"',
        'set "CLANG_CL=C:\\Program Files\\LLVM\\bin\\clang-cl.exe"',
        "",
    ]

    pch_map = {}

    for basename, info in sorted(groups.items(), key=lambda x: -len(x[1]["indices"])):
        pch_output = f"{pch_dir_win}/{basename}.pch"
        rsp_path = os.path.join(pch_dir, f"{basename}.rsp")
        rsp_path_win = to_forward_slash(wsl_to_win(rsp_path))
        abs_header = info["abs_header"]
        form = info.get("form", "clang")

        count = len(info["indices"])
        print(f"  {count:5d} files  {basename}  ({form})")

        flags = extract_compile_flags(info["sample_args"], default_directory,
                                      form=form,
                                      drop_pch_header=info.get("original_header"))
        # rsp files: merge -I/-isystem/-imsvc/-isysroot/--sysroot split form
        flags = _flatten_split_path_flags(flags)

        # 写 response file (每行一个参数, 路径用正斜杠)
        with open(rsp_path, "w", newline="\n") as f:
            for flag in flags:
                if " " in flag:
                    f.write(f'"{flag}"\n')
                else:
                    f.write(f"{flag}\n")
            if form == 'clang':
                f.write("-x\n")
                f.write("c++-header\n")
                f.write("-Wno-everything\n")
                f.write("-o\n")
                f.write(f"{pch_output}\n")
                f.write(f"{abs_header}\n")
            else:  # cl-yu / cl-yu-split — use clang-cl /Yc /Fp + stub.cpp
                # MSVC /Yc requires a source file that #include's the PCH
                # header. We synthesize a one-liner stub.cpp per PCH.
                stub_path = os.path.join(pch_dir, f"{basename}.stub.cpp")
                with open(stub_path, "w", newline="\n") as sf:
                    sf.write(f'#include "{abs_header}"\n')
                f.write("/Wv:0\n")  # silence ALL warnings (cl form)
                f.write(f"/Yc{abs_header}\n")
                f.write(f"/Fp{pch_output}\n")
                f.write(f"/Fo{pch_output}.obj\n")  # stub obj output
                f.write("/c\n")
                f.write(f"/Tp{to_forward_slash(wsl_to_win(stub_path))}\n")

        # bat 里用 @rsp 调用 — 不同 form 用不同编译器
        bat_lines.append(f'echo Building {basename}.pch ({count} files, form={form})...')
        if form == 'clang':
            bat_lines.append(f'"%CLANG_GCC%" "@{rsp_path_win}"')
        else:
            bat_lines.append(f'"%CLANG_CL%" "@{rsp_path_win}"')
        bat_lines.append(f'if %ERRORLEVEL% EQU 0 (echo   OK) else (echo   FAILED)')
        bat_lines.append("")

        pch_map[basename] = pch_output

    bat_lines.append("echo Done.")

    # 写 bat 脚本
    bat_path = os.path.join(pch_dir, "build_pch.bat")
    with open(bat_path, "w", newline="\r\n") as f:
        f.write("\n".join(bat_lines))
    print(f"\nBAT 脚本: {bat_path}")

    # 修改 compile_commands: 把 PCH 引用改为 -include-pch X.pch (正斜杠)
    # 三种形式都要处理：clang -include / cl-yu (joined) / cl-yu-split
    modified = 0
    for basename, info in groups.items():
        pch_path = pch_map.get(basename)
        if not pch_path:
            continue
        original_header = info["original_header"]
        form = info.get("form", "clang")
        for idx in info["indices"]:
            args = data[idx]["arguments"]
            new_args = []
            skip_next = False
            replaced_this_entry = False
            for i, a in enumerate(args):
                if skip_next:
                    skip_next = False
                    continue
                # clang form: -include X.h  ->  -include-pch X.pch
                if (form == 'clang' and a == "-include" and i + 1 < len(args)
                        and args[i + 1] == original_header
                        and not replaced_this_entry):
                    new_args.append("-include-pch")
                    new_args.append(pch_path)
                    skip_next = True
                    modified += 1
                    replaced_this_entry = True
                    continue
                # cl-yu joined: /Yu<path>  ->  -include-pch X.pch
                # NB: clang-cl driver also accepts -include-pch transparently;
                # we drop /Yu entirely since the cdb is for clangd indexing,
                # not for clang-cl actual compilation.
                if (form == 'cl-yu' and a.startswith('/Yu') and a != '/Yu'
                        and not replaced_this_entry):
                    raw = a[3:].strip().strip('"')
                    if raw == original_header:
                        new_args.append("-include-pch")
                        new_args.append(pch_path)
                        modified += 1
                        replaced_this_entry = True
                        continue
                # cl-yu split: /Yu <path>  ->  -include-pch X.pch
                if (form == 'cl-yu-split' and a == '/Yu' and i + 1 < len(args)
                        and args[i + 1] == original_header
                        and not replaced_this_entry):
                    new_args.append("-include-pch")
                    new_args.append(pch_path)
                    skip_next = True
                    modified += 1
                    replaced_this_entry = True
                    continue
                new_args.append(a)
            data[idx]["arguments"] = new_args

    if modified == 0:
        print("\nNo changes needed — PCH already applied")
    else:
        # 备份
        bak = cc_path + ".pre-pch.bak"
        if not os.path.exists(bak):
            shutil.copy2(cc_path, bak)

        with open(cc_path, "w") as f:
            json.dump(data, f, ensure_ascii=False)

        # 同步到 Engine 子目录
        engine_cc = os.path.join(cc_dir, "Engine", "compile_commands.json")
        if os.path.isdir(os.path.dirname(engine_cc)):
            shutil.copy2(cc_path, engine_cc)
            print(f"同步: {engine_cc}")

    print(f"\n替换了 {modified} 个条目 (-include -> -include-pch)")
    print(f"\n下一步:")
    bat_win = to_forward_slash(wsl_to_win(bat_path)).replace("/", "\\")
    print(f"  在 cmd.exe 中执行: {bat_win}")


if __name__ == "__main__":
    main()
