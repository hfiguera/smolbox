#!/usr/bin/env python3
"""Opt-in 1.35.1 padded telemetry proof in an already enrolled empty domain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import time

from native_proof import Port, operation, save, snapshot


def prove(args):
    assert args.ordinary, 'explicit ordinary qualification required'
    package, fixture = args.package.resolve(), args.fixture.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    assert manifest['policy']['sdk']['sdk_version'] == '1.35.1'
    with fixture.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == args.sha256
    domain = json.loads(args.domain_json.read_bytes())
    before = snapshot()
    assert before == [], 'a dedicated empty SDK domain is required'
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    artifact = {'path': str(fixture), 'sha256': args.sha256,
                'max_bytes': fixture.stat().st_size,
                'guest_platform': 'linux/arm64' if manifest['identity']['architecture'] == 'aarch64' else 'linux/amd64'}
    config = output / 'config.json'
    save(config, {'schema': 2, **domain, 'allow_initialize': False,
                  'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
                  'approved_artifacts': [artifact]})
    create = {'name': 'sb-telemetry-' + secrets.token_hex(8),
              'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact, 'resources': {'cpus': 1, 'memory_mib': 512,
                                                 'storage_gib': 1, 'overlay_gib': 1},
              'labels': {}, 'features': {'network': {'enabled': True, 'hosts': [],
                                                    'cidrs': ['127.0.0.1/32']},
                                        'ports': [], 'workload': None}}
    save(output / 'intent.json', create)
    port = Port(package, config, output / 'helper.stderr')
    try:
        result, events = port.call({'operation': 'create', 'create': create})
        assert not events and result['result'] == 'created', result
        receipt = result['receipt']
        save(output / 'receipt.json', receipt)
        started, _ = port.call(operation('start', receipt))
        assert started['result'] == 'observed' and started['observation']['state'] == 'running', started
        cache = (Path.home() / 'Library/Caches' if os.uname().sysname == 'Darwin'
                 else Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')))
        directory = cache / 'smolvm/vms' / hashlib.sha256(create['name'].encode()).hexdigest()[:16]
        sample = directory / 'egress'
        deadline = time.monotonic() + 15
        while not sample.exists():
            assert time.monotonic() < deadline, 'engine did not publish a telemetry sample'
            time.sleep(0.05)
        assert not sample.is_symlink() and sample.stat().st_size == 1024
        assert (directory / 'name').read_text().strip() == create['name']
        measured, events = port.call(operation('measurements', receipt))
        assert not events and measured['result'] == 'measurements', measured
        assert measured['observation']['state'] == 'running'
        assert isinstance(measured['counters']['egress_bytes'], int)
        stopped, _ = port.call(operation('stop', receipt))
        assert stopped['result'] == 'observed' and stopped['observation']['state'] == 'stopped', stopped
        final, _ = port.call(operation('measurements', receipt))
        assert final['result'] == 'measurements' and isinstance(final['counters']['egress_bytes'], int), final
        deleted, _ = port.call(operation('delete', receipt))
        assert deleted['result'] == 'observed' and deleted['observation']['state'] == 'missing', deleted
        assert snapshot() == before
        save(output / 'evidence.json', {'proof': 'passed', 'sdk': manifest['policy']['sdk'],
             'package_identity': manifest['identity'],
             'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
             'sample_bytes': 1024, 'running_counters': measured['counters'],
             'stopped_counters': final['counters'], 'inventory_empty': True,
             'deliberate_process_interruption': False})
    finally:
        port.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['package', 'fixture', 'domain-json', 'output']:
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--ordinary', action='store_true')
    prove(parser.parse_args())
