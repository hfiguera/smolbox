#!/usr/bin/env python3
"""Explicit helper-loss qualification, confined to the disposable Linux lab."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import time

from native_proof import Port, observed, operation, save, snapshot


def process_identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        return {'parent': int(fields[1]), 'start': int(fields[19]), 'state': fields[0]}
    except FileNotFoundError:
        return None


def wait_vmm_exit(pid, start):
    deadline = time.monotonic() + 20
    while True:
        current = process_identity(pid)
        if current is None or current['start'] != start:
            return
        assert time.monotonic() < deadline, 'owned VMM remained after helper loss'
        time.sleep(0.05)


def command(script):
    return {'argv': ['/bin/sh', '-c', script], 'env': {}, 'workdir': '/workspace',
            'user': '0:0', 'max_output_bytes': 4096}


def pending_exec(port, receipt, output, boundary):
    script = ('set -e; n=$(cat /workspace/fault-count 2>/dev/null || printf 0); '
              'printf "%s" "$((n+1))" > /workspace/fault-count; '
              'sync; printf fault-running; sleep 30; exit 7')
    request_id = port.next_id + 1
    request = {'type': 'request', 'epoch': port.hello['epoch'], 'id': request_id,
               'budget_ms': 60000, 'initial_credit': 262144, 'initial_event_credit': 64,
               'operation': operation('exec', receipt, command=command(script))}
    save(output / 'exec-intent.json', request)
    if boundary == 'before-send':
        return {'sent': False, 'accepted': False, 'running_event': False}
    port.next_id = request_id
    port.send(request)
    acceptance = port.receive()
    assert acceptance['type'] == 'accepted' and acceptance['sequence'] == 0
    assert acceptance['epoch'] == request['epoch'] and acceptance['id'] == request_id
    if boundary == 'running':
        witness, sequence = b'', 1
        while witness != b'fault-running':
            event = port.receive()
            assert event['type'] == 'event' and event['sequence'] == sequence
            sequence += 1
            assert event['epoch'] == request['epoch'] and event['id'] == request_id
            assert event['event']['stream'] == 'stdout'
            witness += base64.b64decode(event['event']['data_base64'], validate=True)
            assert b'fault-running'.startswith(witness), 'unexpected running witness'
    return {'sent': True, 'accepted': True, 'running_event': boundary == 'running'}


def run_case(package, config, artifact, output, boundary):
    output.mkdir(mode=0o700)
    before = snapshot()
    assert before == [], 'each case requires the empty dedicated domain'
    create = {'name': 'sb-fault-' + secrets.token_hex(8),
              'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact,
              'resources': {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1},
              'labels': {'proof': boundary}}
    save(output / 'create-intent.json', create)
    port = Port(package, config, output / 'initial.stderr')
    receipt = None
    try:
        created, events = port.call({'operation': 'create', 'create': create})
        assert created['result'] == 'created' and events == []
        receipt = created['receipt']
        save(output / 'receipt.json', receipt)
        running = observed(port, 'start', receipt, 'running')['observation']
        pid, start = running['pid_identity']
        current = process_identity(pid)
        assert current is not None and current['start'] == start
        assert current['parent'] == port.process.pid and current['state'] != 'Z'
        old_epoch = port.hello['epoch']
        evidence = {'sent': False, 'accepted': False, 'running_event': False}
        if boundary != 'idle':
            evidence = pending_exec(port, receipt, output, boundary)
        save(output / 'kill-checkpoint.json', dict(evidence, helper_pid=port.process.pid,
                                                  vmm_pid=pid, vmm_start=start))
        # Popen is the live child this invocation owns. Never signal an
        # inventory-selected VMM or infer completion from acceptance.
        port.process.send_signal(signal.SIGKILL)
        assert port.process.wait(timeout=10) == -signal.SIGKILL
        port.process.stdin.close()
        port.process.stdout.close()
        port.errors.close()
        wait_vmm_exit(pid, start)
        port = Port(package, config, output / 'replacement.stderr')
        assert port.hello['epoch'] != old_epoch
        observed(port, 'inspect', receipt, 'stopped')
        assert len(snapshot()) == 1, 'owner loss removed retained record'
        observed(port, 'start', receipt, 'running')
        result, events = port.call(operation('exec', receipt, command=command(
            'cat /workspace/fault-count 2>/dev/null || printf 0')))
        assert result['completion'] == 'exited' and result['observed_exit'] == 0
        counter = b''.join(data for stream, data in events if stream == 'stdout')
        assert counter in [b'0', b'1'], 'uncertain command ran more than once'
        save(output / 'counter.json', {'observed_counter': int(counter)})
        if boundary in ['idle', 'before-send']:
            assert counter == b'0'
        if boundary == 'running':
            assert counter == b'1'
        observed(port, 'stop', receipt, 'stopped')
        observed(port, 'delete', receipt, 'missing')
        port.close()
        assert snapshot() == before
        result = dict(evidence, boundary=boundary, proof='passed', helper_exit_signal=9,
                      vmm_exit_observed=True, retained_record_preserved=True,
                      counter=int(counter), owned_deleted=True, inventory_unchanged=True,
                      durable_store_qualified=False)
        save(output / 'result.json', result)
        return result
    except BaseException:
        # Keep the authentic intent/receipt for explicit fixture maintenance.
        # EOF stops tracked VMMs and preserves uncertain storage.
        if port.process.poll() is None:
            port.close(eof=True)
        raise


def prove(args):
    assert os.uname().sysname == 'Linux' and socket.gethostname() == 'smolbox-nested'
    assert os.geteuid() != 0, 'use the dedicated disposable guest account'
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package, fixture = args.package.resolve(), args.fixture.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    assert manifest['identity']['platform'] == 'linux'
    assert manifest['identity']['architecture'] == 'x86_64'
    with fixture.open('rb') as file:
        assert hashlib.file_digest(file, 'sha256').hexdigest() == args.sha256
    artifact = {'path': str(fixture), 'sha256': args.sha256,
                'max_bytes': fixture.stat().st_size, 'guest_platform': 'linux/amd64'}
    domain = json.loads(args.domain_json.read_text())
    config = {'schema': 1, **domain, 'allow_initialize': False,
              'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
              'approved_artifacts': [artifact]}
    save(output / 'config.json', config)
    results = [run_case(package, output / 'config.json', artifact, output / boundary, boundary)
               for boundary in ['idle', 'before-send', 'accepted', 'running']]
    save(output / 'result.json', {'proof': 'passed', 'scope': 'linux-native-helper-loss',
                                 'package_manifest_sha256': config['package_manifest_sha256'],
                                 'fixture_sha256': args.sha256, 'cases': results,
                                 'whole_fault_matrix_qualified': False})
    print(json.dumps({'proof': 'passed', 'cases': len(results)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--domain-json', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    prove(parser.parse_args())
