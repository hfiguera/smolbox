#!/usr/bin/env python3
"""Explicit small-fixture pack qualification; no VMs are created or booted."""
import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import struct
import subprocess
import tarfile
import zlib

from native_proof import Port, config_schema, save, snapshot


def archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.GNU_FORMAT) as writer:
        for name, data in files:
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            writer.addfile(entry, io.BytesIO(data))
    return output.getvalue()


def disk(gib):
    data = bytearray(4096)
    struct.pack_into('<I', data, 1028, gib * (1 << 30) // 4096)
    struct.pack_into('<I', data, 1048, 2)
    struct.pack_into('<H', data, 1080, 0xef53)
    return bytes(data)


def pack(path, manifest, assets, compressor):
    compressed = subprocess.run([str(compressor), '-q', '-c', '-1'], input=assets,
                                capture_output=True, timeout=10, check=True).stdout
    assert len(compressed) <= 1024 * 1024, 'small-fixture compressor bound'
    metadata = json.dumps(manifest, separators=(',', ':')).encode()
    checksum = zlib.crc32(compressed + metadata)
    footer = struct.pack('<8sIQQQQQI8x', b'SMOLPACK', 1, 0, 0, len(compressed),
                         len(compressed), len(metadata), checksum)
    with path.open('xb') as output:
        os.chmod(path, 0o600)
        output.write(compressed + metadata + footer)
        output.flush()
        os.fsync(output.fileno())


def prove(args):
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    package = args.package.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    identity = json.loads(manifest_bytes)['identity']
    domain = json.loads(args.domain_json.read_bytes())
    platform = 'linux/arm64' if identity['architecture'] == 'aarch64' else 'linux/amd64'
    fixture = args.fixture.resolve()
    with fixture.open('rb') as file:
        assert hashlib.file_digest(file, 'sha256').hexdigest() == args.sha256, 'fixture changed'

    guest = archive([('usr/bin/witness', b'ordinary fixture')])
    digest = hashlib.sha256(guest).hexdigest()
    layer_path = f'layers/{digest}.tar'
    inventory = {
        'libraries': [], 'agent_rootfs': {'path': 'agent-rootfs.tar', 'size': len(guest)},
        'layers': [{'digest': f'sha256:{digest}', 'path': layer_path, 'size': len(guest)}]}
    metadata = {'mode': 'container', 'image': 'proof:offline', 'digest': f'sha256:{digest}',
                'platform': platform, 'host_platform': 'proof', 'created': '2026-10-10T00:00:00Z',
                'smolvm_version': '1.22.0', 'cpus': 1, 'mem': 512, 'image_size': len(guest),
                'network': False, 'gpu': False, 'cuda': False, 'assets': inventory}
    rootfs = ('agent-rootfs.tar', guest)
    layer = (layer_path, guest)
    variants = {
        'missing-layer': (copy.deepcopy(metadata), archive([rootfs])),
        'duplicate-layer': (copy.deepcopy(metadata), archive([rootfs, layer, layer])),
        'undeclared-layer': (copy.deepcopy(metadata), archive([rootfs, layer, ('layers/hidden.tar', guest)])),
        'invalid-layer': (copy.deepcopy(metadata), archive([rootfs, (layer_path, b'?' * len(guest))])),
        'wrong-size': (copy.deepcopy(metadata), archive([rootfs, layer])),
        'hidden-tail': (copy.deepcopy(metadata), archive([rootfs, layer]) + b'hidden payload'),
        'vm-geometry': (copy.deepcopy(metadata), archive([rootfs, layer, ('overlay.raw', disk(2)), ('storage.ext4', disk(1))]))}
    variants['wrong-size'][0]['assets']['layers'][0]['size'] += 1
    vm = variants['vm-geometry'][0]
    vm['mode'] = 'vm'
    vm['assets'].update({'overlay_template': {'path': 'overlay.raw', 'size': 4096},
                         'storage_template': {'path': 'storage.ext4', 'size': 4096},
                         'overlay_logical_size': 1 << 30, 'storage_logical_size': 1 << 30})

    specs = [{'path': str(fixture), 'sha256': args.sha256, 'max_bytes': fixture.stat().st_size,
              'guest_platform': platform}]
    valid_synthetic = output / 'valid-control.smolmachine'
    pack(valid_synthetic, metadata, archive([rootfs, layer]), args.zstd.resolve())
    control = {'path': str(valid_synthetic), 'sha256': hashlib.sha256(valid_synthetic.read_bytes()).hexdigest(),
               'max_bytes': valid_synthetic.stat().st_size, 'guest_platform': platform}
    valid_vm = output / 'valid-vm-control.smolmachine'
    pack(valid_vm, vm, archive([rootfs, layer, ('overlay.raw', disk(1)), ('storage.ext4', disk(1))]), args.zstd.resolve())
    vm_control = {'path': str(valid_vm), 'sha256': hashlib.sha256(valid_vm.read_bytes()).hexdigest(),
                  'max_bytes': valid_vm.stat().st_size, 'guest_platform': platform}
    for name, (description, data) in variants.items():
        path = output / f'{name}.smolmachine'
        pack(path, description, data, args.zstd.resolve())
        specs.append({'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                      'max_bytes': path.stat().st_size, 'guest_platform': platform})
    config = {'schema': config_schema(json.loads(manifest_bytes)), 'target_id': domain['target_id'], 'generation': domain['generation'],
              'allow_initialize': False, 'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
              'approved_artifacts': [*specs, control, vm_control]}
    save(output / 'config.json', config)
    before = snapshot()
    assert before == [], 'proof requires an empty dedicated native domain'
    save(output / 'inventory-before.json', before)
    resources = {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1}
    port = Port(package, output / 'config.json', output / 'helper.stderr')
    try:
        result, events = port.call({'operation': 'qualify_creation', 'artifact': specs[0],
                                    'resources': resources, 'user': '65534:65534'})
        assert result == {'result': 'qualified'} and events == [], 'real pack failed qualification'
        result, events = port.call({'operation': 'qualify_creation', 'artifact': control,
                                    'resources': resources, 'user': None})
        assert result == {'result': 'qualified'} and events == [], 'synthetic manifest/control invalid'
        result, events = port.call({'operation': 'qualify_creation', 'artifact': vm_control,
                                    'resources': resources, 'user': None})
        assert result == {'result': 'qualified'} and events == [], 'synthetic VM manifest/control invalid'
        results = []
        for name, spec in zip(variants, specs[1:]):
            result, events = port.call({'operation': 'qualify_creation', 'artifact': spec,
                                        'resources': resources, 'user': None})
            assert result['result'] == 'error' and result['code'] == 'validation', name
            assert result['dispatch'] == 'not_dispatched' and events == [], name
            # Direct create repeats validation before its SDK create reservation.
            create = {'name': 'sb-' + secrets.token_hex(6), 'owner_token': secrets.token_hex(32),
                      'incarnation': secrets.token_hex(16), 'artifact': spec,
                      'resources': resources, 'labels': {}}
            save(output / f'{name}-intent.json', create)
            result, events = port.call({'operation': 'create', 'create': create})
            assert result['result'] == 'error' and result['code'] == 'validation', name
            assert result['dispatch'] == 'not_dispatched' and events == [], name
            assert snapshot() == before, 'invalid pack changed native inventory'
            results.append(name)
        port.close(eof=True)
    except BaseException:
        if port.process.poll() is None:
            port.process.kill()
            port.process.wait(timeout=10)
        port.errors.close()
        raise
    assert snapshot() == before, 'qualification shutdown changed native inventory'
    result = {'proof': 'passed', 'scope': 'qualification-only-no-vm',
              'manifest_sha256': config['package_manifest_sha256'], 'real_pack_qualified': True,
              'synthetic_manifest_controls_qualified': True,
              'rejected_before_native_create': results, 'inventory_unchanged': True}
    save(output / 'result.json', result)
    print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['package', 'fixture', 'domain-json', 'output', 'zstd']:
        parser.add_argument('--' + option, required=True, type=Path)
    parser.add_argument('--sha256', required=True)
    prove(parser.parse_args())
