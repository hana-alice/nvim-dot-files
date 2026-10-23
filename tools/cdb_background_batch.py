"""Bounded proof jobs and cache-only publication of independently proven batches.

The caller owns host admission, concurrency and publication intervals. Each worker
owns one private proof store and never reads a production shard cache as evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cdb_verified_batch as verified
from build_hot_super_unity_cdb import secondary_unity_chunks, strict_unity_chunks, tier2_unity_chunks, write_outputs_if_changed

_LARGE_PACKING = {'max_unities': 32, 'budget_factor': 32}
_LARGE_POLICY = {'version': 1, 'max_proposals': 2, 'packing': _LARGE_PACKING}
_RESIDUAL_POLICY = {'version': 1, 'ordering': 'members-desc-index'}


def _json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _write(path, value):
    return write_outputs_if_changed([(str(path), _json(value))])


def _publication_content(path, value):
    """Retain generator bytes when commands and marker fields are unchanged."""
    try:
        previous = Path(path).read_bytes().decode('utf-8')
        if json.loads(previous) == value:
            return previous, False
    except (FileNotFoundError, ValueError, UnicodeError):
        pass
    return json.dumps(value), True


def encode_preserving(path, value):
    """Encode changed JSON; preserve existing bytes for an equal semantic value."""
    return _publication_content(path, value)[0]


def _read_source(path, expected=None):
    raw = Path(path).read_bytes()
    digest = _sha(raw)
    if expected is not None and digest != expected:
        raise ValueError('background-proof-input-changed')
    entries = json.loads(raw.decode('utf-8'))
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise ValueError('background-proof-entry-list-required')
    return entries, digest


def _mode():
    """Tier 1 is the production default; strict preserves the graph-proof path."""
    mode = os.environ.get('NVIM_UE_BATCH_TIER', '1').strip().lower()
    if mode not in ('1', 'strict'):
        raise ValueError('background-proof-unsupported-tier: ' + mode)
    return mode


def _group_packing(mode, packing=None):
    if packing is None:
        return {}
    if (mode != '1' or not isinstance(packing, dict)
            or set(packing) != {'max_unities', 'budget_factor'}
            or any(type(value) is not int or not 1 <= value <= 32 for value in packing.values())):
        raise ValueError('background-proof-invalid-tier1-packing')
    return dict(packing)


def _chunks(entries, mode, packing=None):
    limits = _group_packing(mode, packing)
    if mode == 'strict':
        return strict_unity_chunks(entries, max_sources=80, max_unities=8)
    options = dict(max_unities=limits.get('max_unities', 8), budget_factor=limits.get('budget_factor'))
    if verified.tier2_enabled():
        cross = tier2_unity_chunks(entries, **verified.tier2_grouping_options(**options))
        claimed = {index for chunk in cross for index in chunk}
        remaining = [index for index in range(len(entries)) if index not in claimed]
        local = secondary_unity_chunks([entries[index] for index in remaining],
            **verified.tier1_grouping_options(**options))
        return sorted(cross + [[remaining[index] for index in chunk] for chunk in local], key=min)
    return secondary_unity_chunks(entries, **verified.tier1_grouping_options(**options))


def _recipe_options(value):
    if 'recipe' not in value:
        return {}
    if value['recipe'] != verified._TIER1_PREFIX_RECIPE:
        raise ValueError('background-proof-unknown-tier1-recipe')
    return {'recipe': value['recipe']}


def _strict_recipe_options(value):
    if 'strict_recipe' not in value:
        return {}
    import cdb_ordered_batch
    cdb_ordered_batch.descriptor(value['strict_recipe'])
    limits = value.get('strict_limits')
    if (not isinstance(limits, dict) or set(limits) != {'max_group', 'max_sources'}
            or type(limits['max_group']) is not int or not 2 <= limits['max_group'] <= 32
            or type(limits['max_sources']) is not int or not 1 <= limits['max_sources'] <= 2000
            or any(key in value for key in ('recipe', 'packing', 'upgrade_of', 'fallback_of', 'schedule_role'))):
        raise ValueError('background-proof-invalid-ordered-limits')
    return dict(strict_recipe=value['strict_recipe'], **limits)


def _identity(entries, mode, recipe=None, strict_recipe=None, max_group=8, max_sources=80):
    value = entries if mode == 'strict' else {'tier': 1, 'entries': entries}
    if mode == '1' and recipe is None and verified.tier2_enabled():
        value['tier2'] = True
    if recipe is not None:
        if mode != '1':
            raise ValueError('background-proof-recipe-requires-tier1')
        value['recipe'] = verified._tier1_recipe(entries, recipe)
    if mode == 'strict':
        forced_prefix, _ = verified._strict_forced_prefix(entries)
        if forced_prefix:
            value = {'entries': entries, 'forced_prefix': forced_prefix}
    if strict_recipe is not None:
        if mode != 'strict' or recipe is not None:
            raise ValueError('background-proof-ordered-requires-strict')
        import cdb_ordered_batch
        value = {'entries': entries, 'ordered_recipe': cdb_ordered_batch.descriptor(strict_recipe),
                 'limits': {'max_group': max_group, 'max_sources': max_sources}}
    return _sha(_json(value).encode('utf-8'))


def _cache_only(entries, store, clangd, profile, mode=None, packing=None, recipe=None,
                strict_recipe=None, max_group=8, max_sources=80):
    mode = mode or _mode()
    if strict_recipe is not None:
        if mode != 'strict' or packing is not None or recipe is not None:
            raise ValueError('background-proof-ordered-requires-strict')
        if not Path(store).is_dir():
            return list(entries), dict(_empty_metrics(entries), groups=[{
                'original_indexes': list(range(len(entries))), 'accepted': False, 'deferred': True,
                'reason': 'verification-not-cached', 'run_metrics': []}])
        return verified.accelerate(entries, store, clangd, max_group=max_group, max_sources=max_sources,
            group_indexes=list(range(len(entries))), strict_recipe=strict_recipe,
            verify_missing=False, server_profile=profile)
    limits = _group_packing(mode, packing)
    if mode == '1':
        try:
            # Only a confirmed-absent namespace short-circuits to cache misses.
            # Any other state (a file, or an unreadable stat) keeps the verifier path.
            namespaces = ['tier1', 'tier2'] if verified.tier2_enabled() and recipe is None else ['tier1']
            present = False
            for namespace in namespaces:
                try:
                    (Path(store) / namespace / 'receipts').stat()
                    present = True
                except FileNotFoundError:
                    continue
            if not present:
                raise FileNotFoundError
        except FileNotFoundError:
            groups = [{'original_indexes': chunk, 'original_ubt_count': len(chunk),
                'accepted': False, 'cached': False, 'deferred': True,
                'reason': 'verification-not-cached', 'run_metrics': []}
                for chunk in _chunks(entries, mode, packing)]
            return list(entries), dict(_empty_metrics(entries), groups=groups,
                cache_hits=0, new_proof_count=0, new_batch_count=0, proof_directory=None)
        except OSError:
            pass  # Unknown namespace state retains the existing verifier path.
        # The Tier 1 cache binds wrappers, member sources and owned overlays.
        # Header changes deliberately do not invalidate its receipt.
        return verified.reuse_tier1(entries, store, clangd, max_group=limits.get('max_unities', 8),
            server_profile=profile, **({'budget_factor': limits['budget_factor']} if limits else {}),
            **({'recipe': recipe} if recipe is not None else {}))
    if not Path(store).is_dir():
        # accelerate creates its artifact root even in cache-only mode. An
        # absent advisory store must not mutate watched lookup inventories.
        metrics = _empty_metrics(entries)
        groups = [{'original_indexes': chunk, 'accepted': False, 'deferred': True,
            'reason': 'verification-not-cached', 'run_metrics': []}
            for chunk in _chunks(entries, mode)]
        return list(entries), dict(metrics, groups=groups)
    return verified.accelerate(entries, store, clangd, max_group=8, max_sources=80,
        verify_missing=False, server_profile=profile)


def _empty_metrics(entries):
    ubt = sum(verified._is_ubt(entry) for entry in entries)
    shaders = {'.usf', '.ush', '.hlsl', '.hlsli', '.glsl', '.vert', '.frag', '.geom', '.tesc', '.tese', '.comp', '.metal'}
    shader = sum(Path(entry.get('file', '')).suffix.lower() in shaders for entry in entries)
    exact = sum(not verified._is_ubt(entry) and Path(entry.get('file', '')).suffix.lower()
        in ('.c', '.cc', '.cpp', '.cxx', '.c++') for entry in entries)
    return {'original_ubt_count': ubt, 'exact_count': exact, 'shader_count': shader,
        'other_count': len(entries) - ubt - shader - exact, 'batch_count': 0, 'groups': []}


def _tier1_receipt(entries, candidate, recipe=None):
    raw = Path(candidate['nvim_ue_tier1_receipt']).read_bytes()
    if _sha(raw) != candidate.get('nvim_ue_tier1_receipt_sha256'):
        raise ValueError('background-proof-tier1-receipt-sha-mismatch')
    receipt = json.loads(raw.decode('utf-8'))
    members = [member for entry in entries for member in entry['nvim_ue_members']]
    if candidate.get('nvim_ue_tier') == 2:
        if (not verified.tier2_enabled() or recipe is not None
                or receipt.get('schema') != 1 or receipt.get('tier') != 2
                or receipt.get('accepted') is not True or receipt.get('reusable') is not True
                or receipt.get('original_entries') != [verified._native(entry) for entry in entries]
                or receipt.get('candidate') != verified._native(candidate)
                or not all(receipt.get('gates', {}).get(name) is True for name in verified._TIER2_GATES)
                or receipt.get('inputs') != verified._tier2_inputs(entries)
                or len(members) != len(set(members))
                or receipt.get('members') != candidate.get('nvim_ue_members')
                or sorted(receipt.get('members', [])) != sorted(members)):
            raise ValueError('background-proof-tier2-receipt-mismatch')
        return
    descriptor = verified._tier1_recipe(entries, recipe)
    if (receipt.get('schema') != 1 or receipt.get('tier') != 1
            or receipt.get('accepted') is not True or receipt.get('reusable') is not True
            or receipt.get('original_entries') != [verified._native(entry) for entry in entries]
            or receipt.get('candidate') != verified._native(candidate)
            or not all(receipt.get('gates', {}).get(name) is True for name in
                ('compile_success', 'main_shards_complete', 'members_equal'))
            or len(members) != len(set(members))
            or receipt.get('members') != candidate.get('nvim_ue_members')
            or sorted(receipt.get('members', [])) != sorted(members)
            or receipt.get('recipe') != descriptor or candidate.get('nvim_ue_tier1_recipe') != descriptor):
        raise ValueError('background-proof-tier1-receipt-mismatch')


def _replacements(entries, output, metrics, mode=None):
    """Accept replacements only for groups actually admitted by the proof gate."""
    anchors, consumed, claimed, recipes = {}, set(), set(), {}
    for record in metrics['groups']:
        if not record.get('accepted'):
            continue
        indexes = record['original_indexes']
        if (len(indexes) < 2 or any(type(index) is not int or index < 0 or index >= len(entries)
                for index in indexes) or len(set(indexes)) != len(indexes)
                or claimed.intersection(indexes)):
            raise ValueError('background-proof-invalid-admitted-group')
        if not all(verified._is_ubt(entries[index]) for index in indexes):
            raise ValueError('background-proof-non-ubt-replacement')
        anchor = min(indexes)
        anchors[anchor] = indexes
        recipes[anchor] = _recipe_options(record)
        consumed.update(index for index in indexes if index != anchor)
        claimed.update(indexes)
    if len(output) != len(entries) - len(consumed):
        raise ValueError('background-proof-coverage-mismatch')
    replacements, cursor = {}, 0
    for index, entry in enumerate(entries):
        if index in consumed:
            continue
        value = output[cursor]
        cursor += 1
        if index in anchors:
            tier = mode or _mode()
            receipt_key = 'nvim_ue_tier1_receipt' if tier == '1' else 'nvim_ue_batch_receipt'
            if not value.get(receipt_key):
                raise ValueError('background-proof-missing-receipt')
            if tier == '1':
                _tier1_receipt([entries[position] for position in anchors[index]], value, **recipes[index])
            replacements[index] = value
        elif value != entry:
            raise ValueError('background-proof-original-command-changed')
    return replacements, consumed, claimed


def _catalog_path(store, mode=None, strict_recipe=None):
    root = Path(store).resolve().parent / 'background-proofs'
    if strict_recipe is not None:
        import cdb_ordered_batch
        cdb_ordered_batch.descriptor(strict_recipe)
        if mode != 'strict':
            raise ValueError('background-proof-ordered-requires-strict')
        return root / 'ordered-generated' / 'catalog.json'
    return (root / 'tier1' if (mode or _mode()) == '1' else root) / 'catalog.json'


def _catalog(store, mode=None, strict_recipe=None):
    mode = mode or _mode()
    try:
        value = json.loads(_catalog_path(store, mode, strict_recipe).read_text(encoding='utf-8'))
        groups = value['groups'] if (value.get('schema') == 1 and value.get('mode', 'strict') == mode
            and value.get('strict_recipe') == strict_recipe
            and isinstance(value.get('groups'), list)) else []
    except (OSError, ValueError, TypeError, KeyError):
        groups = []
    if mode == 'strict' and strict_recipe is None:
        import cdb_ordered_batch
        groups += _catalog(store, mode, cdb_ordered_batch.RECIPE)
    return groups


def _tuple_key(entry):
    if not verified._is_ubt(entry):
        return None
    generated = [member.lower().endswith('.gen.cpp') for member in entry['nvim_ue_members']]
    return (entry['nvim_ue_module_root'], verified.compile_context_key(entry),
        'gen' if all(generated) else 'mixed' if any(generated) else 'src')


def _upgrade_sequence(entries, indexes, sequences=None, *, sequence_provider=None):
    if not indexes or indexes != sorted(indexes):
        raise ValueError('background-proof-upgrade-order-changed')
    key = _tuple_key(entries[indexes[0]])
    if key is None or any(_tuple_key(entries[index]) != key for index in indexes):
        raise ValueError('background-proof-upgrade-tuple-mismatch')
    if sequences is None and sequence_provider is not None:
        sequences = sequence_provider()
    sequence = (sequences.get(key, []) if sequences is not None else
        [index for index, entry in enumerate(entries) if _tuple_key(entry) == key])
    start = sequence.index(indexes[0])
    if sequence[start:start + len(indexes)] != indexes:
        raise ValueError('background-proof-upgrade-sequence-gap')


def _upgrade_owners(entries, indexes, records):
    selected = set(indexes)
    owners, covered = [], set()
    for record in records:
        if not record.get('accepted'):
            continue
        owned = set(record['original_indexes'])
        if not selected.intersection(owned):
            continue
        if not owned.issubset(selected):
            raise ValueError('background-proof-upgrade-partial-owner')
        owners.append(_identity([entries[index] for index in record['original_indexes']], '1', **_recipe_options(record)))
        covered.update(owned)
    return sorted(owners), len(owners) + len(selected - covered)


def _whole_flat_owner(indexes, records):
    selected = set(indexes)
    owners = [record for record in records if record.get('accepted')
        and selected.intersection(record['original_indexes'])]
    return (len(owners) == 1 and set(owners[0]['original_indexes']) == selected
        and 'recipe' not in owners[0])


def _automatic_large_groups(entries, ordinary, groups, records, store, clangd, profile, recovered):
    """Join whole current owners and ordinary fallback atoms in tuple order."""
    keys = [_tuple_key(entry) for entry in entries]
    sequences = {}
    for index, key in enumerate(keys):
        if key is not None:
            sequences.setdefault(key, []).append(index)
    positions = {index: position for sequence in sequences.values() for position, index in enumerate(sequence)}
    atoms, claimed, barriers = {}, set(), set()
    for record in records:
        if not record.get('accepted'):
            continue
        indexes = record['original_indexes']
        claimed.update(indexes)
        owner_keys = {keys[index] for index in indexes}
        for key in owner_keys:
            sequence = sequences[key]
            owned = [index for index in indexes if keys[index] == key]
            span = sequence[min(positions[index] for index in owned):max(positions[index] for index in owned) + 1]
            if len(owner_keys) != 1 or span != indexes:
                barriers.update(span)
            else:
                atoms.update((index, indexes) for index in indexes)
    for chunk in ordinary:
        if len({entries[index]['nvim_ue_module_root'] for index in chunk}) > 1:
            barriers.update(chunk)
            continue  # Cross-module owners cannot enter same-tuple upgrades.
        if not claimed.intersection(chunk):
            atoms.update((index, chunk) for index in chunk)
    ordinary_set = {tuple(chunk) for chunk in ordinary}
    manual = [group for group in groups if 'packing' in group]
    for group in groups:
        # Recovered manual proofs keep their own queue path and cannot be split.
        if 'packing' in group or tuple(group['indexes']) not in ordinary_set:
            barriers.update(group['indexes'])
    pending = [set(group['indexes']) for group in groups
        if 'packing' not in group and group['id'] not in recovered]
    candidates = []

    def fits(indexes):
        if len(indexes) > _LARGE_PACKING['max_unities']:
            return False
        try:
            return len(indexes) == 1 or _chunks([entries[index] for index in indexes], '1', _LARGE_PACKING) == [list(range(len(indexes)))]
        except (OSError, ValueError, KeyError, TypeError):
            return False

    def emit(indexes, atom_count):
        if atom_count < 2:
            return
        owners, count = _upgrade_owners(entries, indexes, records)
        if count > 1:
            selected = set(indexes)
            candidates.append((sum(chunk.issubset(selected) for chunk in pending), indexes, owners))

    for sequence in sequences.values():
        current, atom_count = [], 0
        for index in sequence:
            atom = atoms.get(index, [index])
            if atom[0] != index:
                continue
            if barriers.intersection(atom):
                emit(current, atom_count)
                current, atom_count = [], 0
                continue
            joined = current + atom
            if not fits(joined):
                emit(current, atom_count)
                current, atom_count = [], 0
                if not fits(atom):
                    continue
                joined = atom
            current, atom_count = joined, atom_count + 1
        emit(current, atom_count)
    proposals = []
    limit = min(_LARGE_POLICY['max_proposals'] - sum(
        group.get('schedule_role') == 'large-first' for group in groups), 32 - len(manual))
    for _, indexes, owners in sorted(candidates, key=lambda item: (item[0] < 2, tuple(item[1]))):
        if len(proposals) >= limit:
            break
        selected = [entries[index] for index in indexes]
        identity = _identity(selected, '1')
        if any(group['id'] == identity for group in groups):
            continue
        group = {'id': identity, 'indexes': indexes,
            'store': str(_catalog_path(store, '1').parent / identity),
            'ubt_count': len(indexes), 'member_count': sum(len(entry['nvim_ue_members']) for entry in selected),
            'packing': dict(_LARGE_PACKING), 'upgrade_of': owners, 'schedule_role': 'large-first'}
        _group({'mode': '1', 'legacy_store': str(store), 'groups': [group]}, entries, identity, ordinary)
        _, cached = _cache_only(selected, group['store'], clangd, profile, '1', group['packing'])
        if any(record.get('cached') and not record.get('accepted') and not record.get('deferred')
                for record in cached['groups']):
            continue
        proposals.append(group)
    return proposals


def _validate_schedule(plan, entries):
    """Scheduling edges never replace each linked group's existing proof gate."""
    groups = plan['groups']
    scheduling = any('schedule_role' in group or 'fallback_of' in group for group in groups)
    if 'tier1_large_policy' not in plan and not scheduling:
        return
    if plan.get('mode') != '1' or plan.get('tier1_large_policy') != _LARGE_POLICY:
        raise ValueError('background-proof-invalid-large-policy')
    identities = [group['id'] for group in groups]
    if len(set(identities)) != len(identities):
        raise ValueError('background-proof-duplicate-schedule-group')
    sequences = {}
    for index, entry in enumerate(entries):
        key = _tuple_key(entry)
        if key is not None:
            sequences.setdefault(key, []).append(index)
    # Preserve plan-time fallback boundaries when source sizes later change.
    # These scheduling atoms grant no proof or cache admission.
    ordinary = plan.get('tier1_ordinary_atoms')
    if not isinstance(ordinary, list):
        raise ValueError('background-proof-invalid-schedule-atoms')
    atom_members = set()
    for indexes in ordinary:
        if (not isinstance(indexes, list) or not 2 <= len(indexes) <= 8
                or any(type(index) is not int or not 0 <= index < len(entries) for index in indexes)
                or len(set(indexes)) != len(indexes) or atom_members.intersection(indexes)):
            raise ValueError('background-proof-invalid-schedule-atoms')
        if len({entries[index]['nvim_ue_module_root'] for index in indexes}) == 1:
            _upgrade_sequence(entries, indexes, sequences)
        elif not (verified.tier2_enabled() and tier2_unity_chunks(
                [entries[index] for index in indexes], **verified.tier2_grouping_options())
                == [list(range(len(indexes)))]):
            raise ValueError('background-proof-invalid-schedule-atoms')
        atom_members.update(indexes)
    ordinary_set = {tuple(indexes) for indexes in ordinary}

    def definition(group, limit):
        indexes = group['indexes']
        if (not isinstance(indexes, list) or not 2 <= len(indexes) <= limit
                or any(type(index) is not int or not 0 <= index < len(entries) for index in indexes)
                or len(set(indexes)) != len(indexes)):
            raise ValueError('background-proof-invalid-schedule-indexes')
        selected = [entries[index] for index in indexes]
        _upgrade_sequence(entries, indexes, sequences)
        if (_identity(selected, '1') != group['id'] or Path(group['store']).resolve()
                != _catalog_path(plan['legacy_store'], '1').parent / group['id']
                or type(group.get('ubt_count')) is not int or group['ubt_count'] != len(indexes)
                or type(group.get('member_count')) is not int
                or group['member_count'] != sum(len(entry['nvim_ue_members']) for entry in selected)):
            raise ValueError('background-proof-schedule-identity-mismatch')

    parents = {}
    covered = set()
    for group in groups:
        if 'schedule_role' not in group:
            continue
        if (group['schedule_role'] != 'large-first' or 'fallback_of' in group
                or group.get('packing') != _LARGE_PACKING or 'upgrade_of' not in group):
            raise ValueError('background-proof-invalid-large-parent')
        definition(group, _LARGE_PACKING['max_unities'])
        owners = group['upgrade_of']
        if (not isinstance(owners, list) or any(not isinstance(value, str) or len(value) != 64
                or any(char not in '0123456789abcdef' for char in value) for value in owners)
                or len(set(owners)) != len(owners)):
            raise ValueError('background-proof-invalid-upgrade-owners')
        indexes = set(group['indexes'])
        if covered.intersection(indexes):
            raise ValueError('background-proof-overlapping-large-parents')
        covered.update(indexes)
        parents[group['id']] = indexes
    if len(parents) > _LARGE_POLICY['max_proposals']:
        raise ValueError('background-proof-too-many-large-parents')
    children, deferred = set(), 0
    for group in groups:
        if group['id'] in parents:
            continue
        indexes = set(group['indexes'])
        overlaps = [identity for identity, parent in parents.items() if indexes.intersection(parent)]
        if 'fallback_of' not in group:
            if overlaps:
                raise ValueError('background-proof-unlinked-large-overlap')
            continue
        parent = group['fallback_of']
        if (not isinstance(parent, str) or parent not in parents or overlaps != [parent]
                or 'packing' in group or 'upgrade_of' in group
                or tuple(group['indexes']) not in ordinary_set or not indexes < parents[parent]
                or children.intersection(indexes)):
            raise ValueError('background-proof-invalid-large-fallback')
        definition(group, 8)
        children.update(indexes)
        deferred += 1
    if (type(plan.get('deferred_fallback_count')) is not int or plan['deferred_fallback_count'] != deferred
            or type(plan.get('initially_ready_count')) is not int
            or plan['initially_ready_count'] != len(groups) - deferred):
        raise ValueError('background-proof-invalid-large-counts')


def _upgrade_relationships(entries, indexes, upgrade_of, store, ordinary_groups=None):
    """Check diagnostic owner IDs against original commands, never grant reuse."""
    if (not isinstance(upgrade_of, list)
            or any(not isinstance(value, str) or len(value) != 64
                or any(char not in '0123456789abcdef' for char in value) for value in upgrade_of)
            or len(set(upgrade_of)) != len(upgrade_of)):
        raise ValueError('background-proof-invalid-upgrade-owners')
    # A leading singleton may shift the selected slice's greedy boundaries.
    # Root-store owners retain the full CURRENT input's original packing.
    selected = [entries[index] for index in indexes]
    included = set(indexes)
    if ordinary_groups is None:
        ordinary_groups = _chunks(entries, '1')
    known = {_identity([entries[index] for index in chunk], '1') for chunk in ordinary_groups
        if set(chunk).issubset(included)}
    selected_hashes = {_sha(_json(entry).encode('utf-8')): entry for entry in selected}
    for owner in _catalog(store, '1'):
        try:
            hashes = owner['entry_hashes']
            if (not isinstance(hashes, list) or len(hashes) < 2 or len(set(hashes)) != len(hashes)
                    or not all(value in selected_hashes for value in hashes)):
                continue
            original = [selected_hashes[value] for value in hashes]
            if (owner['id'] == _identity(original, '1', **_recipe_options(owner)) and Path(owner['store']).resolve()
                    == _catalog_path(store, '1').parent / owner['id']):
                known.add(owner['id'])
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if not set(upgrade_of).issubset(known):
        raise ValueError('background-proof-upgrade-owner-identity-mismatch')


def _catalog_group(entries, positions, value, store, mode, ordinary_groups=None, *, sequence_provider=None):
    hashes = value['entry_hashes']
    if not isinstance(hashes, list) or any(len(positions.get(item, [])) != 1 for item in hashes):
        raise ValueError('background-proof-catalog-originals-ambiguous')
    group = dict(value, indexes=[positions[item][0] for item in hashes])
    group.setdefault('ubt_count', len(group['indexes']))
    group.setdefault('member_count', sum(len(entries[index].get('nvim_ue_members', [])) for index in group['indexes']))
    _group({'mode': mode, 'legacy_store': str(store), 'groups': [group]}, entries, group['id'], ordinary_groups,
        sequence_provider=sequence_provider)
    return group


def _apply_upgrade(entries, group, clangd, profile, replacements, records, *, persisted=False):
    """Revalidate one exact candidate before atomically replacing whole owners."""
    observation = {'id': group['id'], 'original_indexes': group['indexes'], 'accepted': False}
    try:
        indexes = group['indexes']
        selected = [entries[index] for index in indexes]
        owners, previous_count = _upgrade_owners(entries, indexes, records)
        recipe_options = _recipe_options(group)
        if (recipe_options and not persisted and owners != [group['id']]
                and not _whole_flat_owner(indexes, records)):
            raise ValueError('background-proof-recipe-current-flat-owner-required')
        output, metrics = _cache_only(selected, group['store'], clangd, profile, '1', group['packing'], **recipe_options)
        local, _, claimed = _replacements(selected, output, metrics, '1')
        observation['groups'] = metrics['groups']
        admitted = [record for record in metrics['groups'] if record.get('accepted')]
        if (len(output) != 1 or set(local) != {0} or claimed != set(range(len(selected)))
                or len(admitted) != 1 or admitted[0]['original_indexes'] != list(range(len(selected)))):
            observation['reason'] = 'background-proof-upgrade-not-exactly-qualified'
            observation['cached_rejection'] = (len(metrics['groups']) == 1
                and metrics['groups'][0]['original_indexes'] == list(range(len(selected)))
                and metrics['groups'][0].get('cached') is True
                and not metrics['groups'][0].get('accepted') and not metrics['groups'][0].get('deferred'))
            return replacements, records, observation
        candidate = local[0]
        if previous_count <= 1:
            if owners == [group['id']] and replacements.get(min(indexes)) == candidate:
                observation.update(accepted=True, reason='background-proof-upgrade-already-selected')
                return replacements, records, observation
            elif recipe_options:
                pass  # Explicit whole-owner migration, or a persisted independently valid recipe owner.
            else:
                observation['reason'] = 'background-proof-upgrade-does-not-reduce-tus'
                return replacements, records, observation
        selected_set = set(indexes)
        replaced = [record for record in records if record.get('accepted')
            and selected_set.intersection(record['original_indexes'])]
        proposed = dict(replacements)
        for record in replaced:
            proposed.pop(min(record['original_indexes']))
        proposed[min(indexes)] = candidate
        updated = [record for record in records if not (record.get('accepted')
            and selected_set.intersection(record['original_indexes']))]
        updated.append(dict(admitted[0], original_indexes=indexes))
        observation.update(accepted=True, reason='background-proof-upgrade-selected', upgrade_of=owners)
        return proposed, updated, observation
    except (OSError, ValueError, KeyError, TypeError) as error:
        observation['reason'] = str(error)
        return replacements, records, observation


def _render_selection(entries, replacements, records):
    """Combine already revalidated candidates; do not reread their receipts."""
    consumed, claimed, anchors = set(), set(), set()
    for record in records:
        if not record.get('accepted'):
            continue
        indexes = record['original_indexes']
        if (len(indexes) < 2 or len(set(indexes)) != len(indexes)
                or any(type(index) is not int or not 0 <= index < len(entries) for index in indexes)
                or claimed.intersection(indexes)):
            raise ValueError('background-proof-invalid-upgrade-selection')
        anchors.add(min(indexes))
        claimed.update(indexes)
        consumed.update(index for index in indexes if index != min(indexes))
    if anchors != set(replacements):
        raise ValueError('background-proof-upgrade-selection-mismatch')
    output = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    return output, replacements, consumed, claimed


def _merge_metrics(entries, legacy, replacements, claimed, records):
    result = {key: legacy[key] for key in ('original_ubt_count', 'exact_count', 'shader_count', 'other_count')}
    result.update(batch_count=len(replacements), accepted_ubt_count=len(claimed),
        retained_ubt_count=legacy['original_ubt_count'] - len(claimed),
        output_entries=len(entries) - len(claimed) + len(replacements), groups=records,
        cache_hits=sum(bool(record.get('cached')) for record in records),
        deferred_group_count=sum(bool(record.get('deferred')) for record in records),
        new_proof_count=0, new_batch_count=0, proof_directory=None,
        baseline_cache_reused=bool(replacements))
    result.update(proof_accepted_count=sum(bool(record.get('accepted')) for record in records),
        proof_rejected_count=sum(not record.get('accepted') and not record.get('deferred') for record in records),
        proof_uncached_count=sum(record.get('reason') == 'verification-not-cached' for record in records),
        selector_reuse_status='accepted' if replacements else 'zero-hit')
    return result


def reuse_completed(entries, legacy_store, clangd, server_profile=None):
    """Read-only reuse for prepare; validate every catalog group through the gate."""
    if _mode() == 'strict':
        with verified.tier1_overlay_scope(False):
            return _reuse_completed(entries, legacy_store, clangd, server_profile)
    tier1, strict = {}, {}
    with verified.tier1_overlay_scope(True):
        _reuse_completed(entries, legacy_store, clangd, server_profile, mode='1', selection=tier1)
    with verified.tier1_overlay_scope(False):
        _reuse_completed(entries, legacy_store, clangd, server_profile, mode='strict',
            catalog_only=True, excluded=tier1['claimed'], selection=strict)
    return _compose_selection(entries, tier1, strict)


def _compose_selection(entries, tier1, strict):
    replacements = dict(tier1['replacements'])
    replacements.update(strict['replacements'])
    records = tier1['records'] + strict['records']
    output, replacements, _, claimed = _render_selection(entries, replacements, records)
    metrics = _merge_metrics(entries, tier1['metrics'], replacements, claimed, records)
    metrics['families'] = {mode: {key: value['metrics'].get(key, 0) for key in (
        'batch_count', 'accepted_ubt_count', 'retained_ubt_count', 'invalidated_group_count')}
        for mode, value in (('1', tier1), ('strict', strict))}
    metrics['proof_seconds'] = sum(value['metrics'].get('proof_seconds', 0) for value in (tier1, strict))
    if 'upgrade_observations' in tier1['metrics']:
        metrics['upgrade_observations'] = tier1['metrics']['upgrade_observations']
    return output, metrics


def _disjoint_owners(entries, indexes, replacements, records, blocked, strict_options=None):
    """Project actual admitted receipts, never treat their lookup parent as an owner."""
    selected, consumed, claimed, projected = {}, set(), set(), []
    for record in records:
        original_indexes = [indexes[index] for index in record['original_indexes']]
        if record.get('accepted'):
            if set(original_indexes).intersection(blocked) or claimed.intersection(original_indexes):
                continue
            if strict_options:
                if (record.get('strict_recipe') != strict_options['strict_recipe']
                        or record['original_indexes'] != list(range(len(indexes)))):
                    continue
            elif _chunks([entries[index] for index in original_indexes], 'strict') != [list(range(len(original_indexes)))]:
                continue
            anchor = min(original_indexes)
            selected[anchor] = replacements[min(record['original_indexes'])]
            consumed.update(index for index in original_indexes if index != anchor)
            claimed.update(original_indexes)
        projected.append(dict(record, original_indexes=original_indexes))
    return selected, consumed, claimed, projected


def _reuse_completed(entries, legacy_store, clangd, server_profile, include_upgrades=True, validated_groups=None,
        mode=None, catalog_only=False, excluded=(), selection=None):
    started = time.monotonic()
    mode = mode or _mode()
    excluded = set(excluded)
    output, legacy = ((list(entries), _empty_metrics(entries)) if catalog_only else
        _cache_only(entries, legacy_store, clangd, server_profile, mode))
    replacements, consumed, claimed = _replacements(entries, output, legacy, mode)
    records = list(legacy['groups'])
    if excluded:
        records = [record for record in records if not excluded.intersection(record['original_indexes'])]
        anchors = {min(record['original_indexes']) for record in records if record.get('accepted')}
        replacements = {index: value for index, value in replacements.items() if index in anchors}
        _, replacements, consumed, claimed = _render_selection(entries, replacements, records)
    # Retry children are receipt owners, not a second ordinary packing policy.
    ordinary_groups = [record['original_indexes'] for record in records if not record.get('fallback_of')]
    cross_class_members = {index for chunk in ordinary_groups
        if len({_tuple_key(entries[index])[2] for index in chunk}) > 1
        for index in chunk} if mode == '1' else set()
    catalog = _catalog(legacy_store, mode)
    positions = {}
    if catalog:
        for index, entry in enumerate(entries):
            positions.setdefault(_sha(_json(entry).encode('utf-8')), []).append(index)
    sequences = None

    def upgrade_sequences():
        nonlocal sequences
        if sequences is None:
            current = {}
            for index, entry in enumerate(entries):
                key = _tuple_key(entry)
                if key is not None:
                    current.setdefault(key, []).append(index)
            sequences = current
        return sequences

    upgrades, invalidated = [], 0
    for group in catalog:
        try:
            strict_options = _strict_recipe_options(group)
            if strict_options and mode != 'strict':
                continue
            if 'packing' in group or 'upgrade_of' in group:
                if include_upgrades:
                    upgrades.append(_catalog_group(entries, positions, group, legacy_store, mode, ordinary_groups,
                        sequence_provider=upgrade_sequences if mode == '1' else None))
                continue
            hashes = group['entry_hashes']
            if (not isinstance(hashes, list) or (mode == 'strict' and not 2 <= len(hashes) <= strict_options.get('max_group', 8))
                    or any(len(positions.get(value, [])) != 1 for value in hashes)):
                continue
            indexes = [positions[value][0] for value in hashes]
            # A historical class-split subset must not claim members of the
            # current full-input Tier 1 chunk and prevent its qualification.
            if (mode == '1' and indexes not in ordinary_groups
                    and cross_class_members.intersection(indexes)):
                continue
            blocked = excluded | claimed
            cross_module = (mode == '1' and verified.tier2_enabled()
                and len({entries[index]['nvim_ue_module_root'] for index in indexes}) > 1)
            if cross_module:
                modules = {entries[index]['nvim_ue_module_root'] for index in indexes}
                if any(verified._is_ubt(entry) and entry['nvim_ue_module_root'] in modules
                        and index not in indexes for index, entry in enumerate(entries)):
                    continue
            if (len(set(indexes)) != len(indexes) or (cross_module and excluded.intersection(indexes))
                    or (set(indexes) <= blocked and not cross_module)):
                continue
            selected = [entries[index] for index in indexes]
            if strict_options:
                import cdb_ordered_batch
                cdb_ordered_batch.validate_group(entries, indexes, strict_options['max_group'],
                    strict_options['max_sources'], verified)
                if blocked.intersection(indexes):
                    continue
            elif mode == 'strict':
                # Bound advisory lookup before reading caches, but check live
                # packing on each actual receipt owner after cache validation.
                if (not 2 <= len(selected) <= 8 or not all(verified._is_ubt(entry) for entry in selected)
                        or sum(len(entry['nvim_ue_members']) for entry in selected) > 80
                        or len({_tuple_key(entry)[:2] for entry in selected}) != 1):
                    continue
            identity = _identity(selected, mode, **strict_options)
            expected_store = _catalog_path(legacy_store, mode, strict_options.get('strict_recipe')).parent / identity
            if (identity != group['id'] or Path(group['store']).resolve() != expected_store
                    or (mode != 'strict' and _chunks(selected, mode) != [list(range(len(selected)))])):
                continue
            output, metrics = _cache_only(selected, expected_store, clangd, server_profile, mode, **strict_options)
            local_replacements, local_consumed, local_claimed = _replacements(selected, output, metrics, mode)
            if validated_groups is not None:
                validated_groups[identity] = (local_replacements, local_claimed, metrics['groups'])
            if cross_module:
                full = [record for record in metrics['groups'] if record.get('accepted')
                    and record.get('tier') == 2 and set(record['original_indexes']) == set(range(len(indexes)))]
                owners = [record for record in records if record.get('accepted')
                    and set(indexes).intersection(record['original_indexes'])]
                if full and all(set(owner['original_indexes']).issubset(indexes) for owner in owners):
                    for owner in owners:
                        replacements.pop(min(owner['original_indexes']), None)
                    records = [record for record in records if record not in owners]
                    records.append(dict(full[0], original_indexes=indexes))
                    replacements[min(indexes)] = local_replacements[0]
                    _, replacements, consumed, claimed = _render_selection(entries, replacements, records)
                    continue
            if mode == 'strict' and not local_claimed:
                # Old catalogs do not record historical child boundaries. Count
                # an unavailable lookup, not an unproven/never-admitted remainder.
                invalidated += 1
                continue
            if mode == 'strict':
                current, removed, owners, current_records = _disjoint_owners(entries, indexes,
                    local_replacements, metrics['groups'], blocked, strict_options)
                replacements.update(current)
                consumed.update(removed)
                claimed.update(owners)
                records.extend(current_records)
            else:
                for record in metrics['groups']:
                    projected = [indexes[index] for index in record['original_indexes']]
                    if record.get('accepted'):
                        if blocked.intersection(projected):
                            continue  # Never split or replace an already admitted owner.
                        anchor = min(projected)
                        replacements[anchor] = local_replacements[min(record['original_indexes'])]
                        consumed.update(index for index in projected if index != anchor)
                        claimed.update(projected)
                        blocked.update(projected)
                    records.append(dict(record, original_indexes=projected))
        except (OSError, ValueError, KeyError, TypeError):
            continue  # A corrupt or stale advisory catalog never grants admission.
    if mode == '1':
        # Prefer a revalidated catalog record over the root store's cache miss.
        records = list({tuple(record['original_indexes']): record for record in records}.values())
    observations = []
    for group in sorted(upgrades, key=lambda item: ('recipe' in item, -len(item['indexes']), tuple(item['indexes']), item['id'])):
        replacements, records, observation = _apply_upgrade(entries, group, clangd, server_profile,
            replacements, records, **({'persisted': True} if 'recipe' in group else {}))
        observations.append(observation)
    if upgrades:
        output, replacements, consumed, claimed = _render_selection(entries, replacements, records)
    else:
        output = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    metrics = _merge_metrics(entries, legacy, replacements, claimed, records)
    metrics['invalidated_group_count'] = invalidated
    if observations:
        metrics['upgrade_observations'] = observations
    metrics['proof_seconds'] = round(time.monotonic() - started, 6)
    if selection is not None:
        selection.update(replacements=replacements, claimed=claimed, records=records, metrics=metrics)
    return output, metrics


def _pending_result_hints(previous_path, plan, entries, ordinary_groups=None, preserve_large=False):
    """Old worker outputs are discovery hints only; collect revalidates receipts."""
    if previous_path is None:
        return []
    previous_path = Path(previous_path)
    try:
        previous = json.loads(previous_path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return []
    if (not isinstance(previous, dict) or not isinstance(previous.get('groups'), list)
            or previous.get('schema') != 1 or previous.get('input_sha256') != plan['input_sha256']
            or previous.get('mode', 'strict') != plan.get('mode', 'strict')
            or previous.get('tier2_enabled', False) != plan.get('tier2_enabled', False)
            or previous.get('server_profile') != plan['server_profile']
            or previous.get('residual_strict_policy') != plan.get('residual_strict_policy')
            or previous.get('residual_strict_limit') != plan.get('residual_strict_limit')):
        return []
    current_groups = {group['id']: group for group in plan['groups']}
    hints = []
    seen = set()
    for group in previous['groups']:
        if not isinstance(group, dict) or not isinstance(group.get('id'), str):
            continue
        identity = group['id']
        if 'residual_strict_limit' in plan and identity not in current_groups:
            continue  # Recovery cannot expand this invocation's residual allowance.
        # Queue relationships may change without changing any proof identity.
        core = {key: value for key, value in group.items() if key not in ('schedule_role', 'fallback_of')}
        current = {key: value for key, value in current_groups.get(identity, {}).items()
            if key not in ('schedule_role', 'fallback_of')}
        if identity in seen or (identity in current_groups and current != core):
            continue
        seen.add(identity)
        try:
            # Validate the old group's indexes/store against CURRENT source bytes.
            # A valid cached group may disappear from the new work plan after reuse.
            if 'residual_strict_limit' not in plan:
                _group(dict(plan, groups=[core]), entries, identity, ordinary_groups)
            if type(group.get('ubt_count')) is not int or group['ubt_count'] != len(group['indexes']):
                continue
        except (KeyError, TypeError, ValueError):
            continue
        path = previous_path.parent / ('result-' + identity + '.json')
        try:
            if path.stat().st_size > 4194304:
                continue
            result = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        if not isinstance(result, dict) or not isinstance(result.get('metrics'), dict):
            continue
        count = result['metrics'].get('new_batch_count', 0)
        if (result.get('ok') is True and result.get('group_id') == identity
                and result.get('input_sha256') == plan['input_sha256']
                and result.get('mode', 'strict') == plan.get('mode', 'strict')
                and type(count) is int and 0 < count <= group['ubt_count']):
            if identity not in current_groups:
                recovered = dict(core)
                if preserve_large and group.get('schedule_role') == 'large-first':
                    recovered['schedule_role'] = 'large-first'
                plan['groups'].append(recovered)
                current_groups[identity] = recovered
            hints.append({'id': identity, 'accepted_hint': count})
    return hints


def _residual_pairs(entries):
    contexts = {}
    for index, entry in enumerate(entries):
        key = _tuple_key(entry)
        if key is not None:
            contexts.setdefault(key[:2], []).append((index, key[2]))
    pairs = [[index for index, _ in rows] for rows in contexts.values()
        if len(rows) == 2 and {kind for _, kind in rows} == {'src', 'gen'}]
    # Exactly two differently-classed originals cannot belong to an ordinary
    # same-class Tier 1 chunk. Do not regroup a subset of a larger context.
    return sorted(pairs, key=lambda indexes: (
        -sum(len(entries[index]['nvim_ue_members']) for index in indexes), tuple(indexes)))


def _residual_members(selected):
    members = [member for entry in selected for member in verified._validate_ubt(entry)]
    portable = [verified.portable_member_path(member) for member in members]
    if len(portable) != len(set(portable)):
        raise ValueError('background-proof-residual-duplicate-members')


def _residual_schedule(previous_path, digest, profile, limit, pairs):
    """Resume a bounded scan; old success outputs only prioritize fresh checks."""
    if previous_path is None:
        return 0, []
    path = Path(previous_path)
    try:
        if path.stat().st_size > 4194304:
            return 0, []
        previous = json.loads(path.read_text(encoding='utf-8'))
        cursor = previous.get('residual_cursor')
        if (previous.get('schema') != 1 or previous.get('mode') != 'strict'
                or previous.get('input_sha256') != digest or previous.get('server_profile') != profile
                or previous.get('residual_strict_policy') != _RESIDUAL_POLICY
                or type(previous['residual_strict_policy'].get('version')) is not int
                or type(previous.get('residual_strict_limit')) is not int
                or previous['residual_strict_limit'] != limit or type(cursor) is not int
                or not 0 <= cursor < max(1, len(pairs))
                or not isinstance(previous.get('groups'), list) or len(previous['groups']) > limit):
            return 0, []
        pending = []
        for group in previous['groups']:
            if not isinstance(group, dict) or group.get('indexes') not in pairs:
                continue
            identity = group.get('id')
            if (not isinstance(identity, str) or len(identity) != 64
                    or any(char not in '0123456789abcdef' for char in identity)):
                continue
            result_path = path.parent / ('result-' + identity + '.json')
            try:
                if result_path.stat().st_size > 4194304:
                    continue
                result = json.loads(result_path.read_text(encoding='utf-8'))
                count = result.get('metrics', {}).get('new_batch_count')
                if (result.get('ok') is True and result.get('mode', 'strict') == 'strict'
                        and result.get('group_id') == identity and result.get('input_sha256') == digest
                        and type(count) is int and 0 < count <= 2):
                    rank = pairs.index(group['indexes'])
                    if rank not in pending:
                        pending.append(rank)
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                continue
        return cursor, pending
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return 0, []


def _validate_residual_plan(plan, entries):
    if not any(key in plan for key in ('residual_strict_limit', 'residual_strict_policy', 'residual_discovery', 'residual_cursor')):
        return
    limit, policy = plan.get('residual_strict_limit'), plan.get('residual_strict_policy')
    if (plan.get('mode') != 'strict' or type(limit) is not int or limit not in (1, 2)
            or not isinstance(policy, dict) or type(policy.get('version')) is not int
            or policy != _RESIDUAL_POLICY or len(plan['groups']) > limit):
        raise ValueError('background-proof-residual-policy-mismatch')
    pairs = _residual_pairs(entries)
    rank = {tuple(indexes): index for index, indexes in enumerate(pairs)}
    discovery, cursor = plan.get('residual_discovery'), plan.get('residual_cursor')
    if not isinstance(discovery, dict):
        raise ValueError('background-proof-residual-cursor-mismatch')
    start, checked, pending = (discovery.get('start_cursor'), discovery.get('checked_positions'),
        discovery.get('pending_checked_count'))
    if (type(cursor) is not int or not 0 <= cursor < max(1, len(pairs))
            or type(start) is not int or not 0 <= start < max(1, len(pairs))
            or not isinstance(checked, list) or len(checked) > limit
            or any(type(index) is not int or not 0 <= index < len(pairs) for index in checked)
            or len(set(checked)) != len(checked) or type(pending) is not int or not 0 <= pending <= len(checked)
            or type(discovery.get('pair_count')) is not int or discovery['pair_count'] != len(pairs)
            or type(discovery.get('checked_scope_count')) is not int or discovery['checked_scope_count'] != len(checked)
            or type(discovery.get('cache_probe_count')) is not int
            or not 0 <= discovery['cache_probe_count'] <= len(checked)
            or cursor != ((checked[-1] + 1) % len(pairs) if checked else start)):
        raise ValueError('background-proof-residual-cursor-mismatch')
    distances = [(index - start) % len(pairs) for index in checked[pending:]]
    if distances != sorted(distances):
        raise ValueError('background-proof-residual-order-mismatch')
    seen, ordering = set(), []
    for group in plan['groups']:
        indexes = group.get('indexes')
        if (not isinstance(indexes, list) or any(type(index) is not int for index in indexes)
                or tuple(indexes) not in rank or tuple(indexes) in seen
                or 'packing' in group or 'upgrade_of' in group
                or type(group.get('ubt_count')) is not int or group['ubt_count'] != 2
                or type(group.get('member_count')) is not int
                or group['member_count'] != sum(len(entries[index]['nvim_ue_members']) for index in indexes)):
            raise ValueError('background-proof-residual-scope-mismatch')
        identity = _identity([entries[index] for index in indexes], 'strict')
        if (group.get('id') != identity or Path(group['store']).resolve()
                != _catalog_path(plan['legacy_store'], 'strict').parent / identity):
            raise ValueError('background-proof-group-identity-mismatch')
        seen.add(tuple(indexes))
        ordering.append(rank[tuple(indexes)])
    if ordering != [position for position in checked if position in ordering]:
        raise ValueError('background-proof-residual-order-mismatch')


def _residual_owner_overlap(group, tier1, strict):
    indexes = set(group['indexes'])
    if indexes.intersection(tier1['claimed']):
        return True
    # An exact self owner is expected on repeated work/collect. A different
    # currently accepted owner must never be split, even if its hint is old.
    return any(record.get('accepted') and indexes.intersection(record['original_indexes'])
        and record['original_indexes'] != group['indexes'] for record in strict['records'])


def _ordered_plan(source, store, clangd, profile, strict_recipe, group_indexes, max_group, max_sources):
    """One requested whole-owner group; no automatic cross-module discovery."""
    if _mode() != 'strict':
        raise ValueError('background-proof-ordered-requires-strict')
    options = _strict_recipe_options({'strict_recipe': strict_recipe,
        'strict_limits': {'max_group': max_group, 'max_sources': max_sources}})
    source, store = Path(source).resolve(), Path(store).resolve()
    entries, digest = _read_source(source)
    import cdb_ordered_batch
    indexes, _ = cdb_ordered_batch.validate_group(entries, group_indexes, max_group, max_sources, verified)
    tier1, strict = {}, {}
    with verified.tier1_overlay_scope(True):
        _reuse_completed(entries, store, clangd, profile, mode='1', selection=tier1)
    _reuse_completed(entries, store, clangd, profile, mode='strict', catalog_only=True,
        excluded=tier1['claimed'], selection=strict)
    group = {'indexes': indexes, 'strict_recipe': strict_recipe,
             'strict_limits': {'max_group': max_group, 'max_sources': max_sources}}
    if _ordered_owner_overlap(group, tier1, strict):
        raise ValueError('background-proof-ordered-owner-overlap')
    selected = [entries[index] for index in indexes]
    identity = _identity(selected, 'strict', **options)
    group.update(id=identity, store=str(_catalog_path(store, 'strict', strict_recipe).parent / identity),
        ubt_count=len(indexes), member_count=sum(len(entry['nvim_ue_members']) for entry in selected))
    _, metrics = _compose_selection(entries, tier1, strict)
    _read_source(source, digest)
    return {'schema': 1, 'mode': 'strict', 'strict_recipe': strict_recipe,
        'input_path': str(source), 'input_sha256': digest, 'legacy_store': str(store),
        'server_profile': profile, 'entry_count': len(entries), 'groups': [group],
        'counts': {key: metrics[key] for key in ('original_ubt_count', 'exact_count', 'shader_count', 'other_count')},
        'legacy_batch_count': metrics['batch_count'], 'plan_candidate_count': 1, 'recovered_completed': [],
        'proof_accepted_count': metrics['proof_accepted_count'],
        'proof_rejected_count': metrics['proof_rejected_count'],
        'proof_uncached_count': metrics['proof_uncached_count'], 'selector_reuse_status': metrics['selector_reuse_status']}


def _ordered_owner_overlap(group, tier1, strict):
    wanted = set(group['indexes'])
    return (bool(wanted.intersection(tier1['claimed'])) or any(record.get('accepted')
        and wanted.intersection(record['original_indexes'])
        and (record['original_indexes'] != group['indexes']
             or record.get('strict_recipe') != group['strict_recipe']) for record in strict['records']))


def make_plan(source, store, clangd, profile=None, previous_path=None, tier1_upgrades=None,
              auto_tier1_large=False, residual_strict_limit=None, *, strict_recipe=None,
              group_indexes=None, max_group=8, max_sources=80):
    if strict_recipe is not None:
        if tier1_upgrades is not None or auto_tier1_large or residual_strict_limit is not None:
            raise ValueError('background-proof-ordered-exclusive-request')
        return _ordered_plan(source, store, clangd, profile, strict_recipe, group_indexes, max_group, max_sources)
    if group_indexes is not None or max_group != 8 or max_sources != 80:
        raise ValueError('background-proof-ordered-request-required')
    if type(auto_tier1_large) is not bool:
        raise ValueError('background-proof-invalid-auto-tier1-large')
    if residual_strict_limit is not None and (type(residual_strict_limit) is not int
            or residual_strict_limit not in (1, 2)):
        raise ValueError('background-proof-invalid-residual-strict-limit')
    if residual_strict_limit is not None and _mode() != 'strict':
        raise ValueError('background-proof-residual-strict-requires-strict')
    source, store = Path(source).resolve(), Path(store).resolve()
    entries, digest = _read_source(source)
    mode = _mode()
    if tier1_upgrades is not None and (mode != '1'
            or not isinstance(tier1_upgrades, list) or len(tier1_upgrades) > 32):
        raise ValueError('background-proof-invalid-tier1-upgrades')
    residual = residual_strict_limit is not None
    if residual:
        tier1, strict = {}, {}
        with verified.tier1_overlay_scope(True):
            _reuse_completed(entries, store, clangd, profile, mode='1', selection=tier1)
        with verified.tier1_overlay_scope(False):
            _reuse_completed(entries, store, clangd, profile, mode='strict', catalog_only=True,
                excluded=tier1['claimed'], selection=strict)
        output, metrics = _compose_selection(entries, tier1, strict)
        claimed = tier1['claimed'] | strict['claimed']
        ordinary_groups = []
    else:
        with verified.tier1_overlay_scope(mode == '1'):
            output, metrics = _reuse_completed(entries, store, clangd, profile)
            ordinary_groups = [record['original_indexes'] for record in metrics['groups']
                if not record.get('fallback_of')]
            _, _, claimed = _replacements(entries, output, metrics, mode)
    # Tier 1 chunks must stay identical to prepare's full-input cache lookup;
    # removing admitted groups first could regroup the remaining originals.
    available = [(index, entry) for index, entry in enumerate(entries)
        if residual or mode == '1' or index not in claimed]
    pairs = _residual_pairs(entries) if residual else []
    start_cursor, pending = _residual_schedule(previous_path, digest, profile,
        residual_strict_limit, pairs) if residual else (0, [])
    positions = pending + [position for position in (
        list(range(start_cursor, len(pairs))) + list(range(start_cursor))) if position not in pending]
    candidates = [pairs[position] for position in positions] if residual else _chunks([entry for _, entry in available], mode)
    rejected = {tuple(record['original_indexes']) for record in metrics['groups']
        if record.get('cached') and not record.get('accepted') and not record.get('deferred')}
    # The parent's negative receipt remains reusable while a missing child still
    # needs work. Schedule the same parent, letting the verifier own retry packing.
    retry_pending = set()
    if mode == '1' and not residual:
        for record in metrics['groups']:
            key = record.get('cache_key')
            indexes = set(record['original_indexes'])
            if (record.get('fallback_of') or not key or record.get('accepted')
                    or not any(child.get('fallback_of') == key and child.get('deferred')
                        for child in metrics['groups'])):
                continue
            owners = [owner for owner in metrics['groups'] if owner.get('accepted')
                and indexes.intersection(owner['original_indexes'])]
            if all(owner.get('fallback_of') == key
                    and set(owner['original_indexes']).issubset(indexes) for owner in owners):
                retry_pending.add(tuple(record['original_indexes']))
        if verified.tier2_enabled():
            for chunk in candidates:
                indexes = {available[index][0] for index in chunk}
                if (len({entries[index]['nvim_ue_module_root'] for index in indexes}) > 1
                        and (tuple(available[index][0] for index in chunk) not in rejected
                            or any(owner.get('deferred') and indexes.intersection(owner['original_indexes'])
                                and owner.get('tier') != 2 for owner in metrics['groups']))
                        and not any(owner.get('accepted') and owner.get('tier') == 2
                            and set(owner['original_indexes']) == indexes for owner in metrics['groups'])
                        and all(set(owner['original_indexes']).issubset(indexes)
                            for owner in metrics['groups'] if owner.get('accepted')
                            and indexes.intersection(owner['original_indexes']))):
                    retry_pending.add(tuple(available[index][0] for index in chunk))
    groups, cache_probes, checked_positions, pending_checked = [], 0, [], 0
    for chunk in candidates:
        indexes = [available[index][0] for index in chunk]
        if ((mode == '1' or residual) and tuple(indexes) not in retry_pending
                and (claimed.intersection(indexes) or tuple(indexes) in rejected)):
            continue
        selected = [entries[index] for index in indexes]
        if residual:
            if len(checked_positions) >= residual_strict_limit:
                break
            position = pairs.index(indexes)
            checked_positions.append(position)
            pending_checked += int(position in pending)
            if _chunks(selected, 'strict') != [[0, 1]]:
                continue
            try:
                _residual_members(selected)
            except (OSError, ValueError, KeyError, TypeError):
                continue
        identity = _identity(selected, mode)
        if residual:
            cache_probes += 1
            cached_output, cached = _cache_only(selected, _catalog_path(store, mode).parent / identity, clangd, profile, mode)
            if position in pending and _replacements(selected, cached_output, cached, mode)[2] != {0, 1}:
                continue  # An obsolete success hint is consumed, never made sticky.
            if any(record.get('cached') and not record.get('accepted') and not record.get('deferred')
                    for record in cached['groups']):
                continue
        groups.append({'id': identity, 'indexes': indexes,
            'store': str(_catalog_path(store, mode).parent / identity),
            'ubt_count': len(indexes),
            'member_count': sum(len(entry['nvim_ue_members']) for entry in selected)})
    if not residual:
        groups.sort(key=lambda group: (group['member_count'], group['ubt_count'], group['indexes'][0]))
    if tier1_upgrades is not None:
        positions = {}
        for index, entry in enumerate(entries):
            positions.setdefault(_sha(_json(entry).encode('utf-8')), []).append(index)
        proposals = []
        for request in tier1_upgrades:
            if not isinstance(request, dict) or set(request) not in (
                    {'entry_hashes', 'packing'}, {'entry_hashes', 'packing', 'recipe'}):
                raise ValueError('background-proof-invalid-upgrade-proposal')
            recipe_options = _recipe_options(request)
            hashes = request['entry_hashes']
            if (not isinstance(hashes, list) or not 2 <= len(hashes) <= 32
                    or any(not isinstance(value, str) or len(value) != 64
                        or any(char not in '0123456789abcdef' for char in value) for value in hashes)
                    or len(set(hashes)) != len(hashes) or any(len(positions.get(value, [])) != 1 for value in hashes)):
                raise ValueError('background-proof-upgrade-originals-ambiguous')
            indexes = [positions[value][0] for value in hashes]
            selected = [entries[index] for index in indexes]
            identity = _identity(selected, mode, **recipe_options)
            owners, count = _upgrade_owners(entries, indexes, metrics['groups'])
            if recipe_options:
                if owners == [identity]:
                    continue
                if not _whole_flat_owner(indexes, metrics['groups']):
                    raise ValueError('background-proof-recipe-current-flat-owner-required')
            group = {'id': identity, 'indexes': indexes,
                'store': str(_catalog_path(store, mode).parent / identity),
                'ubt_count': len(indexes), 'member_count': sum(len(entry.get('nvim_ue_members', [])) for entry in selected),
                'packing': request['packing'], 'upgrade_of': owners, **recipe_options}
            _group({'mode': mode, 'legacy_store': str(store), 'groups': [group]}, entries, identity, ordinary_groups)
            if (count <= 1 and not recipe_options) or any(item['id'] == identity for item in groups + proposals):
                continue
            _, cached = _cache_only(selected, group['store'], clangd, profile, mode, group['packing'], **recipe_options)
            if any(record.get('cached') and not record.get('accepted') and not record.get('deferred')
                    for record in cached['groups']):
                continue
            proposals.append(group)
        groups.extend(sorted(proposals, key=lambda item: (-len(item['indexes']), tuple(item['indexes']), item['id'])))
    _read_source(source, digest)
    plan = {'schema': 1, 'mode': mode, 'input_path': str(source), 'input_sha256': digest,
        'legacy_store': str(store), 'server_profile': profile,
        'entry_count': len(entries), 'counts': {key: metrics[key] for key in (
            'original_ubt_count', 'exact_count', 'shader_count', 'other_count')},
        'legacy_batch_count': metrics['batch_count'], 'groups': groups,
        'plan_candidate_count': len(groups),
        'proof_accepted_count': metrics['proof_accepted_count'],
        'proof_rejected_count': metrics['proof_rejected_count'],
        'proof_uncached_count': metrics['proof_uncached_count'],
        'selector_reuse_status': metrics['selector_reuse_status']}
    if mode == '1' and verified.tier2_enabled():
        plan['tier2_enabled'] = True
    if residual:
        plan.update(residual_strict_limit=residual_strict_limit, residual_strict_policy=dict(_RESIDUAL_POLICY),
            residual_cursor=(checked_positions[-1] + 1) % len(pairs) if checked_positions else start_cursor,
            residual_discovery={'pair_count': len(pairs), 'checked_scope_count': len(checked_positions),
                'cache_probe_count': cache_probes, 'start_cursor': start_cursor,
                'checked_positions': checked_positions, 'pending_checked_count': pending_checked})
    plan['recovered_completed'] = _pending_result_hints(previous_path, plan, entries, ordinary_groups,
        preserve_large=auto_tier1_large and mode == '1')
    _validate_residual_plan(plan, entries)
    if auto_tier1_large and mode == '1':
        active = {_identity([entries[index] for index in record['original_indexes']], mode, **_recipe_options(record))
            for record in metrics['groups'] if record.get('accepted')}
        selected_parents = {group['id'] for group in plan['groups']
            if group.get('schedule_role') == 'large-first' and group['id'] in active}
        plan['groups'] = [group for group in plan['groups'] if group['id'] not in selected_parents]
        plan['recovered_completed'] = [hint for hint in plan['recovered_completed'] if hint['id'] not in selected_parents]
        ordinary = [[available[index][0] for index in chunk] for chunk in candidates]
        parents = [group for group in plan['groups'] if group.get('schedule_role') == 'large-first']
        parents += _automatic_large_groups(entries, ordinary, plan['groups'], metrics['groups'], store,
            clangd, profile, {hint['id'] for hint in plan['recovered_completed']})
        for group in plan['groups']:
            if 'packing' in group:
                continue
            for parent in parents:
                if set(group['indexes']) < set(parent['indexes']):
                    group['fallback_of'] = parent['id']
        plan['groups'] = parents + [group for group in plan['groups']
            if 'fallback_of' not in group and group.get('schedule_role') != 'large-first'] + [
            group for group in plan['groups'] if 'fallback_of' in group]
        plan['tier1_large_policy'] = dict(_LARGE_POLICY, packing=dict(_LARGE_PACKING))
        plan['tier1_ordinary_atoms'] = ordinary
        plan['deferred_fallback_count'] = sum('fallback_of' in group for group in plan['groups'])
        plan['initially_ready_count'] = len(plan['groups']) - plan['deferred_fallback_count']
        plan['plan_candidate_count'] = len(plan['groups'])
        _validate_schedule(plan, entries)
        _read_source(source, digest)
    return plan


def _load_plan(path, profile):
    plan = json.loads(Path(path).read_text(encoding='utf-8'))
    if plan.get('schema') != 1 or plan.get('server_profile') != profile:
        raise ValueError('background-proof-plan-profile-mismatch')
    if plan.get('mode', 'strict') != _mode():
        raise ValueError('background-proof-plan-tier-mismatch')
    if plan.get('mode') == '1' and plan.get('tier2_enabled', False) != verified.tier2_enabled():
        raise ValueError('background-proof-plan-tier2-mismatch')
    entries, _ = _read_source(plan['input_path'], plan['input_sha256'])
    _validate_schedule(plan, entries)
    _validate_residual_plan(plan, entries)
    return plan, entries


def _group(plan, entries, identity, ordinary_groups=None, *, sequence_provider=None):
    matches = [group for group in plan['groups'] if group['id'] == identity]
    if len(matches) != 1:
        raise ValueError('background-proof-group-not-found')
    group = matches[0]
    indexes = group['indexes']
    if (not isinstance(indexes, list)
            or any(type(index) is not int or index < 0 or index >= len(entries) for index in indexes)
            or len(set(indexes)) != len(indexes)):
        raise ValueError('background-proof-invalid-indexes')
    selected = [entries[index] for index in indexes]
    strict_options = _strict_recipe_options(group)
    if strict_options:
        if plan.get('mode') != 'strict' or plan.get('strict_recipe') != strict_options['strict_recipe']:
            raise ValueError('background-proof-ordered-plan-mismatch')
        import cdb_ordered_batch
        cdb_ordered_batch.validate_group(entries, indexes, strict_options['max_group'],
            strict_options['max_sources'], verified)
        expected_store = _catalog_path(plan['legacy_store'], 'strict', strict_options['strict_recipe']).parent / identity
        if (_identity(selected, 'strict', **strict_options) != identity
                or Path(group['store']).resolve() != expected_store
                or group.get('ubt_count') != len(selected)
                or group.get('member_count') != sum(len(entry['nvim_ue_members']) for entry in selected)):
            raise ValueError('background-proof-ordered-group-identity-mismatch')
        return group, selected
    if 'strict_recipe' in plan:
        raise ValueError('background-proof-ordered-group-required')
    if 'residual_strict_limit' in plan:
        _residual_members(selected)
    mode = plan.get('mode', 'strict')
    recipe_options = _recipe_options(group)
    modules = {entry.get('nvim_ue_module_root') for entry in selected}
    if mode == '1' and verified.tier2_enabled() and len(modules) > 1:
        if any(verified._is_ubt(entry) and entry['nvim_ue_module_root'] in modules
                and index not in indexes for index, entry in enumerate(entries)):
            raise ValueError('background-proof-tier2-partial-module')
    if recipe_options and (mode != '1' or 'packing' not in group or 'upgrade_of' not in group
            or len(group['upgrade_of']) != 1 or 'schedule_role' in group or 'fallback_of' in group):
        raise ValueError('background-proof-invalid-recipe-migration')
    packing = group.get('packing')
    if 'packing' in group or 'upgrade_of' in group:
        if packing is None or 'upgrade_of' not in group:
            raise ValueError('background-proof-incomplete-upgrade')
        _group_packing(mode, packing)
        if (type(group.get('ubt_count')) is not int or group['ubt_count'] != len(indexes)
                or type(group.get('member_count')) is not int
                or group['member_count'] != sum(len(entry.get('nvim_ue_members', [])) for entry in selected)):
            raise ValueError('background-proof-upgrade-count-mismatch')
        _upgrade_sequence(entries, indexes, sequence_provider=sequence_provider)
        _upgrade_relationships(entries, indexes, group['upgrade_of'], plan['legacy_store'], ordinary_groups)
    if recipe_options:
        # A recipe migrates this exact whole flat identity, never a child-owner
        # hint. Its own receipt remains authoritative when the old receipt is gone.
        flat_id = _identity(selected, '1')
        parents = [owner for owner in _catalog(plan['legacy_store'], '1')
            if isinstance(owner, dict) and owner.get('id') == flat_id]
        hashes = [_sha(_json(entry).encode('utf-8')) for entry in selected]
        if (group['upgrade_of'] != [flat_id] or len(parents) != 1 or 'recipe' in parents[0]
                or parents[0].get('entry_hashes') != hashes):
            raise ValueError('background-proof-recipe-whole-flat-parent-required')
        positions = {}
        for index, digest in zip(indexes, hashes):
            positions.setdefault(digest, []).append(index)
        _catalog_group(entries, positions, parents[0], plan['legacy_store'], '1', ordinary_groups,
            sequence_provider=sequence_provider)
    expected_store = _catalog_path(plan['legacy_store'], mode).parent / identity
    if (_identity(selected, mode, **recipe_options) != identity
            or Path(group['store']).resolve() != expected_store
            or _chunks(selected, mode, packing) != [list(range(len(selected))) ]):
        raise ValueError('background-proof-group-identity-mismatch')
    return group, selected


def _owned_job():
    """Keep this Windows job handle alive until worker exit, including descendants."""
    if os.name != 'nt':
        return None
    import ctypes
    from ctypes import wintypes

    class Basic(ctypes.Structure):
        _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
            ('flags', wintypes.DWORD), ('min_working_set', ctypes.c_size_t),
            ('max_working_set', ctypes.c_size_t), ('active_process_limit', wintypes.DWORD),
            ('affinity', ctypes.c_size_t), ('priority', wintypes.DWORD), ('scheduling', wintypes.DWORD)]

    class IO(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in (
            'read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]

    class Extended(ctypes.Structure):
        _fields_ = [('basic', Basic), ('io', IO), ('process_memory', ctypes.c_size_t),
            ('job_memory', ctypes.c_size_t), ('peak_process_memory', ctypes.c_size_t),
            ('peak_job_memory', ctypes.c_size_t)]

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateJobObjectW(None, None)
    if not handle:
        raise OSError(ctypes.get_last_error(), 'background-proof-job-create-failed')
    limit = Extended()
    limit.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if (not kernel.SetInformationJobObject(handle, 9, ctypes.byref(limit), ctypes.sizeof(limit))
            or not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess())):
        error = ctypes.get_last_error()
        kernel.CloseHandle(handle)
        raise OSError(error, 'background-proof-job-assignment-failed')
    # Deliberately do not close: closing while this process is in the job kills
    # it before its result is delivered. The OS closes it when this worker exits.
    return handle


def work(plan_path, identity, clangd, profile=None):
    plan, entries = _load_plan(plan_path, profile)
    group, selected = _group(plan, entries, identity)
    recipe_options = _recipe_options(group)
    strict_options = _strict_recipe_options(group)
    if recipe_options:
        with verified.tier1_overlay_scope(True):
            _, current = _reuse_completed(entries, plan['legacy_store'], clangd, profile, mode='1')
        owners, _ = _upgrade_owners(entries, group['indexes'], current['groups'])
        if owners != [identity] and not _whole_flat_owner(group['indexes'], current['groups']):
            raise ValueError('background-proof-recipe-current-flat-owner-required')
    job_handle = _owned_job()
    if 'residual_strict_limit' in plan or strict_options:
        tier1, strict = {}, {}
        with verified.tier1_overlay_scope(True):
            _reuse_completed(entries, plan['legacy_store'], clangd, profile, mode='1', selection=tier1)
        _reuse_completed(entries, plan['legacy_store'], clangd, profile, mode='strict', catalog_only=True,
            excluded=tier1['claimed'], selection=strict)
        if (_ordered_owner_overlap(group, tier1, strict) if strict_options else
                _residual_owner_overlap(group, tier1, strict)):
            raise ValueError('background-proof-residual-owner-overlap')
    if plan.get('mode', 'strict') == '1':
        limits = _group_packing('1', group.get('packing'))
        output, metrics = verified.accelerate_tier1(selected, group['store'], clangd,
            max_group=limits.get('max_unities', 8), timeout=90, server_profile=profile,
            **({'budget_factor': limits['budget_factor']} if limits else {}), **recipe_options)
    else:
        output, metrics = verified.accelerate(selected, group['store'], clangd,
            timeout=90, verify_missing=True, max_new_groups=None, server_profile=profile,
            **(dict(strict_options, group_indexes=list(range(len(selected)))) if strict_options
               else dict(max_group=8, max_sources=80)))
    _replacements(selected, output, metrics, plan.get('mode', 'strict'))
    _read_source(plan['input_path'], plan['input_sha256'])
    return {'ok': True, 'mode': plan.get('mode', 'strict'),
        'group_id': identity, 'input_sha256': plan['input_sha256'],
        'completed_at': time.time(), 'metrics': metrics, 'owned_job': job_handle is not None}


def collect(plan_path, completed, background, marker_path, clangd, profile=None,
        publish_request=None, nvim=None, publish_worker=None):
    return _collect(plan_path, completed, background, marker_path, clangd, profile,
        publish_request, nvim, publish_worker)


def _collect(plan_path, completed, background, marker_path, clangd, profile,
        publish_request, nvim, publish_worker):
    publication_args = (publish_request, nvim, publish_worker)
    if any(publication_args) and not all(publication_args):
        raise ValueError('background-proof-publication-worker-options-required-together')
    plan, entries = _load_plan(plan_path, profile)
    mode = plan.get('mode', 'strict')
    job_handle = _owned_job() if publish_request else None
    if not isinstance(completed, list) or not all(isinstance(identity, str) for identity in completed):
        raise ValueError('background-proof-completed-list-required')
    # Preserve all currently revalidated owners, including catalog upgrades,
    # before testing whether newly completed proposals replace whole owners.
    validated_groups = {}
    tier1, strict = {}, {}
    if mode == 'strict':
        with verified.tier1_overlay_scope(True):
            _reuse_completed(entries, plan['legacy_store'], clangd, profile, mode='1', selection=tier1)
    with verified.tier1_overlay_scope(mode == '1'):
        output, legacy = _reuse_completed(entries, plan['legacy_store'], clangd, profile,
            validated_groups=validated_groups, mode=mode,
            catalog_only='residual_strict_limit' in plan or 'strict_recipe' in plan,
            excluded=tier1.get('claimed', ()), selection=strict if mode == 'strict' else tier1)
        replacements, consumed, claimed = _replacements(entries, output, legacy, mode)
        records = list(legacy['groups'])
        ordinary_groups = _chunks(entries, mode) if mode == '1' else [record['original_indexes'] for record in records]
        catalog = {group['id']: group for group in _catalog(plan['legacy_store'], mode)
            if isinstance(group, dict) and 'id' in group}
        revalidated = []
        completed_upgrades = {}
        stale_parents = []
        for identity in (sorted(set(completed)) if mode == 'strict' else dict.fromkeys(completed)):
            try:
                group, selected = _group(plan, entries, identity, ordinary_groups)
            except ValueError as error:
                parent = next((group for group in plan['groups'] if group['id'] == identity), None)
                # The loader already checked static identity and all scheduling
                # edges. Current source sizes/owner packing may invalidate only
                # this parent while its ordinary fallbacks remain valid jobs.
                if (parent is None or parent.get('schedule_role') != 'large-first' or str(error) not in (
                        'background-proof-group-identity-mismatch',
                        'background-proof-upgrade-owner-identity-mismatch')):
                    raise
                stale_parents.append({'id': identity, 'original_indexes': parent['indexes'],
                    'accepted': False, 'reason': str(error)})
                continue
            if mode == 'strict':
                strict_options = _strict_recipe_options(group)
                if (set(group['indexes']) <= tier1['claimed'] or (strict_options
                        and _ordered_owner_overlap(group, tier1, strict)) or ('residual_strict_limit' in plan
                        and _residual_owner_overlap(group, tier1, strict))):
                    stale_parents.append({'id': identity, 'original_indexes': group['indexes'],
                        'accepted': False, 'reason': 'background-proof-residual-owner-overlap'
                            if 'residual_strict_limit' in plan else 'tier1-original-overlap'})
                    continue
                validated = validated_groups.get(identity)
                if validated is None:
                    checked, checked_metrics = _cache_only(selected, group['store'], clangd, profile, mode, **strict_options)
                    local, _, local_claimed = _replacements(selected, checked, checked_metrics, mode)
                    checked_groups = checked_metrics['groups']
                else:
                    local, local_claimed, checked_groups = validated
                blocked = tier1['claimed'] | claimed
                current, removed, owners, current_records = _disjoint_owners(entries, group['indexes'],
                    local, checked_groups, blocked, strict_options)
                replacements.update(current)
                consumed.update(removed)
                claimed.update(owners)
                if current or not local_claimed:
                    records.extend(current_records)
                actual = {tuple(record['original_indexes']) for record in records if record.get('accepted')}
                matches = [tuple(group['indexes'][index] for index in record['original_indexes']) in actual
                    and replacements.get(min(group['indexes'][index] for index in record['original_indexes']))
                    == local[min(record['original_indexes'])] for record in checked_groups if record.get('accepted')]
                if ((local_claimed == set(range(len(selected))) and matches and all(matches))
                        or (current and not blocked.intersection(group['indexes']))):
                    revalidated.append(identity)
                if current:
                    # Preserve existing lookup priority. A newly registered
                    # parent's overlapping children cannot replace older owners
                    # on the next prepare simply because its ID sorts earlier.
                    catalog[identity] = {'id': identity, 'store': group['store'],
                        'entry_hashes': [_sha(_json(entry).encode('utf-8')) for entry in selected],
                        **({key: group[key] for key in ('strict_recipe', 'strict_limits')} if strict_options else {})}
                continue
            if 'packing' in group:
                completed_upgrades[identity] = group
                continue
            if claimed.intersection(group['indexes']):
                # The same original coverage does not identify the requested
                # candidates. Strict proof may have admitted several subgroups.
                validated = validated_groups.get(identity)
                if validated is None:
                    checked, checked_metrics = _cache_only(selected, group['store'], clangd, profile, mode)
                    local, _, local_claimed = _replacements(selected, checked, checked_metrics, mode)
                    checked_groups = checked_metrics['groups']
                else:
                    # This collect's baseline already passed the same canonical
                    # store through both cache and receipt gates. No cross-call cache.
                    local, local_claimed, checked_groups = validated
                # A newly qualified whole cross-module owner may replace whole
                # live Tier 1 owners. Never split an existing receipt owner.
                selected_indexes = set(group['indexes'])
                full_tier2 = [record for record in checked_groups if record.get('accepted')
                    and record.get('tier') == 2
                    and set(record['original_indexes']) == set(range(len(selected)))]
                owners = [record for record in records if record.get('accepted')
                    and selected_indexes.intersection(record['original_indexes'])]
                if full_tier2 and all(set(owner['original_indexes']).issubset(selected_indexes)
                        for owner in owners):
                    for owner in owners:
                        replacements.pop(min(owner['original_indexes']), None)
                    records = [record for record in records if record not in owners]
                    replacements[min(group['indexes'])] = local[0]
                    records.append(dict(full_tier2[0], original_indexes=group['indexes']))
                    _, replacements, consumed, claimed = _render_selection(entries, replacements, records)
                    revalidated.append(identity)
                    catalog[identity] = {'id': identity, 'store': group['store'],
                        'entry_hashes': [_sha(_json(entry).encode('utf-8')) for entry in selected]}
                    continue
                actual = {tuple(record['original_indexes']) for record in records if record.get('accepted')}
                matches = []
                cross_module = verified.tier2_enabled() and len({
                    entry['nvim_ue_module_root'] for entry in selected}) > 1
                for record in checked_groups:
                    indexes = [group['indexes'][index] for index in record['original_indexes']]
                    if record.get('accepted'):
                        candidate = local[min(record['original_indexes'])]
                        same_owner = (tuple(indexes) in actual
                            and replacements.get(min(indexes)) == candidate)
                        if (record.get('fallback_of') or cross_module) and not claimed.intersection(indexes):
                            # A retry parent can retain one admitted child while
                            # its worker proves the other. Add only whole disjoint
                            # receipt owners; the verifier remains the sole grouper.
                            replacements[min(indexes)] = candidate
                            consumed.update(index for index in indexes if index != min(indexes))
                            claimed.update(indexes)
                            records.append(dict(record, original_indexes=indexes))
                            same_owner = True
                        matches.append(same_owner)
                    elif record.get('fallback_of') or record.get('fallback_chunks'):
                        records.append(dict(record, original_indexes=indexes))
                if local_claimed == set(range(len(selected))) and matches and all(matches):
                    revalidated.append(identity)
                if (cross_module or any(record.get('fallback_of') and record.get('accepted')
                        for record in checked_groups)) and any(matches):
                    catalog[identity] = {'id': identity, 'store': group['store'],
                        'entry_hashes': [_sha(_json(entry).encode('utf-8')) for entry in selected]}
                continue  # Never overlay a legacy proof or split an admitted group.
            output, metrics = _cache_only(selected, group['store'], clangd, profile, mode)
            local_replacements, local_consumed, local_claimed = _replacements(selected, output, metrics, mode)
            replacements.update({group['indexes'][index]: value for index, value in local_replacements.items()})
            consumed.update(group['indexes'][index] for index in local_consumed)
            claimed.update(group['indexes'][index] for index in local_claimed)
            if local_replacements:
                revalidated.append(identity)
            if local_replacements or (mode == '1' and any(record.get('cached') for record in metrics['groups'])):
                catalog[identity] = {'id': identity, 'store': group['store'],
                    'entry_hashes': [_sha(_json(entry).encode('utf-8')) for entry in selected]}
            records.extend(dict(record, original_indexes=[group['indexes'][index]
                for index in record['original_indexes']]) for record in metrics['groups'])
        if mode == '1':
            records = list({tuple(record['original_indexes']): record for record in records}.values())
        upgrades = dict(completed_upgrades)
        upgrade_observations = [observation for observation in legacy.get('upgrade_observations', [])
            if observation['id'] not in completed] + stale_parents
        for group in sorted(upgrades.values(), key=lambda item: ('recipe' in item, -len(item['indexes']), tuple(item['indexes']), item['id'])):
            replacements, records, observation = _apply_upgrade(entries, group, clangd, profile, replacements, records)
            upgrade_observations.append(observation)
            if observation['accepted'] or (observation.get('cached_rejection') and 'recipe' not in group):
                catalog[group['id']] = {'id': group['id'], 'store': group['store'],
                    'entry_hashes': [_sha(_json(entries[index]).encode('utf-8')) for index in group['indexes']],
                    'packing': group['packing'], 'upgrade_of': group['upgrade_of'], **_recipe_options(group)}
        if upgrades:
            output, replacements, consumed, claimed = _render_selection(entries, replacements, records)
        else:
            output = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
        if upgrades:
            active = {_identity([entries[index] for index in record['original_indexes']], mode, **_recipe_options(record))
                for record in records if record.get('accepted')}
            revalidated = [identity for identity in revalidated if identity in active]
            revalidated.extend(group['id'] for group in upgrade_observations
                if group['accepted'] and group['id'] in completed_upgrades and group['id'] in active)
        metrics = _merge_metrics(entries, legacy, replacements, claimed, records)
        metrics['invalidated_group_count'] = legacy.get('invalidated_group_count', 0)
    current = {'replacements': replacements, 'claimed': claimed, 'records': records, 'metrics': metrics}
    if mode == '1':
        tier1 = current
        _reuse_completed(entries, plan['legacy_store'], clangd, profile, mode='strict',
            catalog_only=True, excluded=claimed, selection=strict)
    else:
        strict = current
    output, metrics = _compose_selection(entries, tier1, strict)
    records = metrics['groups']
    summary = {key: metrics[key] for key in ('original_ubt_count', 'exact_count', 'shader_count',
        'other_count', 'batch_count', 'accepted_ubt_count', 'retained_ubt_count', 'output_entries')}
    marker_summary = dict(summary)
    # This is admission by collect, distinct from planned/proven groups and
    # frozen activation or the translation units a client actually indexes.
    summary['collect_accepted_count'] = metrics['batch_count']
    marker = json.loads(Path(marker_path).read_text(encoding='utf-8'))
    marker.update(entry_count=len(output),
        native_background_entry_count=sum(entry.get('nvim_ue_background_route') != 'shader-compatibility'
            for entry in output),
        unity_entry_count=sum('super_unity_cpps' in str(entry.get('file', '')).replace('\\', '/')
            for entry in entries), verified_batches=marker_summary)
    _read_source(plan['input_path'], plan['input_sha256'])
    catalog_value = {'schema': 1, 'mode': mode,
        'groups': [group for group in catalog.values() if 'strict_recipe' not in group]
            if mode == 'strict' else [catalog[key] for key in sorted(catalog)]}
    catalog_outputs = [(str(_catalog_path(plan['legacy_store'], mode)), _json(catalog_value))]
    if mode == 'strict':
        import cdb_ordered_batch
        ordered_groups = [group for group in catalog.values() if group.get('strict_recipe') == cdb_ordered_batch.RECIPE]
        ordered_path = _catalog_path(plan['legacy_store'], mode, cdb_ordered_batch.RECIPE)
        if ordered_groups or 'strict_recipe' in plan or ordered_path.exists():
            catalog_outputs.append((str(ordered_path), _json({'schema': 1, 'mode': 'strict',
                'strict_recipe': cdb_ordered_batch.RECIPE, 'groups': ordered_groups})))
    background_content, background_changed = _publication_content(background, output)
    marker_content, marker_changed = _publication_content(marker_path, marker)
    write_outputs_if_changed([(str(background), background_content), (str(marker_path), marker_content)] + catalog_outputs)
    result = {'ok': True, 'mode': mode, 'changed': background_changed or marker_changed, 'metrics': summary, 'groups': records,
        'revalidated_completed': revalidated,
        'completed_at': time.time(), 'input_sha256': plan['input_sha256']}
    if upgrade_observations:
        result['upgrade_observations'] = upgrade_observations
    result['observations'] = {key: metrics[key] for key in ('proof_accepted_count',
        'proof_rejected_count', 'proof_uncached_count', 'selector_reuse_status')}
    result['observations'].update(plan_candidate_count=plan.get('plan_candidate_count', len(plan['groups'])),
        collect_accepted_count=metrics['batch_count'], families=metrics['families'])
    if publish_request:
        request = json.loads(Path(publish_request).read_text(encoding='utf-8'))
        publication_result = Path(request['publication_result'])
        # Exit status alone must never allow an old successful response to stand
        # in for a worker that did not write this invocation's result.
        publication_result.unlink(missing_ok=True)
        cwd = profile.get('launch_cwd') if profile else None
        completed_process = subprocess.run([str(nvim), '--headless', '-u', 'NONE', '-l',
            str(publish_worker), str(publish_request)], cwd=cwd or str(Path(plan['input_path']).parent),
            text=True, capture_output=True, timeout=90)
        if completed_process.returncode != 0:
            raise ValueError('background-proof-publication-worker-failed: ' + completed_process.stderr.strip())
        activation = json.loads(publication_result.read_text(encoding='utf-8'))
        if not isinstance(activation, dict) or activation.get('ok') is not True:
            raise ValueError('background-proof-publication-worker-rejected')
        _read_source(plan['input_path'], plan['input_sha256'])
        result.update(activation=activation, owned_job=job_handle is not None, completed_at=time.time())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--plan')
    action.add_argument('--worker')
    action.add_argument('--collect')
    parser.add_argument('--store')
    parser.add_argument('--tier1-upgrades', type=json.loads, default=None)
    parser.add_argument('--auto-tier1-large', action='store_true')
    parser.add_argument('--residual-strict-limit', type=int, choices=(1, 2))
    parser.add_argument('--strict-recipe')
    parser.add_argument('--group-indexes', type=json.loads)
    parser.add_argument('--max-group', type=int, default=8)
    parser.add_argument('--max-sources', type=int, default=80)
    parser.add_argument('--group')
    parser.add_argument('--completed', type=json.loads, default=[])
    parser.add_argument('--background')
    parser.add_argument('--marker')
    parser.add_argument('--publish-request')
    parser.add_argument('--nvim')
    parser.add_argument('--publish-worker')
    parser.add_argument('--clangd', required=True)
    parser.add_argument('--server-profile', type=json.loads, default=None)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    try:
        publication_args = (args.publish_request, args.nvim, args.publish_worker)
        if any(publication_args) and (not all(publication_args) or not args.collect):
            raise ValueError('background-proof-publication-worker-options-required-together-for-collect')
        if args.tier1_upgrades is not None and not args.plan:
            raise ValueError('background-proof-upgrades-require-plan')
        if args.auto_tier1_large and not args.plan:
            raise ValueError('background-proof-auto-tier1-large-requires-plan')
        if args.residual_strict_limit is not None and not args.plan:
            raise ValueError('background-proof-residual-strict-requires-plan')
        if (args.strict_recipe is not None or args.group_indexes is not None
                or args.max_group != 8 or args.max_sources != 80) and not args.plan:
            raise ValueError('background-proof-ordered-options-require-plan')
        if args.plan:
            if not args.store:
                raise ValueError('background-proof-store-required')
            result = make_plan(args.plan, args.store, args.clangd, args.server_profile, args.out,
                args.tier1_upgrades, args.auto_tier1_large, args.residual_strict_limit,
                strict_recipe=args.strict_recipe, group_indexes=args.group_indexes,
                max_group=args.max_group, max_sources=args.max_sources)
        elif args.worker:
            if not args.group:
                raise ValueError('background-proof-group-required')
            result = work(args.worker, args.group, args.clangd, args.server_profile)
        else:
            if not args.background or not args.marker:
                raise ValueError('background-proof-publication-paths-required')
            result = collect(args.collect, args.completed, args.background, args.marker, args.clangd, args.server_profile,
                args.publish_request, args.nvim, args.publish_worker)
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        result = {'ok': False, 'reason': str(error)}
    _write(args.out, result)
    print(_json(result))
    return 0 if result.get('ok', True) else 1


if __name__ == '__main__':
    raise SystemExit(main())
