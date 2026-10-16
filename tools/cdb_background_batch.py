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
from build_hot_super_unity_cdb import secondary_unity_chunks, write_outputs_if_changed


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


def _chunks(entries, mode):
    return secondary_unity_chunks(entries, max_unities=8,
        **({'max_sources': 80} if mode == 'strict' else {}))


def _identity(entries, mode):
    value = entries if mode == 'strict' else {'tier': 1, 'entries': entries}
    return _sha(_json(value).encode('utf-8'))


def _cache_only(entries, store, clangd, profile, mode=None):
    mode = mode or _mode()
    if mode == '1':
        # The Tier 1 cache binds wrappers, member sources and owned overlays.
        # Header changes deliberately do not invalidate its receipt.
        return verified.reuse_tier1(entries, store, clangd, max_group=8,
            server_profile=profile)
    if not Path(store).is_dir():
        # accelerate creates its artifact root even in cache-only mode. An
        # absent advisory store must not mutate watched lookup inventories.
        ubt = sum(verified._is_ubt(entry) for entry in entries)
        shaders = {'.usf', '.ush', '.hlsl', '.hlsli', '.glsl', '.vert', '.frag', '.geom', '.tesc', '.tese', '.comp', '.metal'}
        shader = sum(Path(entry.get('file', '')).suffix.lower() in shaders for entry in entries)
        exact = sum(not verified._is_ubt(entry) and Path(entry.get('file', '')).suffix.lower()
            in ('.c', '.cc', '.cpp', '.cxx', '.c++') for entry in entries)
        groups = [{'original_indexes': chunk, 'accepted': False, 'deferred': True,
            'reason': 'verification-not-cached', 'run_metrics': []}
            for chunk in secondary_unity_chunks(entries, max_sources=80, max_unities=8)]
        return list(entries), {'original_ubt_count': ubt, 'exact_count': exact, 'shader_count': shader,
            'other_count': len(entries) - ubt - shader - exact, 'batch_count': 0, 'groups': groups}
    return verified.accelerate(entries, store, clangd, max_group=8, max_sources=80,
        verify_missing=False, server_profile=profile)


def _tier1_receipt(entries, candidate):
    raw = Path(candidate['nvim_ue_tier1_receipt']).read_bytes()
    if _sha(raw) != candidate.get('nvim_ue_tier1_receipt_sha256'):
        raise ValueError('background-proof-tier1-receipt-sha-mismatch')
    receipt = json.loads(raw.decode('utf-8'))
    members = [member for entry in entries for member in entry['nvim_ue_members']]
    if (receipt.get('schema') != 1 or receipt.get('tier') != 1
            or receipt.get('accepted') is not True or receipt.get('reusable') is not True
            or receipt.get('original_entries') != [verified._native(entry) for entry in entries]
            or receipt.get('candidate') != verified._native(candidate)
            or not all(receipt.get('gates', {}).get(name) is True for name in
                ('compile_success', 'main_shards_complete', 'members_equal'))
            or len(members) != len(set(members))
            or receipt.get('members') != candidate.get('nvim_ue_members')
            or sorted(receipt.get('members', [])) != sorted(members)):
        raise ValueError('background-proof-tier1-receipt-mismatch')


def _replacements(entries, output, metrics, mode=None):
    """Accept replacements only for groups actually admitted by the proof gate."""
    anchors, consumed, claimed = {}, set(), set()
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
                _tier1_receipt([entries[position] for position in anchors[index]], value)
            replacements[index] = value
        elif value != entry:
            raise ValueError('background-proof-original-command-changed')
    return replacements, consumed, claimed


def _catalog_path(store, mode=None):
    root = Path(store).resolve().parent / 'background-proofs'
    return (root / 'tier1' if (mode or _mode()) == '1' else root) / 'catalog.json'


def _catalog(store, mode=None):
    mode = mode or _mode()
    try:
        value = json.loads(_catalog_path(store, mode).read_text(encoding='utf-8'))
        return value['groups'] if (value.get('schema') == 1 and value.get('mode', 'strict') == mode
            and isinstance(value.get('groups'), list)) else []
    except (OSError, ValueError, TypeError, KeyError):
        return []


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
    with verified.tier1_overlay_scope(_mode() == '1'):
        return _reuse_completed(entries, legacy_store, clangd, server_profile)


def _reuse_completed(entries, legacy_store, clangd, server_profile):
    started = time.monotonic()
    mode = _mode()
    output, legacy = _cache_only(entries, legacy_store, clangd, server_profile, mode)
    replacements, consumed, claimed = _replacements(entries, output, legacy, mode)
    records = list(legacy['groups'])
    positions = {}
    for index, entry in enumerate(entries):
        positions.setdefault(_sha(_json(entry).encode('utf-8')), []).append(index)
    for group in _catalog(legacy_store, mode):
        try:
            hashes = group['entry_hashes']
            if not isinstance(hashes, list) or any(len(positions.get(value, [])) != 1 for value in hashes):
                continue
            indexes = [positions[value][0] for value in hashes]
            if claimed.intersection(indexes) or len(set(indexes)) != len(indexes):
                continue
            selected = [entries[index] for index in indexes]
            identity = _identity(selected, mode)
            expected_store = _catalog_path(legacy_store, mode).parent / identity
            if (identity != group['id'] or Path(group['store']).resolve() != expected_store
                    or _chunks(selected, mode)
                    != [list(range(len(selected))) ]):
                continue
            output, metrics = _cache_only(selected, expected_store, clangd, server_profile, mode)
            local_replacements, local_consumed, local_claimed = _replacements(selected, output, metrics, mode)
            replacements.update({indexes[index]: value for index, value in local_replacements.items()})
            consumed.update(indexes[index] for index in local_consumed)
            claimed.update(indexes[index] for index in local_claimed)
            records.extend(dict(record, original_indexes=[indexes[index] for index in record['original_indexes']])
                for record in metrics['groups'])
        except (OSError, ValueError, KeyError, TypeError):
            continue  # A corrupt or stale advisory catalog never grants admission.
    output = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    if mode == '1':
        # Prefer a revalidated catalog record over the root store's cache miss.
        records = list({tuple(record['original_indexes']): record for record in records}.values())
    metrics = _merge_metrics(entries, legacy, replacements, claimed, records)
    metrics['proof_seconds'] = round(time.monotonic() - started, 6)
    return output, metrics


def _pending_result_hints(previous_path, plan, entries):
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
            or previous.get('server_profile') != plan['server_profile']):
        return []
    current_groups = {group['id']: group for group in plan['groups']}
    hints = []
    seen = set()
    for group in previous['groups']:
        if not isinstance(group, dict) or not isinstance(group.get('id'), str):
            continue
        identity = group['id']
        if identity in seen or (identity in current_groups and current_groups[identity] != group):
            continue
        seen.add(identity)
        try:
            # Validate the old group's indexes/store against CURRENT source bytes.
            # A valid cached group may disappear from the new work plan after reuse.
            _group(dict(plan, groups=[group]), entries, identity)
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
                plan['groups'].append(group)
                current_groups[identity] = group
            hints.append({'id': identity, 'accepted_hint': count})
    return hints


def make_plan(source, store, clangd, profile=None, previous_path=None):
    source, store = Path(source).resolve(), Path(store).resolve()
    entries, digest = _read_source(source)
    mode = _mode()
    output, metrics = reuse_completed(entries, store, clangd, profile)
    _, _, claimed = _replacements(entries, output, metrics, mode)
    # Tier 1 chunks must stay identical to prepare's full-input cache lookup;
    # removing admitted groups first could regroup the remaining originals.
    available = [(index, entry) for index, entry in enumerate(entries)
        if mode == '1' or index not in claimed]
    candidates = _chunks([entry for _, entry in available], mode)
    rejected = {tuple(record['original_indexes']) for record in metrics['groups']
        if record.get('cached') and not record.get('accepted') and not record.get('deferred')}
    groups = []
    for chunk in candidates:
        indexes = [available[index][0] for index in chunk]
        if mode == '1' and (claimed.intersection(indexes) or tuple(indexes) in rejected):
            continue
        selected = [entries[index] for index in indexes]
        identity = _identity(selected, mode)
        groups.append({'id': identity, 'indexes': indexes,
            'store': str(_catalog_path(store, mode).parent / identity),
            'ubt_count': len(indexes),
            'member_count': sum(len(entry['nvim_ue_members']) for entry in selected)})
    groups.sort(key=lambda group: (group['member_count'], group['ubt_count'], group['indexes'][0]))
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
    plan['recovered_completed'] = _pending_result_hints(previous_path, plan, entries)
    return plan


def _load_plan(path, profile):
    plan = json.loads(Path(path).read_text(encoding='utf-8'))
    if plan.get('schema') != 1 or plan.get('server_profile') != profile:
        raise ValueError('background-proof-plan-profile-mismatch')
    if plan.get('mode', 'strict') != _mode():
        raise ValueError('background-proof-plan-tier-mismatch')
    entries, _ = _read_source(plan['input_path'], plan['input_sha256'])
    return plan, entries


def _group(plan, entries, identity):
    matches = [group for group in plan['groups'] if group['id'] == identity]
    if len(matches) != 1:
        raise ValueError('background-proof-group-not-found')
    group = matches[0]
    indexes = group['indexes']
    if (not isinstance(indexes, list) or len(set(indexes)) != len(indexes)
            or any(type(index) is not int or index < 0 or index >= len(entries) for index in indexes)):
        raise ValueError('background-proof-invalid-indexes')
    selected = [entries[index] for index in indexes]
    mode = plan.get('mode', 'strict')
    expected_store = _catalog_path(plan['legacy_store'], mode).parent / identity
    if (_identity(selected, mode) != identity
            or Path(group['store']).resolve() != expected_store
            or _chunks(selected, mode) != [list(range(len(selected))) ]):
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
    job_handle = _owned_job()
    if plan.get('mode', 'strict') == '1':
        output, metrics = verified.accelerate_tier1(selected, group['store'], clangd,
            max_group=8, timeout=90, server_profile=profile)
    else:
        output, metrics = verified.accelerate(selected, group['store'], clangd,
            max_group=8, max_sources=80, timeout=90, verify_missing=True,
            max_new_groups=None, server_profile=profile)
    _replacements(selected, output, metrics, plan.get('mode', 'strict'))
    _read_source(plan['input_path'], plan['input_sha256'])
    return {'ok': True, 'mode': plan.get('mode', 'strict'),
        'group_id': identity, 'input_sha256': plan['input_sha256'],
        'completed_at': time.time(), 'metrics': metrics, 'owned_job': job_handle is not None}


def collect(plan_path, completed, background, marker_path, clangd, profile=None,
        publish_request=None, nvim=None, publish_worker=None):
    with verified.tier1_overlay_scope(_mode() == '1'):
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
    output, legacy = reuse_completed(entries, plan['legacy_store'], clangd, profile)
    replacements, consumed, claimed = _replacements(entries, output, legacy, mode)
    records = list(legacy['groups'])
    catalog = {group['id']: group for group in _catalog(plan['legacy_store'], mode)
        if isinstance(group, dict) and 'id' in group}
    revalidated = []
    for identity in dict.fromkeys(completed):
        group, selected = _group(plan, entries, identity)
        if claimed.intersection(group['indexes']):
            if set(group['indexes']).issubset(claimed):
                revalidated.append(identity)
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
    output = [replacements.get(index, entry) for index, entry in enumerate(entries) if index not in consumed]
    if mode == '1':
        records = list({tuple(record['original_indexes']): record for record in records}.values())
    metrics = _merge_metrics(entries, legacy, replacements, claimed, records)
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
    catalog_value = {'schema': 1, 'mode': mode, 'groups': [catalog[key] for key in sorted(catalog)]}
    background_content, background_changed = _publication_content(background, output)
    marker_content, marker_changed = _publication_content(marker_path, marker)
    write_outputs_if_changed([(str(background), background_content), (str(marker_path), marker_content),
        (str(_catalog_path(plan['legacy_store'], mode)), _json(catalog_value))])
    result = {'ok': True, 'mode': mode, 'changed': background_changed or marker_changed, 'metrics': summary, 'groups': records,
        'revalidated_completed': revalidated,
        'completed_at': time.time(), 'input_sha256': plan['input_sha256']}
    result['observations'] = {key: metrics[key] for key in ('proof_accepted_count',
        'proof_rejected_count', 'proof_uncached_count', 'selector_reuse_status')}
    result['observations'].update(plan_candidate_count=plan.get('plan_candidate_count', len(plan['groups'])),
        collect_accepted_count=metrics['batch_count'])
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
        if args.plan:
            if not args.store:
                raise ValueError('background-proof-store-required')
            result = make_plan(args.plan, args.store, args.clangd, args.server_profile, args.out)
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
