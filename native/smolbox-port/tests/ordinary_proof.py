#!/usr/bin/env python3
"""Explicit normal VM lifecycle proof; no deliberate process interruption."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import time

from native_proof import Port, config_schema, observed, operation, save, snapshot


def check_upgrade(previous, replacement):
    for key in ['platform', 'architecture', 'engine_version', 'smolvm_revision']:
        assert previous['identity'][key] == replacement['identity'][key], 'incompatible upgrade tuple'
    if previous.get('schema', 0) >= 2 or replacement.get('schema', 0) >= 2:
        assert previous.get('schema') == replacement.get('schema') and previous['schema'] in (2, 3), \
            'native protocol migration requires drain/delete and fresh enrollment'
        assert previous['policy'] == replacement['policy'], 'incompatible native policy'


def children(port):
    assert port.process.poll() is None
    found = set()
    for task in Path(f'/proc/{port.process.pid}/task').iterdir():
        try:
            found.update(int(pid) for pid in (task / 'children').read_text().split())
        except FileNotFoundError:
            pass  # A worker thread may finish while sampling.
    return found


def stopped_children(port, enabled, witnesses):
    if not enabled:
        return
    deadline = time.monotonic() + 5
    while children(port):
        assert time.monotonic() < deadline, 'stopped helper retained child processes'
        time.sleep(0.05)
    witnesses.append({'stopped_helper_children': 0})


def terminal_preflight(port, receipt, state):
    """Observe eligibility without mutation, terminal events or new children."""
    before = snapshot()
    owned_children = children(port) if os.uname().sysname == 'Linux' else None
    outcome, events = port.call(operation('terminal_preflight', receipt), budget=2000)
    assert not events, 'preflight emitted terminal or stream events'
    if state == 'missing':
        assert outcome == {'result': 'error', 'code': 'not_found',
                           'dispatch': 'not_dispatched'}, outcome
    else:
        assert outcome == {'result': 'ready'}, outcome
    assert snapshot() == before, 'preflight changed SDK machine records'
    if owned_children is not None:
        assert children(port) == owned_children, 'preflight changed owned children'
    observed(port, 'inspect', receipt, state)
    return {'state': state, 'no_stream_events': True,
            'sdk_records_unchanged': True,
            'owned_children_unchanged': owned_children is not None}


def observe_native(port, state, resources, receipt=None):
    """Bind ordinary read-only results to one isolated owned lifecycle."""
    count = int(state not in (None, 'missing'))
    running = int(state == 'running')
    health, events = port.call({'operation': 'health'})
    assert not events and health['result'] == 'health'
    assert health['snapshot']['total'] == count and health['snapshot']['running'] == running
    capacity, events = port.call({'operation': 'capacity'})
    assert not events and capacity['result'] == 'capacity'
    allocated = capacity['snapshot']
    assert allocated['allocated_cpus'] == running * resources['cpus']
    assert allocated['allocated_memory_mb'] == running * resources['memory_mib']
    metrics, events = port.call({'operation': 'metrics'})
    assert not events and metrics['result'] == 'metrics'
    gauges = dict(line.split() for line in metrics['text'].splitlines()
                  if line and not line.startswith('#'))
    assert float(gauges['smolbox_native_machines']) == count
    assert float(gauges['smolbox_native_running_machines']) == running
    assert float(gauges['smolbox_native_allocated_cpus']) == running * resources['cpus']
    assert float(gauges['smolbox_native_allocated_memory_mb']) == running * resources['memory_mib']
    ready, events = port.call({'operation': 'readiness'}, budget=2000)
    assert not events and ready['result'] == 'ready'
    inventory, events = port.call({'operation': 'list'})
    assert inventory['result'] == 'inventory' and inventory['count'] == count
    assert all(stream == 'file' for stream, _ in events)
    encoded = b''.join(data for _, data in events)
    assert inventory['bytes'] == len(encoded)
    records = json.loads(encoded)
    assert isinstance(records, list) and len(records) == count
    if count:
        assert records[0]['name'] == receipt['name'] and records[0]['state'] == state
        assert records[0]['cpus'] == resources['cpus']
        assert records[0]['memoryMb'] == resources['memory_mib']
    sampled = None
    if receipt is not None:
        measured, events = port.call(operation('measurements', receipt))
        assert not events and measured['result'] == 'measurements'
        assert measured['observation']['state'] == state
        counters = measured['counters']
        if running:
            assert measured['observation']['resources'] == resources
            assert type(counters['cpu_millis']) is int and counters['cpu_millis'] >= 0
            assert type(counters['rss_mb']) is int and counters['rss_mb'] > 0
            sampled = True
        else:
            # A stopped/absent process is unavailable, not a fabricated zero.
            assert counters['cpu_millis'] is None and counters['rss_mb'] is None
            sampled = False
    return {'state': state or 'empty', 'total': count, 'running': running,
            'allocated_cpus': allocated['allocated_cpus'],
            'allocated_memory_mb': allocated['allocated_memory_mb'],
            'inventory_count': len(records), 'running_process_sampled': sampled,
            'metrics_bound_to_lifecycle': True, 'readiness': True}


def prove(args):
    if args.child_reaping:
        assert os.uname().sysname == 'Linux' and os.uname().nodename == 'smolbox-nested'
    reaping = []
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package, fixture = args.package.resolve(), args.fixture.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    if args.terminal_preflight:
        assert manifest['policy']['sdk']['feature_versions'].get('terminal_preflight') == 1
    assert manifest['identity']['platform'] == ('macos' if os.uname().sysname == 'Darwin' else 'linux')
    with fixture.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == args.sha256
    artifact = {'path': str(fixture), 'sha256': args.sha256,
                'max_bytes': fixture.stat().st_size,
                'guest_platform': 'linux/arm64' if manifest['identity']['architecture'] == 'aarch64' else 'linux/amd64'}
    domain = json.loads(args.domain_json.read_text())
    upgrade = None
    next_package = package
    next_manifest_bytes = manifest_bytes
    if args.upgrade_package:
        next_package = args.upgrade_package.resolve()
        next_manifest_bytes = (next_package / 'package.json').read_bytes()
        next_manifest = json.loads(next_manifest_bytes)
        check_upgrade(manifest, next_manifest)
        assert next_manifest_bytes != manifest_bytes, 'upgrade must exercise a different package'
        upgrade = {'from_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
                   'to_manifest_sha256': hashlib.sha256(next_manifest_bytes).hexdigest(),
                   'from_identity': manifest['identity'], 'to_identity': next_manifest['identity'],
                   'retained_full_receipt': True, 'domain_generation_unchanged': True,
                   'old_assets_retained_during_upgrade': True, 'codec_rollback_qualified': False}
    config = output / 'config.json'
    save(config, {'schema': config_schema(manifest), **domain, 'allow_initialize': False,
                  'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
                  'approved_artifacts': [artifact]})
    before = snapshot()
    if args.observability:
        assert before == [], 'observability qualification requires an isolated empty SDK inventory'
        assert manifest['policy']['sdk']['feature_versions'].get('observability') == 1
    save(output / 'inventory-before.json', before)
    create = {'name': 'sb-ordinary-' + secrets.token_hex(8),
              'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact,
              'resources': {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1},
              'labels': {'proof': 'ordinary-lifecycle'}}
    save(output / 'intent.json', create)
    port = Port(package, config, output / 'first.stderr')
    observations = []
    preflights = []

    def observe(current, state, receipt=None):
        if args.observability:
            observations.append(observe_native(current, state, create['resources'], receipt))
        if args.terminal_preflight and receipt is not None:
            preflights.append(terminal_preflight(current, receipt, state))

    try:
        observe(port, None)
        created, events = port.call({'operation': 'create', 'create': create})
        save(output / 'create-result.json', created)
        assert created['result'] == 'created' and not events, created
        receipt = created['receipt']
        save(output / 'receipt.json', receipt)
        observe(port, 'stopped', receipt)
        observed(port, 'start', receipt, 'running')
        observe(port, 'running', receipt)
        command = {'argv': ['/bin/sh', '-c',
                           'printf "cpu=%s mem_kib=%s storage_sectors=%s overlay_sectors=%s env=%s cwd=%s user=%s" '
                           '"$(nproc)" "$(awk \'/MemTotal/ {print $2}\' /proc/meminfo)" '
                           '"$(cat /sys/block/vda/size)" "$(cat /sys/block/vdb/size)" '
                           '"$SMOLBOX_ORDINARY" "$PWD" "$(id -u)"; exit 7'],
                   'env': {'SMOLBOX_ORDINARY': 'set'}, 'workdir': '/workspace',
                   'user': '65534:65534', 'max_output_bytes': 4096}
        result, events = port.call(operation('exec', receipt, command=command))
        assert result['result'] == 'command' and result['completion'] == 'exited'
        assert result['observed_exit'] == 7 and result['running_observed']
        stdout = b''.join(data for stream, data in events if stream == 'stdout').decode()
        assert not any(data for stream, data in events if stream == 'stderr')
        fields = dict(part.split('=', 1) for part in stdout.split())
        assert fields['cpu'] == '1' and fields['env'] == 'set'
        assert fields['cwd'] == '/workspace' and fields['user'] == '65534'
        assert fields['storage_sectors'] == fields['overlay_sectors'] == '2097152'
        allowance = 2048 if manifest['identity']['platform'] == 'linux' else 0
        assert 400000 <= int(fields['mem_kib']) <= 524288 + allowance
        save(output / 'resource-witness.json', {'stdout': stdout, 'observed_exit': 7})
        data = bytes(range(256)) * 4096 + b'ordinary-retained'
        options = {'guest_path': '/workspace/ordinary-retained.bin',
                   'max_bytes': 2 * 1024 * 1024, 'mode': 0o600}
        written, _ = port.call(operation('write_file', receipt, options=options, total_bytes=len(data)), upload=data)
        save(output / 'write-result.json', written)
        assert written['result'] == 'file' and written['completion'] == 'completed', written
        assert written['native_acknowledged'] and written['observed_bytes'] == len(data)
        options['mode'] = None

        def read_exact(current):
            read, chunks = current.call(operation('read_file', receipt, options=options))
            assert read['result'] == 'file' and read['completion'] == 'completed'
            assert read['native_acknowledged'] and read['observed_bytes'] == len(data)
            assert b''.join(chunk for _, chunk in chunks) == data

        read_exact(port)
        observed(port, 'stop', receipt, 'stopped')
        stopped_children(port, args.child_reaping, reaping)
        observe(port, 'stopped', receipt)
        observed(port, 'start', receipt, 'running')
        read_exact(port)
        observed(port, 'stop', receipt, 'stopped')
        stopped_children(port, args.child_reaping, reaping)
        epoch = port.hello['epoch']
        port.close()
        if upgrade:
            config = output / 'upgrade-config.json'
            save(config, {'schema': config_schema(next_manifest), **domain, 'allow_initialize': False,
                         'package_manifest_sha256': hashlib.sha256(next_manifest_bytes).hexdigest(),
                         'approved_artifacts': [artifact]})
        port = Port(next_package, config, output / 'second.stderr')
        assert port.hello['epoch'] != epoch
        observed(port, 'inspect', receipt, 'stopped')
        observe(port, 'stopped', receipt)
        observed(port, 'start', receipt, 'running')
        read_exact(port)
        observed(port, 'stop', receipt, 'stopped')
        stopped_children(port, args.child_reaping, reaping)
        observed(port, 'delete', receipt, 'missing')
        observe(port, 'missing', receipt)
        port.close()
        after = snapshot()
        assert after == before, 'inventory changed beyond owned fixture deletion'
        evidence = {'proof': 'passed', 'scope': 'compatible-native-package-upgrade' if upgrade else 'ordinary-native-lifecycle',
                    'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
                    'identity': manifest['identity'], 'fixture_sha256': args.sha256,
                    'observed_exit': 7, 'resource_witness': stdout,
                    'file_bytes': len(data), 'file_sha256': hashlib.sha256(data).hexdigest(),
                    'retained_after_stop_start': True,
                    'retained_after_stopped_helper_shutdown': True,
                    'fresh_epoch': True, 'owned_deleted': True,
                    'inventory_before': before, 'inventory_after': after,
                    'upgrade': upgrade,
                    'normal_stop_child_reaping': reaping,
                    'ordinary_observability': observations,
                    'ordinary_terminal_preflight': preflights,
                    'deliberate_process_interruption': False,
                    'crash_handling_qualified': False}
        save(output / 'evidence.json', evidence)
        print(json.dumps(evidence))
    finally:
        # Normal shutdown retains uncertain storage and authentic receipts.
        # No injected signals, boot pauses or simulated watcher failures.
        if port.process.poll() is None:
            port.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['package', 'fixture', 'domain-json', 'output']:
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--upgrade-package', type=Path)
    parser.add_argument('--child-reaping', action='store_true')
    parser.add_argument('--observability', action='store_true',
                        help='check ordinary observations against an isolated empty SDK lifecycle')
    parser.add_argument('--terminal-preflight', action='store_true',
                        help='check standalone read-only image eligibility during ordinary lifecycle')
    prove(parser.parse_args())
