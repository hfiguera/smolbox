#!/usr/bin/env python3
"""Bounded record interference in the disposable Linux lab; no process signals."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3

from native_proof import Port, creation_presence, observed, operation, save, snapshot


def prove(args):
    assert os.uname().sysname == 'Linux' and os.uname().nodename == 'smolbox-nested'
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package, fixture = args.package.resolve(), args.fixture.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    with fixture.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == args.sha256
    artifact = {'path': str(fixture), 'sha256': args.sha256,
                'max_bytes': fixture.stat().st_size, 'guest_platform': 'linux/amd64'}
    domain = json.loads(args.domain_json.read_text())
    save(output / 'config.json', {'schema': 1, **domain, 'allow_initialize': False,
        'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
        'approved_artifacts': [artifact]})
    before = snapshot()
    assert before == [], 'lab proof requires its empty baseline'
    save(output / 'inventory-before.json', before)
    create = {'name': 'sb-interference-' + secrets.token_hex(8),
              'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact,
              'resources': {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1},
              'labels': {'proof': 'record-interference'}}
    save(output / 'intent.json', create)
    port = Port(package, output / 'config.json', output / 'helper.stderr')
    receipt = None
    database = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'smolvm/server/smolvm.db'

    def rejected(op, code):
        result, events = port.call(op)
        assert result['result'] == 'error' and result['code'] == code and not events, result
        return result

    try:
        result, _ = port.call({'operation': 'create', 'create': create})
        assert result['result'] == 'created'
        receipt = result['receipt']
        save(output / 'receipt.json', receipt)
        observed(port, 'inspect', receipt, 'stopped')
        with sqlite3.connect(database, timeout=10) as connection:
            original, = connection.execute('SELECT data FROM vms WHERE name=?', (receipt['name'],)).fetchone()
            record = json.loads(original)
            record['cpus'] = 2
            changed = json.dumps(record).encode()
            try:
                connection.execute('UPDATE vms SET data=? WHERE name=?', (changed, receipt['name']))
                connection.commit()
                changed_inspect = rejected(operation('inspect', receipt), 'ownership')
                changed_delete = rejected(operation('delete', receipt), 'ownership')
                creation_presence(port, create, 'unverified')
                assert connection.execute('SELECT data FROM vms WHERE name=?', (receipt['name'],)).fetchone()[0] == changed
            finally:
                connection.execute('UPDATE vms SET data=? WHERE name=?', (original, receipt['name']))
                connection.commit()
            observed(port, 'inspect', receipt, 'stopped')
            try:
                connection.execute('UPDATE vms SET data=? WHERE name=?', (b'{', receipt['name']))
                connection.commit()
                corrupt_inspect = rejected(operation('inspect', receipt), 'database')
                corrupt_query, events = port.call({'operation': 'inspect_creation', 'create': create})
                # Presence alone cannot authorize adoption; a present corrupt row
                # may still be conservatively reported as unverified.
                assert corrupt_query == {'result': 'creation_presence', 'presence': 'unverified'} and not events
                corrupt_delete = rejected(operation('delete', receipt), 'database')
            finally:
                connection.execute('UPDATE vms SET data=? WHERE name=?', (original, receipt['name']))
                connection.commit()
            connection.execute('BEGIN IMMEDIATE')
            try:
                busy_query = rejected({'operation': 'inspect_creation', 'create': create}, 'database')
            finally:
                connection.rollback()
        observed(port, 'inspect', receipt, 'stopped')
        observed(port, 'delete', receipt, 'missing')
        old = receipt
        create = {**create, 'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16)}
        save(output / 'replacement-intent.json', create)
        result, _ = port.call({'operation': 'create', 'create': create})
        assert result['result'] == 'created'
        receipt = result['receipt']
        save(output / 'replacement-receipt.json', receipt)
        rejected(operation('inspect', old), 'ownership')
        rejected(operation('delete', old), 'ownership')
        observed(port, 'inspect', receipt, 'stopped')
        observed(port, 'delete', receipt, 'missing')
        port.close()
        after = snapshot()
        assert after == before
        save(output / 'evidence.json', {'proof': 'passed', 'scope': 'linux-native-record-interference',
            'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(), 'identity': manifest['identity'],
            'fixture_sha256': args.sha256, 'changed_inspect': changed_inspect, 'changed_delete': changed_delete,
            'corrupt_inspect': corrupt_inspect, 'corrupt_query': corrupt_query, 'corrupt_delete': corrupt_delete,
            'busy_query': busy_query, 'copied_labels_did_not_authorize': True,
            'same_name_recreation_rejects_original_receipt': True, 'owned_deleted': True,
            'inventory_before': before, 'inventory_after': after, 'deliberate_process_interruption': False,
            'independent_cli_races_qualified': False})
        print('record-interference proof passed; empty inventory restored')
    finally:
        if port.process.poll() is None:
            # Row restoration precedes this path; delete only the saved full receipt.
            if receipt is not None:
                try:
                    observed(port, 'inspect', receipt, 'stopped')
                    observed(port, 'delete', receipt, 'missing')
                    save(output / 'failure-cleanup.json', {'owned_deleted': True})
                except Exception:
                    pass
            port.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['package', 'fixture', 'domain-json', 'output']:
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    prove(parser.parse_args())
