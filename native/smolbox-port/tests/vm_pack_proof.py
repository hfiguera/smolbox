#!/usr/bin/env python3
"""Explicit ordinary live bare-VM pack proof using saved full receipts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess

from native_proof import Port, observed, operation, save, snapshot

RESOURCES = {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1}
ROOT = '/etc/smolbox-vm-root-witness'
STORAGE = '/workspace/smolbox-vm-storage-witness'


def spec(path, platform):
    with path.open('rb') as file:
        digest = hashlib.file_digest(file, 'sha256').hexdigest()
    return {'path': str(path), 'sha256': digest, 'max_bytes': path.stat().st_size,
            'guest_platform': platform}


def fixture_tool(args, output, name, *arguments):
    environment = os.environ.copy()
    # Only the authoring tool needs an explicit library path. Port clears it
    # and proves the signed helper resolves its own packaged dependencies.
    environment['DYLD_LIBRARY_PATH'] = str(args.package.resolve() / 'lib')
    environment.pop('SMOLBOX_FIXTURE_QEMU_IMG', None)
    if args.qemu_img:
        environment['SMOLBOX_FIXTURE_QEMU_IMG'] = str(args.qemu_img.resolve())
    for key in ['SMOLVM_DATA_DIR', 'SMOLVM_BOOT_DEBUG', 'SMOLVM_AGENT_ROOTFS_TAR']:
        environment.pop(key, None)
    log_path = output / name
    with log_path.open('xb') as log:
        os.chmod(log_path, 0o600)
        subprocess.run([str(args.fixture_tool.resolve()), *map(str, arguments)],
                       env=environment, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=180)


def execute(port, receipt, script, exit_code=0):
    command = {'argv': ['/bin/sh', '-c', script], 'env': {}, 'workdir': '/workspace',
               'user': None, 'max_output_bytes': 65536}
    result, events = port.call(operation('exec', receipt, command=command))
    assert result['result'] == 'command' and result['completion'] == 'exited'
    assert result['observed_exit'] == exit_code and result['running_observed']
    return b''.join(data for stream, data in events if stream == 'stdout').decode().strip()


def verify_witness(port, receipt):
    result = execute(port, receipt,
                     f'test "$(cat {ROOT})" = root-snapshot && '
                     f'test "$(cat {STORAGE})" = storage-snapshot && '
                     'test ! -e /workspace/implicit-vm-workload && '
                     'printf "cpu=%s mem_kib=%s storage_sectors=%s overlay_sectors=%s uid=%s" '
                     '"$(nproc)" "$(awk \'/MemTotal/ {print $2}\' /proc/meminfo)" '
                     '"$(cat /sys/block/vda/size)" "$(cat /sys/block/vdb/size)" "$(id -u)"')
    fields = dict(part.split('=', 1) for part in result.split())
    memory_allowance = 2048 if port.hello['package']['platform'] == 'linux' else 0
    assert fields['cpu'] == '1' and 400000 <= int(fields['mem_kib']) <= 524288 + memory_allowance
    assert fields['storage_sectors'] == fields['overlay_sectors'] == '2097152'
    assert fields['uid'] == '0'
    return result


def prove(args):
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    package = args.package.resolve()
    domain_path = args.domain_json.resolve()
    domain = json.loads(domain_path.read_bytes())
    manifest_bytes = (package / 'package.json').read_bytes()
    identity = json.loads(manifest_bytes)['identity']
    platform = 'linux/arm64' if identity['architecture'] == 'aarch64' else 'linux/amd64'
    config = {'schema': 1, 'target_id': domain['target_id'], 'generation': domain['generation'],
              'allow_initialize': False, 'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
              'approved_artifacts': []}
    before = snapshot()
    assert before == [], 'proof requires an empty dedicated native domain'
    save(output / 'inventory-before.json', before)
    save(output / 'preflight.json', config)
    port = Port(package, output / 'preflight.json', output / 'preflight.stderr')
    port.close()
    seed = output / 'seed.smolmachine'
    fixture_tool(args, output, 'seed.log', 'vm-seed', seed, package)
    config['approved_artifacts'] = [spec(seed, platform)]
    save(output / 'seed-config.json', config)
    port = Port(package, output / 'seed-config.json', output / 'seed.stderr')
    receipts = []
    try:
        def create(name, artifact):
            result, events = port.call({'operation': 'qualify_creation', 'artifact': artifact,
                                       'resources': RESOURCES, 'user': None})
            assert result == {'result': 'qualified'} and events == []
            result, events = port.call({'operation': 'qualify_creation', 'artifact': artifact,
                                       'resources': RESOURCES, 'user': '65534:65534'})
            assert result['result'] == 'error' and result['code'] == 'unsupported'
            assert result['dispatch'] == 'not_dispatched' and events == []
            request = {'name': 'sb-vm-' + secrets.token_hex(6), 'owner_token': secrets.token_hex(32),
                       'incarnation': secrets.token_hex(16), 'artifact': artifact,
                       'resources': RESOURCES, 'labels': {'proof': name}}
            save(output / f'{name}-intent.json', request)
            result, events = port.call({'operation': 'create', 'create': request})
            assert result['result'] == 'created' and events == []
            receipt = result['receipt']
            receipts.append(receipt)
            save(output / f'{name}-receipt.json', receipt)
            observed(port, 'inspect', receipt, 'stopped')
            observed(port, 'start', receipt, 'running')
            return receipt

        source = create('source', config['approved_artifacts'][0])
        execute(port, source, f'printf root-snapshot > {ROOT}; '
                f'printf storage-snapshot > {STORAGE}; exit 7', exit_code=7)
        verify_witness(port, source)
        observed(port, 'stop', source, 'stopped')
        port.close(eof=True)
        exported = output / 'exported.smolmachine'
        fixture_tool(args, output, 'export.log', 'vm-export', exported, package,
                     domain_path, output / 'source-receipt.json')
        config['approved_artifacts'].append(spec(exported, platform))
        save(output / 'import-config.json', config)
        port = Port(package, output / 'import-config.json', output / 'import.stderr')
        observed(port, 'inspect', source, 'stopped')
        imported = create('import', config['approved_artifacts'][1])
        witness = verify_witness(port, imported)
        observed(port, 'stop', imported, 'stopped')
        observed(port, 'start', imported, 'running')
        assert verify_witness(port, imported) == witness
        data = b'vm-pack-file\x00' * 257
        options = {'guest_path': '/workspace/vm-pack-transfer.bin', 'max_bytes': 4096, 'mode': 0o600}
        result, _ = port.call(operation('write_file', imported, options=options, total_bytes=len(data)), upload=data)
        assert result['completion'] == 'completed' and result['native_acknowledged']
        options['mode'] = None
        old_epoch = port.hello['epoch']
        port.close(eof=True)
        port = Port(package, output / 'import-config.json', output / 'recovery.stderr')
        assert port.hello['epoch'] != old_epoch
        observed(port, 'inspect', imported, 'stopped')
        observed(port, 'start', imported, 'running')
        assert verify_witness(port, imported) == witness
        result, events = port.call(operation('read_file', imported, options=options))
        assert result['completion'] == 'completed' and result['native_acknowledged']
        assert b''.join(chunk for _, chunk in events) == data
        observed(port, 'stop', imported, 'stopped')
        observed(port, 'delete', imported, 'missing')
        observed(port, 'delete', source, 'missing')
        port.close()
        assert snapshot() == before, 'owned deletion did not restore inventory'
        evidence = {'proof': 'passed', 'scope': 'live-bare-vm-pack',
                    'package_manifest_sha256': config['package_manifest_sha256'],
                    'seed_sha256': config['approved_artifacts'][0]['sha256'],
                    'exported_sha256': config['approved_artifacts'][1]['sha256'],
                    'fixture_tool_sha256': spec(args.fixture_tool.resolve(), platform)['sha256'],
                    'host_qemu_img_sha256': spec(args.qemu_img.resolve(), platform)['sha256'] if args.qemu_img else None,
                    'sdk_temporary_export_vm': False,
                    'witness': witness, 'source_observed_exit': 7,
                    'root_and_storage_snapshots_preserved': True, 'implicit_workload_absent': True,
                    'explicit_vm_user_rejected': True, 'retained_after_helper_eof': True,
                    'file_bytes': len(data), 'owned_deleted': True, 'inventory_unchanged': True}
        save(output / 'result.json', evidence)
        print(json.dumps(evidence))
    except BaseException:
        # Only already-returned full receipts authorize cleanup. An uncertain
        # receipt-less create remains for explicit inspection, never replay.
        try:
            if port.process.poll() is not None:
                path = output / 'failure-config.json'
                save(path, config)
                port = Port(package, path, output / 'failure.stderr')
            for receipt in reversed(receipts):
                result, _ = port.call(operation('inspect', receipt))
                if result['result'] == 'observed' and result['observation']['state'] == 'running':
                    observed(port, 'stop', receipt, 'stopped')
                observed(port, 'delete', receipt, 'missing')
            save(output / 'failure-cleanup.json', {'saved_receipts_deleted': len(receipts),
                                                 'inventory_restored': snapshot() == before})
        finally:
            if port.process.poll() is None:
                port.close(eof=True)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['package', 'domain-json', 'fixture-tool', 'output']:
        parser.add_argument('--' + option, required=True, type=Path)
    parser.add_argument('--qemu-img', type=Path,
                        help='explicit approved host converter for qcow2 fixture disks; no temporary SDK VM is launched')
    prove(parser.parse_args())
