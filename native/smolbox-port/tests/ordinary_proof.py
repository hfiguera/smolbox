#!/usr/bin/env python3
"""Explicit normal VM lifecycle proof; no deliberate process interruption."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import time

from native_proof import Port, observed, operation, save, snapshot


def check_upgrade(previous, replacement):
    for key in ['platform', 'architecture', 'engine_version', 'smolvm_revision']:
        assert previous['identity'][key] == replacement['identity'][key], 'incompatible upgrade tuple'
    if previous.get('schema') == 2 or replacement.get('schema') == 2:
        assert previous.get('schema') == replacement.get('schema') == 2, \
            'patched-to-clean migration requires drain/delete and fresh enrollment'
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


def prove(args):
    if args.child_reaping:
        assert os.uname().sysname == 'Linux' and os.uname().nodename == 'smolbox-nested'
    reaping = []
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package, fixture = args.package.resolve(), args.fixture.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
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
    save(config, {'schema': 1, **domain, 'allow_initialize': False,
                  'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
                  'approved_artifacts': [artifact]})
    before = snapshot()
    save(output / 'inventory-before.json', before)
    create = {'name': 'sb-ordinary-' + secrets.token_hex(8),
              'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact,
              'resources': {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1},
              'labels': {'proof': 'ordinary-lifecycle'}}
    save(output / 'intent.json', create)
    port = Port(package, config, output / 'first.stderr')
    try:
        created, events = port.call({'operation': 'create', 'create': create})
        assert created['result'] == 'created' and not events
        receipt = created['receipt']
        save(output / 'receipt.json', receipt)
        observed(port, 'start', receipt, 'running')
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
        observed(port, 'start', receipt, 'running')
        read_exact(port)
        observed(port, 'stop', receipt, 'stopped')
        stopped_children(port, args.child_reaping, reaping)
        epoch = port.hello['epoch']
        port.close()
        if upgrade:
            config = output / 'upgrade-config.json'
            save(config, {'schema': 1, **domain, 'allow_initialize': False,
                         'package_manifest_sha256': hashlib.sha256(next_manifest_bytes).hexdigest(),
                         'approved_artifacts': [artifact]})
        port = Port(next_package, config, output / 'second.stderr')
        assert port.hello['epoch'] != epoch
        observed(port, 'inspect', receipt, 'stopped')
        observed(port, 'start', receipt, 'running')
        read_exact(port)
        observed(port, 'stop', receipt, 'stopped')
        stopped_children(port, args.child_reaping, reaping)
        observed(port, 'delete', receipt, 'missing')
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
    prove(parser.parse_args())
