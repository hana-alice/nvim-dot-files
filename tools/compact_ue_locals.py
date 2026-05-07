#!/usr/bin/env python3
# Compact 17 single-line require-wrapper locals at top of ue.lua
# into one `local _ufs = require("ue.core.fs")` + 1 alias for trim (kept as alias because
# `trim` is referenced ~72 times AND we want minimal call-site churn).
# Strategy:
#   - 17 wrappers (lines ~57-123) -> 2 module locals (_ufs, _uproc) + 0 wrapper functions
#   - rewrite call sites:  trim(x) -> _ufs.trim(x)   etc.
# Keep these as aliases (not rewritten) to minimize churn AND save slots:
#   trim, norm, cwd, join  -> these 4 stay as `local foo = _ufs.foo` (4 slots)
# Net: 17 wrappers -> 4 aliases + 2 module tables = 6 slots. Save 11.
import re, sys
P = r"<LOCAL_APPDATA>\nvim\lua\ue.lua"
src = open(P, 'r', encoding='utf-8', newline='').read()

# Define groups
fs_funcs = ['trim','norm','cwd','join','dirname','is_dir','is_file','ensure_dir',
            'file_stat','file_mtime','path_has_prefix','is_absolute_path',
            'split_path','common_ancestor','relative_to']
proc_funcs = ['first_executable']
plat_funcs = ['is_native_windows']  # special: returns require("utils.platform").is_windows directly

# Keep these as local aliases (high-frequency, want short names)
keep_alias = {'trim','norm','cwd','join'}

# 1. Replace the wrapper-functions block (lines 57-123) with compact requires + aliases
old_block_pattern = re.compile(
    r'local function trim\(value\).*?return require\("utils\.platform"\)\.is_windows\nend\n',
    re.DOTALL
)
m = old_block_pattern.search(src)
if not m:
    print("ERROR: could not match wrapper block", file=sys.stderr)
    sys.exit(1)

new_block_lines = [
    '-- Cached module tables (was 17 single-line wrappers; compacted to save LuaJIT local slots).',
    'local _ufs = require("ue.core.fs")',
    'local _uproc = require("ue.core.proc")',
    'local _uplat = require("utils.platform")',
    '',
    '-- High-frequency aliases (kept short for readability).',
    'local trim = _ufs.trim',
    'local norm = _ufs.norm',
    'local cwd = _ufs.cwd',
    'local join = _ufs.join',
    '',
]
new_block = '\n'.join(new_block_lines) + '\n'
src2 = src[:m.start()] + new_block + src[m.end():]

# 2. Rewrite call sites for non-aliased functions.
# Use word-boundary so we don't touch e.g. `M.dirname` or `obj.dirname`.
def rewrite(name, prefix, text):
    # Match `name(` not preceded by `.` or alnum/underscore.
    pat = re.compile(r'(?<![\w.])' + re.escape(name) + r'\(')
    return pat.sub(f'{prefix}.{name}(', text)

for fn in fs_funcs:
    if fn in keep_alias:
        continue
    src2 = rewrite(fn, '_ufs', src2)
for fn in proc_funcs:
    src2 = rewrite(fn, '_uproc', src2)

# is_native_windows() -> _uplat.is_windows (NOTE: was a function returning .is_windows; now just direct field access)
# Carefully: replace `is_native_windows()` -> `_uplat.is_windows`
src2 = re.sub(r'(?<![\w.])is_native_windows\(\)', '_uplat.is_windows', src2)

open(P, 'w', encoding='utf-8', newline='').write(src2)

# Report
import subprocess
out = subprocess.run(['grep', '-c', '^local ', P], capture_output=True, text=True).stdout.strip()
print(f"After rewrite, ^local count: {out}")
