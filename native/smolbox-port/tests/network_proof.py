#!/usr/bin/env python3
"""Opt-in raw Port network/mapping lifecycle; no fault or CLI-race campaign."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import time

from native_proof import Port, config_schema, operation, save, snapshot
from ordinary_proof import stopped_children
from network_fixture import ADDRESSES, RESPONDER_PORT, RESPONSE, positive_controls, require_namespace


def command(port, receipt, argv):
    result, events = port.call(operation('exec', receipt, command={
        'argv': argv, 'env': {}, 'workdir': '/workspace', 'user': None,
        'max_output_bytes': 65536}), budget=10000)
    assert result['result'] == 'command' and result['completion'] == 'exited', result
    assert result['running_observed']
    return result['observed_exit'], b''.join(data for stream, data in events if stream == 'stdout')


def listeners(mapped):
    result = subprocess.check_output(['/usr/bin/ss', '-H', '-lnt', f'sport = :{mapped}'], text=True)
    return sorted(line.split()[3] for line in result.splitlines())


def inbound(mapped, expected, address='127.0.0.1'):
    deadline = time.monotonic() + 5
    while True:
        connection = http.client.HTTPConnection(address, mapped, timeout=1)
        try:
            connection.request('GET', '/native-network.txt')
            response = connection.getresponse()
            assert response.status == 200 and response.read(len(expected) + 1) == expected
            return
        except OSError:
            assert time.monotonic() < deadline, 'mapped application did not become reachable'
            time.sleep(0.05)
        finally:
            connection.close()


def observe(port, receipt, expected, state):
    result, events = port.call(operation('inspect', receipt))
    assert not events and result['result'] == 'observed'
    value = result['observation']
    assert value['state'] == state and value['configuration'] == expected


def traffic(port, receipt, mapped, allowed, contents):
    positive_controls()  # A denied destination must still be independently live.
    reached = []
    for address in ADDRESSES:
        code, output = command(port, receipt, ['python', '-c',
            'import socket,sys\n'
            'try:\n'
            ' with socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2) as peer:\n'
            '  data=bytearray()\n'
            '  while len(data)<256:\n'
            '   part=peer.recv(256-len(data))\n'
            '   if not part: break\n'
            '   data.extend(part)\n'
            '  sys.stdout.buffer.write(data)\n'
            'except OSError: sys.exit(3)\n', address, str(RESPONDER_PORT)])
        connected = code == 0 and output == RESPONSE
        if not connected:
            assert code != 0 and not output, 'a failed positive control is not policy evidence'
        reached.append(connected)
    assert reached == [allowed, False], 'guest traffic differs from its approved policy'
    launched, events = port.call(operation('exec_background', receipt, command={
        'argv': ['python', '-m', 'http.server', '8000', '--bind', '0.0.0.0', '--directory', '/workspace'],
        'env': {}, 'workdir': '/workspace', 'user': None, 'stdin': None, 'max_output_bytes': 65536}))
    assert not events and launched['result'] == 'launched' and launched['pid'] > 0, launched
    inbound(mapped, contents)
    bindings = listeners(mapped)
    assert f'127.0.0.1:{mapped}' in bindings
    assert set(bindings) <= {f'127.0.0.1:{mapped}', f'[::1]:{mapped}'}
    if f'[::1]:{mapped}' in bindings:
        inbound(mapped, contents, '::1')
    return {'outbound_reached': reached, 'host_positive_controls': [True, True],
            'inbound_reply_verified': True, 'listener_addresses': bindings,
            'ordinary_background_launch_acknowledged': True}


def prove(args):
    assert os.geteuid() != 0 and os.getuid() == 1000, 'SDK proof must run as the approved lab account'
    require_namespace(args.namespace_identity)
    assert args.isolated_lab_network, 'explicit ordinary isolated-network selection required'
    assert 1024 <= args.host_port <= 65535
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package, fixture = args.package.resolve(), args.fixture.resolve()
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    assert manifest['identity']['platform'] == 'linux' and manifest['identity']['architecture'] == 'x86_64'
    assert all(manifest['policy']['sdk']['feature_versions'].get(key) == 1 for key in ['networking', 'ports'])
    with fixture.open('rb') as stream:
        assert hashlib.file_digest(stream, 'sha256').hexdigest() == args.sha256
        stream.seek(-64, 2)
        footer = stream.read(64)
        assert footer[:8] == b'SMOLPACK'
        stub, offset, size, where, length = struct.unpack_from('<QQQQQ', footer, 12)
        assert stub == offset == 0 and where == size and 0 < length <= 1048576
        assert where + length + 64 == fixture.stat().st_size
        stream.seek(where)
        source_manifest = json.loads(stream.read(length))
        assert source_manifest.get('mode', 'container') == 'container', \
            'approved Python container fixture required before any SDK owner starts'
    artifact = {'path': str(fixture), 'sha256': args.sha256,
                'max_bytes': fixture.stat().st_size, 'guest_platform': 'linux/amd64'}
    domain = json.loads(args.domain_json.read_bytes())
    config = output / 'config.json'
    save(config, {'schema': config_schema(manifest), **domain, 'allow_initialize': False,
                  'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
                  'approved_artifacts': [artifact]})
    before = snapshot()
    assert before == [], 'isolated empty SDK inventory required; never adopt other machines'
    save(output / 'inventory-before.json', before)
    assert not listeners(args.host_port), 'choose an unused explicit fixture port before SDK dispatch'
    positive_controls()
    port = Port(package, config, output / 'helper.stderr')
    evidence, reaping = [], []
    try:
        for enabled in [False, True]:
            stage = output / ('cidr' if enabled else 'offline')
            stage.mkdir(mode=0o700)
            network = {'enabled': enabled, 'hosts': [],
                       'cidrs': [ADDRESSES[0] + '/32'] if enabled else []}
            ports = [{'host': args.host_port, 'guest': 8000}]
            features = {'network': network, 'ports': ports, 'workload': None}
            expected = {'network': network, 'ports': ports, 'backend': 'virtio-net'}
            create = {'name': 'sb-network-' + secrets.token_hex(8),
                      'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
                      'artifact': artifact, 'resources': {'cpus': 1, 'memory_mib': 512,
                                                         'storage_gib': 1, 'overlay_gib': 1},
                      'labels': {}, 'features': features}
            save(stage / 'intent.json', create)
            result, events = port.call({'operation': 'create', 'create': create})
            save(stage / 'create-result.json', result)
            assert not events and result['result'] == 'created', result
            receipt = result['receipt']
            save(stage / 'receipt.json', receipt)
            observe(port, receipt, expected, 'stopped')
            cycles = []
            contents = ('native-network-' + secrets.token_hex(8)).encode()
            for cycle in range(2):
                started, _ = port.call(operation('start', receipt))
                save(stage / f'start-{cycle}.json', started)
                assert started['result'] == 'observed' and started['observation']['state'] == 'running', started
                observe(port, receipt, expected, 'running')
                code, version = command(port, receipt, ['python', '-c', 'import socket,http.server,sys; print(sys.version)'])
                assert code == 0 and version, 'approved fixture needs Python standard networking modules'
                if cycle == 0:
                    options = {'guest_path': '/workspace/native-network.txt', 'max_bytes': 1024, 'mode': 0o644}
                    written, _ = port.call(operation('write_file', receipt, options=options,
                                                     total_bytes=len(contents)), upload=contents)
                    assert written['result'] == 'file' and written['completion'] == 'completed'
                    assert written['native_acknowledged'] and written['observed_bytes'] == len(contents)
                cycles.append(traffic(port, receipt, args.host_port, enabled, contents))
                stopped, _ = port.call(operation('stop', receipt))
                assert stopped['result'] == 'observed' and stopped['observation']['state'] == 'stopped'
                stopped_children(port, True, reaping)
                assert not listeners(args.host_port), 'normal stop retained mapped listeners'
                observe(port, receipt, expected, 'stopped')
            deleted, _ = port.call(operation('delete', receipt))
            assert deleted['result'] == 'observed' and deleted['observation']['state'] == 'missing'
            assert snapshot() == before and not listeners(args.host_port)
            evidence.append({'network': network, 'ports': ports, 'observed_backend': 'virtio-net',
                             'cycles': cycles, 'owned_deleted': True,
                             'retained_after_stop_start': True})
        port.close()
        assert snapshot() == before
        save(output / 'evidence.json', {'proof': 'passed', 'scope': 'ordinary-raw-port-network-mappings',
             'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
             'identity': manifest['identity'], 'fixture_sha256': args.sha256,
             'cases': evidence, 'normal_stop_child_reaping': reaping,
             'inventory_before': before, 'inventory_after': snapshot(),
             'public_managed_reservations_qualified': False,
             'workload_startup_qualified': False, 'deliberate_process_interruption': False,
             'crash_handling_qualified': False})
        print('Ordinary raw Port network and mappings passed; SDK inventory restored')
    finally:
        # Preserve all intents/receipts on failure. Only normal helper shutdown;
        # no signal, uncertain-operation replay or name-based cleanup.
        if port.process.poll() is None:
            port.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['package', 'fixture', 'domain-json', 'output']:
        parser.add_argument('--' + option, type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--host-port', type=int, required=True)
    parser.add_argument('--namespace-identity', required=True,
                        help='verified isolated namespace supplied by the privileged local fixture')
    parser.add_argument('--isolated-lab-network', action='store_true')
    prove(parser.parse_args())
