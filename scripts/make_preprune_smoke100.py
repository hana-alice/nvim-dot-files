"""
Validate the prune module-local fix.
1. Load pre-prune baseline (full -I, no prune yet).
2. Take the same 100 file paths as smoke100.
3. Write a 100-entry pre-prune baseline.
4. Run modified prune on it.
5. Count whether victim dirs survived.
"""
import json
import os

BASELINE = r'<PROJ_DRIVE>/UnrealEngine/compile_commands.pre-prune.bak'
SMOKE100 = r'<PROJ_DRIVE>/UnrealEngine/compile_commands.smoke100.json'
OUT_BASELINE = r'<PROJ_DRIVE>/UnrealEngine/compile_commands.smoke100_preprune.json'

print('Loading smoke100 file list...')
with open(SMOKE100, 'r', encoding='utf-8') as f:
    smoke = json.load(f)
wanted_files = set()
for e in smoke:
    f_ = e.get('file')
    if f_:
        wanted_files.add(os.path.normpath(f_).lower())
print(f'  smoke100 unique files: {len(wanted_files)}')

print('Loading pre-prune baseline (this may take a minute, 437MB)...')
with open(BASELINE, 'r', encoding='utf-8') as f:
    baseline = json.load(f)
print(f'  baseline entries: {len(baseline)}')

print('Filtering baseline to smoke100 file set...')
out = []
for e in baseline:
    f_ = e.get('file')
    if not f_:
        continue
    if os.path.normpath(f_).lower() in wanted_files:
        out.append(e)
print(f'  matched entries: {len(out)}')

with open(OUT_BASELINE, 'w', encoding='utf-8') as f:
    json.dump(out, f)
sz = os.path.getsize(OUT_BASELINE)
print(f'  wrote {OUT_BASELINE}: {sz/1024/1024:.1f} MB')

# Quick sanity: count victim-dir occurrences in this pre-prune slice
joined = '\n'.join(' '.join(e.get('arguments', [])) for e in out)
victims = [
    'Engine/Source/Runtime/Core/Private',
    'Engine/Source/Runtime/Net/Core/Classes',
    'Engine/Plugins/FX/Niagara/Source/NiagaraEditor/Private',
    'ProjectNet/Private',
]
print('\nPre-prune victim dir occurrences (should be > 0):')
for v in victims:
    print(f'  {v}: {joined.count(v)}')
