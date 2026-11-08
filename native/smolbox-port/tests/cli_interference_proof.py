#!/usr/bin/env python3
"""Finite independent CLI resource change against our stopped Linux lab fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import subprocess

from native_proof import Port, observed, operation, save, snapshot


def prove(args):
    assert os.uname().sysname == 'Linux' and os.uname().nodename == 'smolbox-nested'
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package, fixture, cli = args.package.resolve(), args.fixture.resolve(), args.cli.resolve()
    before = snapshot()
    assert before == []
    with fixture.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == args.sha256
    artifact = {'path': str(fixture), 'sha256': args.sha256,
                'max_bytes': fixture.stat().st_size, 'guest_platform': 'linux/amd64'}
    domain = json.loads(args.domain_json.read_text())
    manifest = (package / 'package.json').read_bytes()
    save(output / 'config.json', {'schema': 1, **domain, 'allow_initialize': False,
        'package_manifest_sha256': hashlib.sha256(manifest).hexdigest(),
        'approved_artifacts': [artifact]})
    create = {'name': 'sb-cli-proof-' + secrets.token_hex(8),
              'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact,
              'resources': {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1},
              'labels': {'proof': 'finite-cli-interference'}}
    save(output / 'intent.json', create)
    port = Port(package, output / 'config.json', output / 'helper.stderr')
    database = Path.home() / '.local/share/smolvm/server/smolvm.db'

    def row(receipt):
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as connection:
            value, = connection.execute('SELECT data FROM vms WHERE name=?', (receipt['name'],)).fetchone()
            return value

    def update(receipt, cpus):
        return subprocess.run([str(cli), 'machine', 'update', '--name', receipt['name'],
                               '--cpus', str(cpus)], stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=30)

    receipt = None
    changed = False
    process = None
    try:
        result, _ = port.call({'operation': 'create', 'create': create})
        assert result['result'] == 'created'
        receipt = result['receipt']
        save(output / 'receipt.json', receipt)
        observed(port, 'inspect', receipt, 'stopped')
        original = json.loads(row(receipt))
        # This independent unpatched CLI is a separate process; no test writes
        # the database. While it runs, native inspection may see either version.
        with (output / 'cli-update.log').open('xb') as log:
            process = subprocess.Popen([str(cli), 'machine', 'update', '--name',
                receipt['name'], '--cpus', '2'], stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT)
            changed = True
            outcome, events = port.call(operation('inspect', receipt))
            assert process.wait(timeout=30) == 0
            assert not events
            assert (outcome.get('result') == 'observed' and
                    outcome.get('observation', {}).get('state') == 'stopped') or (
                    outcome == {'result': 'error', 'code': 'ownership',
                                'dispatch': 'not_dispatched'}), outcome
        modified = row(receipt)
        material = json.loads(modified)
        assert material['cpus'] == 2 and material['labels'] == original['labels']
        for name in ['inspect', 'delete']:
            result, events = port.call(operation(name, receipt))
            assert result == {'result': 'error', 'code': 'ownership', 'dispatch': 'not_dispatched'} and not events
        assert row(receipt) == modified
        restored = update(receipt, 1)
        assert restored.returncode == 0
        changed = False
        observed(port, 'inspect', receipt, 'stopped')
        observed(port, 'delete', receipt, 'missing')
        receipt = None
        assert snapshot() == before
        with cli.open('rb') as stream:
            cli_sha = hashlib.file_digest(stream, 'sha256').hexdigest()
        save(output / 'evidence.json', {'proof': 'passed', 'scope': 'finite-independent-cli-interference',
             'package_manifest_sha256': hashlib.sha256(manifest).hexdigest(),
             'identity': json.loads(manifest)['identity'], 'cli_sha256': cli_sha,
             'cli_version': '1.22.0', 'copied_labels_did_not_authorize': True,
             'native_delete_preserved_changed_record': True, 'owned_deleted': True,
             'inventory_before': before, 'inventory_after': snapshot(),
             'destructive_concurrent_cli_races_qualified': False,
             'deliberate_process_interruption': False})
    finally:
        try:
            if process is not None and process.poll() is None:
                raise RuntimeError('CLI outcome unresolved; retain authentic evidence for lab recovery')
            if receipt is not None:
                if changed:
                    assert update(receipt, 1).returncode == 0
                observed(port, 'inspect', receipt, 'stopped')
                observed(port, 'delete', receipt, 'missing')
        finally:
            port.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['package', 'fixture', 'domain-json', 'cli', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    prove(parser.parse_args())
