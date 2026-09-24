"""build_super_unity_cdb.py - 按 SharedPCH 分组合并 unity TU。

当前 build_unity_cdb 产 821 TU（每 module 1-N 个 Module.<Mod>.<i>.cpp）。
但 821 个 TU 各自 #include 同一份 SharedPCH（11 种 PCH 共享，分成 7 大组），
clangd-indexer 没有 preamble share → 重复 parse 7 大 PCH 821 次。

方案：把同 SharedPCH group 的 Module.<Mod>.cpp 集中成 1 个 super-unity.cpp
- 保留 .obj.rsp 的 args（任意 module 的，因为它们 SharedPCH 一致）
- super-unity.cpp 内容 = 所有成员 Module.X.cpp 的 #include
- 默认按 50 mods/unity 切分（控制单 TU 内存）

输出 CDB 含约 25 entry（vs 821）。
"""
import json, os, sys, re
from collections import defaultdict

# Establish this before imports: their bytecode writes precede module guards
# and would change the directory inventory used by semantic proof receipts.
sys.dont_write_bytecode = True
# Keep this module importable through the existing isolated Python launchers.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_hot_super_unity_cdb import (
    portable_member_path, rewritten_arguments, secondary_unity_chunks, write_if_changed,
)

RE_FI_PCH = re.compile(r'/FI"([^"]*(?:SharedPCH|PCH)\.[^"]*)"')

# Match #define X DLLEXPORT  or  #define X_NON_ATTRIBUTED_API DLLEXPORT  in Definitions.<Mod>.h
RE_API_DEF = re.compile(r'^\s*#\s*define\s+(\w+_API|\w+_NON_ATTRIBUTED_API)\s+(DLLEXPORT|DLLIMPORT)\s*$')

def winpath_local(p):
    if sys.platform.startswith('linux') and len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/' + p[2:].replace('\\', '/').lstrip('/')
    return p


def winpath_from_local(p):
    """/mnt/d/foo -> D:/foo"""
    if p.startswith('/mnt/') and len(p) > 6 and p[6] == '/':
        drive = p[5].upper()
        return f'{drive}:{p[6:]}'
    return p


def get_module_from_unity(file_path):
    """Module.<Mod>.cpp or Module.<Mod>.<N>.cpp -> <Mod>"""
    fp = file_path.replace('\\', '/')
    base = os.path.basename(fp)
    if base.startswith('Module.') and base.endswith('.cpp'):
        parts = fp.split('/')
        if len(parts) >= 2:
            return parts[-2]
    return None


def get_module_api_defines(dev_root_local, mod):
    """Read Definitions.<Mod>.h and return list of (NAME, VALUE) for *_API / *_NON_ATTRIBUTED_API.
    These are the per-module DLLEXPORT macros; they need to be re-applied per-module
    inside super-unity.cpp because all members are concatenated into one TU."""
    defs_h = f'{dev_root_local}/{mod}/Definitions.{mod}.h'
    if not os.path.isfile(defs_h):
        return []
    out = []
    try:
        for line in open(defs_h, encoding='utf-8', errors='replace'):
            m = RE_API_DEF.match(line)
            if m:
                out.append((m.group(1), m.group(2)))
    except OSError:
        pass
    return out


def find_shared_pch_for_module(dev_root_local, mod):
    mod_dir = f'{dev_root_local}/{mod}'
    if not os.path.isdir(mod_dir):
        return ('NONE',)
    rsps = [f for f in os.listdir(mod_dir) if f.startswith(f'Module.{mod}') and f.endswith('.obj.rsp')]
    if not rsps:
        return ('NONE',)
    try:
        content = open(f'{mod_dir}/{rsps[0]}', encoding='utf-8', errors='replace').read()
    except OSError:
        return ('NONE',)
    pchs = sorted(set(os.path.basename(m.group(1)) for m in RE_FI_PCH.finditer(content)))
    return tuple(pchs) if pchs else ('NONE',)


def build_generated_batches(entries, output_dir, max_originals=50, max_sources=2000):
    """Generate same-context, generated-only secondary UBT wrappers.

    This does not compile, index, publish or create a frozen/schema-2 receipt.
    Original entries are retained verbatim when membership cannot be verified;
    merged entries carry their complete originals for interactive CDB routing.
    The caller remains responsible for qualification and activation.
    """
    import copy
    import hashlib
    from collections import Counter
    from pathlib import Path

    if (type(max_originals) is not int or max_originals < 1
            or type(max_sources) is not int or max_sources < 1):
        raise ValueError('generated batch budgets must be positive integers')

    def key(path):
        return os.path.normcase(os.path.realpath(winpath_local(path)))

    overlay_cache = {}
    entry_overlays = {}

    def overlay_digest(path):
        with path.open('rb') as stream:
            return hashlib.file_digest(stream, 'sha256').hexdigest()

    def owned_overlay(path):
        identity = key(path)
        if identity not in overlay_cache:
            physical = Path(winpath_local(path))
            digest, valid = None, False
            try:
                digest = overlay_digest(physical)
                workaround_dir = Path(__file__).resolve().parents[1] / 'lua/workarounds/clangd'
                if str(workaround_dir) not in sys.path:
                    sys.path.insert(0, str(workaround_dir))
                from header_path_case import validate_owned_overlay
                validate_owned_overlay(physical)
                valid = overlay_digest(physical) == digest
            except (OSError, ValueError):
                pass
            overlay_cache[identity] = (physical, digest, valid)
        if not overlay_cache[identity][2]:
            raise ValueError('unsupported or changed VFS overlay')
        return identity

    marker = '// Compiler-authored UBT unity membership; copied into nvim cache.'
    literal_include = re.compile(r'#include "([^"\r\n\0]+)"')
    source_counts = Counter(key(os.path.join(
                                winpath_local(e['directory']) if isinstance(e.get('directory'), str) else '',
                                winpath_local(e['file'])))
                            for e in entries
                            if isinstance(e.get('file'), str) and e['file'])
    claims = Counter(source_counts)
    # Unverified metadata cannot admit a wrapper, but an ownership claim still
    # prevents batching the same portable member through another entry.
    metadata_claims = Counter(member for entry in entries
                              if isinstance(entry.get('nvim_ue_members'), list)
                              for member in entry['nvim_ue_members'] if isinstance(member, str))
    verified, contexts = {}, {}
    rejected = set()
    for index, entry in enumerate(entries):
        filename = entry.get('file', '')
        if not isinstance(filename, str):
            continue
        name = filename.replace('\\', '/').rsplit('/', 1)[-1]
        if not (name.startswith('SuperUnity.UBT.') and name.endswith('.cpp')):
            continue
        try:
            raw = Path(winpath_local(filename)).read_text(encoding='utf-8-sig')
            lines = raw.splitlines()
            # Count actual literal ownership even when metadata or other lines
            # invalidate a wrapper, so another batch cannot steal its members.
            includes = [match.group(1) for line in lines
                        if (match := literal_include.fullmatch(line))]
            claims.update(key(path) for path in includes if os.path.isabs(winpath_local(path)))
            if (not os.path.isabs(winpath_local(filename)) or not lines or lines[0] != marker
                    or not includes or len(includes) != len(lines) - 1
                    or any(not os.path.isabs(winpath_local(p)) or not os.path.isfile(winpath_local(p))
                           for p in includes)):
                raise ValueError('unsupported or unavailable wrapper membership')
            members = entry.get('nvim_ue_members')
            module = entry.get('nvim_ue_module_root')
            if (not isinstance(members, list)
                    or members != [portable_member_path(p) for p in includes]
                    or len(set(members)) != len(members)
                    or not isinstance(module, str) or not module
                    or entry.get('nvim_ue_generated_originals') is not None):
                raise ValueError('missing or inconsistent original metadata')
            if not all(path.lower().endswith('.gen.cpp') for path in includes):
                continue
            directory, args = entry.get('directory'), entry.get('arguments')
            if (not isinstance(directory, str) or not os.path.isabs(winpath_local(directory))
                    or not os.path.isdir(winpath_local(directory)) or not isinstance(args, list)
                    or len(args) < 2 or any(not isinstance(arg, str) or not arg for arg in args)):
                raise ValueError('unsupported compiler command')
            if any(arg.startswith('@') or arg == '--config'
                   or arg.startswith('--config=') for arg in args):
                raise ValueError('indirect compiler input')
            if any(arg.startswith(('-vfsoverlay', '--vfsoverlay', '/vfsoverlay',
                                   '-Xclang=-ivfsoverlay', '-Xclang=-vfsoverlay',
                                   '/clang:-ivfsoverlay', '/clang:-vfsoverlay')) for arg in args):
                raise ValueError('unsupported VFS overlay option')
            overlays = [i for i, arg in enumerate(args) if arg.startswith('-ivfsoverlay')]
            if overlays:
                position = overlays[0]
                if (len(overlays) != 1 or args[position] != '-ivfsoverlay'
                        or position == 0 or position + 1 >= len(args)
                        or args[position - 1] == '-Xclang'
                        or ('--' in args and position > args.index('--'))
                        or not os.path.isabs(winpath_local(args[position + 1]))):
                    raise ValueError('unsupported VFS overlay option')
                entry_overlays[index] = owned_overlay(args[position + 1])
            rewritten = rewritten_arguments(entry, '<SOURCE>')
            if rewritten is None or rewritten.count('<SOURCE>') != 1:
                raise ValueError('expected exactly one source operand')
            source_index = rewritten.index('<SOURCE>')
            if source_index == 0 or rewritten[source_index - 1] in (
                    '-include', '-include-pch', '-imacros', '-I', '-isystem', '-iquote',
                    '-idirafter', '-F', '-iframework', '-x', '-target', '--target', '-ivfsoverlay'):
                raise ValueError('source occurs as an option operand')
            # Preserve the full literal cwd and ordered semantic argv. The
            # helper's compact context hash is only a planner optimization.
            contexts[index] = (directory, tuple(rewritten))
            verified[index] = includes
        except (OSError, UnicodeError, ValueError, TypeError):
            rejected.add(index)

    # Reuse one validation per file's bytes, then bind every candidate to those
    # same bytes after collecting its originals. Never cache only by mtime.
    changed_overlays = set()
    for identity, (path, digest, valid) in overlay_cache.items():
        try:
            if not valid or overlay_digest(path) != digest:
                changed_overlays.add(identity)
        except OSError:
            changed_overlays.add(identity)

    eligible = []
    indexes = []
    for index, includes in verified.items():
        if (entry_overlays.get(index) in changed_overlays
                or source_counts[key(entries[index]['file'])] != 1
                or any(claims[key(p)] != 1 for p in includes)
                or any(metadata_claims[p] != 1 for p in entries[index]['nvim_ue_members'])):
            rejected.add(index)
            continue
        indexes.append(index)
        eligible.append(entries[index])

    replacements, consumed = {}, set()
    generated_sources = 0
    for planned in secondary_unity_chunks(eligible, max_sources=max_sources, max_unities=max_originals):
        chunk = [indexes[index] for index in planned]
        if any(contexts[index] != contexts[chunk[0]] for index in chunk[1:]):
            rejected.update(chunk)
            continue
        originals = [entries[index] for index in chunk]
        body = '// Generated-only secondary UBT unity; qualification is separate.\n' + ''.join(
            '#include "' + original['file'].replace('\\', '/') + '"\n' for original in originals)
        if any(char in original['file'] for original in originals for char in ('"', '\r', '\n', '\0')):
            rejected.update(chunk)
            continue
        identity = hashlib.sha256(json.dumps([body, contexts[chunk[0]]],
            ensure_ascii=False, separators=(',', ':')).encode('utf-8')).hexdigest()
        directory = Path(winpath_local(str(output_dir))).resolve()
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / ('SuperUnity.Generated.' + identity + '.cpp')
        write_if_changed(str(path), body)
        source = winpath_from_local(str(path))
        members = [member for original in originals for member in original['nvim_ue_members']]
        replacements[chunk[0]] = {
            'directory': originals[0]['directory'], 'file': source,
            'arguments': rewritten_arguments(originals[0], source),
            'nvim_ue_members': members, 'nvim_ue_module_root': originals[0]['nvim_ue_module_root'],
            'nvim_ue_generated_originals': copy.deepcopy(originals),
        }
        consumed.update(chunk)
        generated_sources += len(members)
    result = [replacements[index] if index in replacements else entry
              for index, entry in enumerate(entries) if index in replacements or index not in consumed]
    return result, {
        'input_entries': len(entries), 'output_entries': len(result),
        'secondary_groups': len(replacements), 'merged_originals': len(consumed),
        'generated_sources': generated_sources, 'retained_entries': len(entries) - len(consumed),
        'rejected_entries': len(rejected),
    }


def main():
    if len(sys.argv) < 3:
        print('usage: build_super_unity_cdb.py <unity_cdb> <out_cdb> [max_mods_per_unity]')
        return 1
    src = winpath_local(sys.argv[1])
    out = winpath_local(sys.argv[2])
    max_mods = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    cdb = json.load(open(src))
    print(f'Source unity CDB: {len(cdb)} entries', file=sys.stderr)
    if not cdb:
        return 1

    # Find dev_root from first entry
    first_file = cdb[0].get('file', '').replace('\\', '/')
    dev_root = None
    parts = first_file.split('/')
    if 'Development' in parts:
        idx = parts.index('Development')
        dev_root = '/'.join(parts[:idx + 1])
    if not dev_root:
        print('ERROR: no dev_root', file=sys.stderr)
        return 1
    dev_root_local = winpath_local(dev_root)

    # Group entries by SharedPCH set
    pch_cache = {}
    def get_pch(mod):
        if mod not in pch_cache:
            pch_cache[mod] = find_shared_pch_for_module(dev_root_local, mod)
        return pch_cache[mod]

    groups = defaultdict(list)  # pch_key -> [(mod, entry)]
    for e in cdb:
        mod = get_module_from_unity(e.get('file', ''))
        if not mod:
            continue
        pch = get_pch(mod)
        groups[pch].append((mod, e))

    print(f'Distinct SharedPCH groups: {len(groups)}', file=sys.stderr)
    for k, v in sorted(groups.items(), key=lambda x: -len(x[1])):
        print(f'  {len(v):>4d} TUs  →  {", ".join(k)}', file=sys.stderr)

    # Output dir for super-unity .cpp files
    out_dir = os.path.dirname(out) or '.'
    os.makedirs(out_dir, exist_ok=True)
    super_dir = os.path.join(out_dir, 'super_unity_cpps')
    os.makedirs(super_dir, exist_ok=True)
    # Clear old
    for f in os.listdir(super_dir):
        if f.endswith('.cpp'):
            os.remove(os.path.join(super_dir, f))

    new_cdb = []
    n_super = 0
    n_skipped_oversized = 0

    for pch_key, members in groups.items():
        # Slice into chunks
        pch_name = pch_key[0].replace('SharedPCH.', '').replace('.h', '').replace('.', '_') if pch_key != ('NONE',) else 'NONE'
        for chunk_idx, start in enumerate(range(0, len(members), max_mods)):
            chunk = members[start:start + max_mods]
            n_super += 1

            # Pick template entry from chunk[0]
            template_entry = chunk[0][1]

            # Build super-unity.cpp content
            super_cpp_local = f'{super_dir}/SuperUnity.{pch_name}.{chunk_idx}.cpp'
            super_cpp_win = winpath_from_local(super_cpp_local).replace('/', '\\')
            with open(super_cpp_local, 'w', encoding='utf-8') as f:
                f.write(f'// Super-unity for SharedPCH={pch_name}, chunk {chunk_idx}\n')
                f.write(f'// Members: {len(chunk)} unity TUs\n\n')
                for mod, e in chunk:
                    member_path = e['file'].replace('\\', '/')
                    api_defs = get_module_api_defines(dev_root_local, mod)
                    f.write(f'\n// ---- {mod} ({len(api_defs)} API macros) ----\n')
                    for name, val in api_defs:
                        f.write(f'#undef {name}\n#define {name} {val}\n')
                    f.write(f'#include "{member_path}"\n')

            # Build args: union of -I, -D, -U from ALL chunk members so each
            # module's Public/Private/Classes/UHT headers + per-module
            # DLLEXPORT macros (from Definitions.X.h, injected upstream) survive.
            # Without this, only chunk[0]'s -D set wins → other modules' API
            # macros undefined → indexer hits Build.h:47 #error UE_BUILD_DEBUG.
            #
            # CRITICAL: must handle BOTH glued (`-IPATH`, `-DNAME=val`) AND
            # split (`-I PATH`, `-D NAME=val`, `-include PATH`) forms. UBT
            # emits split form for absolute -I paths in modern CDBs. Treating
            # them as separate `-I` and `PATH` tokens during merge corrupts
            # the union (lone `-I` preserved, path string sorted into wrong
            # bucket → indexer sees `-I -ID:/...` which is a parse bomb).
            def _walk_member_args(args):
                """Yield ('inc'|'def'|'other', token_or_pair) preserving split forms."""
                n = len(args)
                i = 0
                while i < n:
                    a = args[i]
                    # split-form -I / -D / -U / -include / -isystem
                    if a in ('-I', '-D', '-U', '-include', '-isystem', '-imacros') and i + 1 < n:
                        kind = 'inc' if a in ('-I', '-include', '-isystem', '-imacros') else 'def'
                        yield kind, (a, args[i + 1])
                        i += 2
                        continue
                    # glued -IPATH / -DNAME[=VAL] / -UNAME
                    if (a.startswith('-I') and len(a) > 2) or a.startswith('-isystem='):
                        yield 'inc', (a,)
                        i += 1
                        continue
                    if (a.startswith('-D') and len(a) > 2) or (a.startswith('-U') and len(a) > 2):
                        yield 'def', (a,)
                        i += 1
                        continue
                    yield 'other', (a,)
                    i += 1

            base_args = list(template_entry.get('arguments', []))
            all_includes = []  # list of tuples
            seen_inc = set()
            all_defines = []
            seen_def = set()
            for _, mem_e in chunk:
                for kind, payload in _walk_member_args(mem_e.get('arguments', [])):
                    key = '\x00'.join(payload)
                    if kind == 'inc' and key not in seen_inc:
                        seen_inc.add(key)
                        all_includes.append(payload)
                    elif kind == 'def' and key not in seen_def:
                        seen_def.add(key)
                        all_defines.append(payload)
            # Strip template's -I/-D/-U/-include (any form); we re-insert union.
            new_args = []
            for kind, payload in _walk_member_args(base_args):
                if kind == 'other':
                    new_args.extend(payload)
            # Flatten union back into args
            flat_inc = [tok for tup in all_includes for tok in tup]
            flat_def = [tok for tup in all_defines for tok in tup]
            # Insert union right after clang++ executable (preserves arg ordering
            # for clang's remaining flags that follow).
            new_args = new_args[:1] + flat_inc + flat_def + new_args[1:]
            # Swap file path
            old_cpp = template_entry['file']
            for i, a in enumerate(new_args):
                if a == old_cpp:
                    new_args[i] = super_cpp_win
                    break

            new_cdb.append({
                'directory': template_entry['directory'],
                'arguments': new_args,
                'file': super_cpp_win,
            })

    print(f'Super-unity TUs created: {n_super} (vs {len(cdb)} original)', file=sys.stderr)
    print(f'Compression: {len(cdb)/n_super:.1f}x', file=sys.stderr)

    with open(out, 'w', encoding='utf-8') as f:
        json.dump(new_cdb, f)
    print(f'Wrote: {out}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
