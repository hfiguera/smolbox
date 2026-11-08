#!/usr/bin/env python3
"""Explicit ordinary native Port qualification; never run by cargo test."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
import sqlite3
import struct
import subprocess
import tempfile
import time

MAX_FRAME = 1024 * 1024
MAX_CHUNK = 65536


def save(path, value):
    # Before-dispatch intent is immutable and cannot be reused as a replay.
    path = Path(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        os.fchmod(temporary.fileno(), 0o600)
        temporary.write(json.dumps(value, indent=2).encode())
        temporary.flush()
        os.fsync(temporary.fileno())
        name = Path(temporary.name)
    try:
        os.link(name, path)
    finally:
        name.unlink()
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def snapshot():
    database = Path.home() / 'Library/Application Support/smolvm/server/smolvm.db' if os.uname().sysname == 'Darwin' else Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'smolvm/server/smolvm.db'
    with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as connection:
        rows = connection.execute('SELECT * FROM vms ORDER BY name').fetchall()
    return [hashlib.sha256(repr(row).encode()).hexdigest() for row in rows]


class Port:
    def __init__(self, package, config, error_path):
        self.error_path = Path(error_path)
        self.errors = Path(error_path).open('xb')
        environment = os.environ.copy()
        # The package's executable-relative rpath resolves its own libraries.
        for key in ['DYLD_LIBRARY_PATH', 'DYLD_INSERT_LIBRARIES', 'DYLD_FALLBACK_LIBRARY_PATH',
                    'DYLD_FRAMEWORK_PATH', 'DYLD_FALLBACK_FRAMEWORK_PATH',
                    'LD_LIBRARY_PATH', 'LD_PRELOAD', 'SMOLVM_LIB_DIR', 'SMOLVM_AGENT_ROOTFS',
                    'SMOLVM_AGENT_ROOTFS_TAR', 'SMOLVM_TEMPLATE_DIR', 'SMOLVM_BOOT_BINARY', 'SMOLVM_DATA_DIR']:
            environment.pop(key, None)
        self.process = subprocess.Popen([str(package / 'smolbox-port'), '--config', str(config)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, env=environment)
        self.next_id = 0
        try:
            frame = self.receive(60)
            assert frame['type'] == 'hello' and frame['hello']['preflight']['status'] == 'ready', 'package not ready'
            self.hello = frame['hello']
            expected_config = json.loads(Path(config).read_bytes())
            expected_manifest = json.loads((package / 'package.json').read_bytes())
            minor = expected_manifest.get('policy', {}).get('port_protocol_minor', 3)
            assert (self.hello['major'], self.hello['minor']) == (1, minor), 'incompatible protocol'
            assert self.hello['domain'] == {'target_id': expected_config['target_id'], 'generation': expected_config['generation']}, 'wrong domain'
            assert self.hello['package'] == expected_manifest['identity'], 'wrong package tuple'
            assert self.hello['capabilities'] == ['create', 'inspect', 'start', 'stop', 'delete', 'exec', 'read_file', 'write_file', 'qualify_creation', 'inspect_creation'], 'wrong capabilities'
            expected_limits = {
                'frame_bytes': 1048576, 'chunk_bytes': 65536, 'in_flight': 32, 'events_per_request': 65536,
                'work_workers': 4, 'control_workers': 2, 'input_queue_encoded_bytes': 4194304, 'upload_spool_bytes': 134217728,
                'credit_grace_ms': 1000, 'writer_grace_ms': 5000, 'initial_credit_bytes': 262144, 'initial_credit_events': 64,
                'event_queue_decoded_bytes': 8388608, 'event_queue_encoded_bytes': 12582912,
                'transfer_bytes': 16777216, 'command_ms': 86400000, 'file_ms': 600000,
                'cpus_min': 1, 'cpus_max': 16, 'memory_mib_min': 64, 'memory_mib_max': 65536, 'disk_gib_min': 1, 'disk_gib_max': 1024,
            }
            if minor == 4:
                expected_limits['cancel_grace_ms'] = 3000
            assert self.hello['limits'] == expected_limits, 'unexpected effective limits'
            self.send({'type': 'approve', 'hello': self.hello})
        except BaseException:
            self.graceful_exit()
            raise

    def exact(self, size, timeout):
        deadline = time.monotonic() + timeout
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], 'frame deadline'
            chunk = os.read(self.process.stdout.fileno(), size - len(data))
            assert chunk, 'helper EOF before frame completion'
            data.extend(chunk)
        return bytes(data)

    def receive(self, timeout=30):
        size = struct.unpack('>I', self.exact(4, timeout))[0]
        assert 0 < size <= MAX_FRAME, 'bad helper length'
        return json.loads(self.exact(size, timeout))

    def send(self, message):
        body = json.dumps(message, separators=(',', ':')).encode()
        assert 0 < len(body) <= MAX_FRAME
        self.process.stdin.write(struct.pack('>I', len(body)) + body)
        self.process.stdin.flush()

    def call(self, operation, budget=30000, upload=None):
        self.next_id += 1
        request_id = self.next_id
        epoch = self.hello['epoch']
        self.send({'type': 'request', 'epoch': epoch, 'id': request_id, 'budget_ms': budget, 'initial_credit': 262144, 'initial_event_credit': 64, 'operation': operation})
        accepted = self.receive()
        assert accepted['epoch'] == epoch and accepted['id'] == request_id and accepted['sequence'] == 0, 'wrong acceptance'
        if accepted['type'] == 'terminal':
            return accepted['outcome'], []
        assert accepted['type'] == 'accepted'
        if upload is not None:
            for offset in range(0, len(upload), MAX_CHUNK):
                chunk = upload[offset:offset + MAX_CHUNK]
                self.send({'type': 'upload', 'epoch': epoch, 'id': request_id, 'offset': offset, 'data_base64': base64.b64encode(chunk).decode()})
        events, sequence = [], 1
        while True:
            frame = self.receive()
            assert frame['epoch'] == epoch and frame['id'] == request_id and frame['sequence'] == sequence, 'bad correlation or sequence'
            sequence += 1
            if frame['type'] == 'terminal':
                return frame['outcome'], events
            assert frame['type'] == 'event'
            data = base64.b64decode(frame['event']['data_base64'], validate=True)
            assert 0 < len(data) <= MAX_CHUNK
            events.append((frame['event']['stream'], data))
            self.send({'type': 'credit', 'epoch': epoch, 'id': request_id, 'decoded_bytes': len(data), 'events': 1})

    def close(self, eof=False):
        try:
            if not eof:
                self.send({'type': 'shutdown', 'epoch': self.hello['epoch']})
        finally:
            status = self.graceful_exit()
        assert status == 0, 'helper failed shutdown'

    def graceful_exit(self):
        # Ordinary runner failure never authorizes forced owner loss. Preserve
        # intent/receipt/epoch evidence if EOF cannot finish within the budget.
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            status = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            path = self.error_path.with_name(self.error_path.name + '.retained.json')
            if not path.exists():
                save(path, {'scope': 'ordinary-runner-shutdown-unresolved',
                            'helper_pid_for_diagnostics_only': self.process.pid,
                            'deletion_authority': False, 'forced_termination': False,
                            'crash_handling_qualified': False})
            raise RuntimeError('helper graceful exit unresolved; preserve authority and process evidence') from None
        self.errors.close()
        return status


def operation(name, receipt, **fields):
    return {'operation': name, 'receipt': receipt, **fields}


def observed(port, name, receipt, state):
    outcome, _ = port.call(operation(name, receipt))
    assert outcome['result'] == 'observed' and outcome['observation']['state'] == state, 'unexpected lifecycle observation'
    return outcome


def creation_presence(port, create, expected):
    outcome, events = port.call({'operation': 'inspect_creation', 'create': create})
    assert outcome == {'result': 'creation_presence', 'presence': expected}, 'unexpected creation presence'
    assert events == [], 'creation query returned streams'


def memory_calibration(port, create, output, initial_kib):
    request = json.loads(json.dumps(create))
    request.update(name='smolbox-ram-proof-' + secrets.token_hex(8),
                   owner_token=secrets.token_hex(32), incarnation=secrets.token_hex(16))
    request['resources']['memory_mib'] = 768
    save(output / 'memory-intent.json', request)
    receipt = None
    try:
        created, events = port.call({'operation': 'create', 'create': request})
        assert created['result'] == 'created' and not events
        receipt = created['receipt']
        save(output / 'memory-receipt.json', receipt)
        observed(port, 'start', receipt, 'running')
        command = {'argv': ['/bin/sh', '-c', "awk '/MemTotal/ {print $2}' /proc/meminfo"],
                   'env': {}, 'workdir': '/workspace', 'user': '0:0', 'max_output_bytes': 4096}
        result, events = port.call(operation('exec', receipt, command=command))
        assert result['completion'] == 'exited' and result['observed_exit'] == 0
        kib = int(b''.join(data for stream, data in events if stream == 'stdout'))
        witness = {'initial_request_mib': 512, 'initial_kernel_kib': initial_kib,
                   'second_request_mib': 768, 'second_kernel_kib': kib,
                   'kernel_delta_kib': kib - initial_kib}
        save(output / 'memory-calibration.json', witness)
        # MemTotal is usable RAM, excluding reserved/kernel memory. Check the
        # requested increase within 8 MiB rather than assuming identical overhead.
        assert abs(kib - initial_kib - 256 * 1024) <= 8192, 'guest RAM did not follow allocation'
        return witness
    finally:
        if receipt is not None:
            state, _ = port.call(operation('inspect', receipt))
            assert state['result'] == 'observed'
            if state['observation']['state'] == 'running':
                observed(port, 'stop', receipt, 'stopped')
            observed(port, 'delete', receipt, 'missing')


def prove(args):
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    package = args.package.resolve()
    artifact = args.fixture.resolve()
    with artifact.open('rb') as file:
        assert hashlib.file_digest(file, 'sha256').hexdigest() == args.sha256, 'fixture identity changed'
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    domain = json.loads(args.domain_json.read_text())
    artifact_spec = {'path': str(artifact), 'sha256': args.sha256, 'max_bytes': artifact.stat().st_size,
                     'guest_platform': 'linux/arm64' if manifest['identity']['architecture'] == 'aarch64' else 'linux/amd64'}
    config = {'schema': 1, 'target_id': domain['target_id'], 'generation': domain['generation'], 'allow_initialize': False,
              'package_manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(), 'approved_artifacts': [artifact_spec]}
    save(output / 'config.json', config)
    before = snapshot()
    save(output / 'inventory-before.json', before)
    create = {'name': 'smolbox-port-proof-' + secrets.token_hex(8), 'owner_token': secrets.token_hex(32), 'incarnation': secrets.token_hex(16),
              'artifact': artifact_spec, 'resources': {'cpus': 1, 'memory_mib': 512, 'storage_gib': 1, 'overlay_gib': 1}, 'labels': {'proof': 'owned-port'}}
    save(output / 'intent.json', {'domain': domain, 'create': create})
    port = Port(package, output / 'config.json', output / 'first.stderr')
    receipt = None
    try:
        creation_presence(port, create, 'absent')
        assert snapshot() == before, 'absence query changed SDK inventory'
        rejected = json.loads(json.dumps(create))
        rejected['artifact']['sha256'] = '0' * 64
        rejection, events = port.call({'operation': 'inspect_creation', 'create': rejected})
        assert rejection == {'result': 'error', 'code': 'unsupported', 'dispatch': 'not_dispatched'} and not events, 'unapproved query reached engine'
        created, _ = port.call({'operation': 'create', 'create': create})
        assert created['result'] == 'created', 'create did not return authority'
        receipt = created['receipt']
        save(output / 'receipt.json', receipt)
        creation_presence(port, create, 'unverified')
        observed(port, 'inspect', receipt, 'stopped')
        observed(port, 'start', receipt, 'running')
        command = {'argv': ['/bin/sh', '-c', 'printf "cpu=%s mem_kib=%s storage_sectors=%s overlay_sectors=%s env=%s cwd=%s user=%s\\n" "$(nproc)" "$(awk \'/MemTotal/ {print $2}\' /proc/meminfo)" "$(cat /sys/block/vda/size)" "$(cat /sys/block/vdb/size)" "$SMOLBOX_PROOF" "$PWD" "$(id -u)"; printf stderr-witness >&2'],
                   'env': {'SMOLBOX_PROOF': 'set'}, 'workdir': '/workspace', 'user': '0:0', 'max_output_bytes': 65536}
        result, events = port.call(operation('exec', receipt, command=command))
        assert result['result'] == 'command' and result['completion'] == 'exited' and result['observed_exit'] == 0 and result['running_observed'], 'missing real exit'
        stdout = b''.join(data for stream, data in events if stream == 'stdout').decode().strip()
        stderr = b''.join(data for stream, data in events if stream == 'stderr')
        save(output / 'resource-witness.json', {'stdout': stdout,
                                               'stderr': stderr.decode(),
                                               'observed_exit': result['observed_exit']})
        fields = dict(part.split('=', 1) for part in stdout.split())
        # The qualified Linux kernel reports slightly more than nominal RAM.
        # Keep a narrow 2 MiB allowance and independently verify allocation scaling.
        memory_allowance = 2048 if manifest['identity']['platform'] == 'linux' else 0
        assert fields['cpu'] == '1' and 400000 <= int(fields['mem_kib']) <= 524288 + memory_allowance
        assert fields['storage_sectors'] == fields['overlay_sectors'] == '2097152'
        assert fields['env'] == 'set' and fields['cwd'] == '/workspace' and fields['user'] == '0' and stderr == b'stderr-witness'
        uid = {'argv': ['/usr/bin/id', '-u'], 'env': {}, 'workdir': '/workspace', 'user': '65534:65534', 'max_output_bytes': 4096}
        result, events = port.call(operation('exec', receipt, command=uid))
        assert result['observed_exit'] == 0 and b''.join(data for _, data in events).strip() == b'65534'
        data = b'Z' * 1048593
        options = {'guest_path': '/workspace/port-retained.bin', 'max_bytes': 2 * 1024 * 1024, 'mode': 0o600}
        result, _ = port.call(operation('write_file', receipt, options=options, total_bytes=len(data)), upload=data)
        assert result['completion'] == 'completed' and result['native_acknowledged'] and result['observed_bytes'] == len(data)
        options['mode'] = None
        result, events = port.call(operation('read_file', receipt, options=options))
        assert result['completion'] == 'completed' and result['native_acknowledged'] and b''.join(chunk for _, chunk in events) == data
        old_epoch = port.hello['epoch']
        first_hello = port.hello
        # Idle helper EOF stops only the tracked VMM and retains its record/disks.
        port.close(eof=True)
        port = Port(package, output / 'config.json', output / 'second.stderr')
        assert port.hello['epoch'] != old_epoch and port.hello['domain'] == first_hello['domain'] and port.hello['package'] == first_hello['package']
        creation_presence(port, create, 'unverified')
        observed(port, 'inspect', receipt, 'stopped')
        observed(port, 'start', receipt, 'running')
        result, events = port.call(operation('read_file', receipt, options=options))
        assert result['completion'] == 'completed' and b''.join(chunk for _, chunk in events) == data
        # A finite deadline without Exit stays uncertain; subsequent explicit
        # stop verifies termination before owned deletion, never command replay.
        sleep = {'argv': ['/bin/sleep', '5'], 'env': {}, 'workdir': '/workspace', 'user': None, 'max_output_bytes': 4096}
        result, _ = port.call(operation('exec', receipt, command=sleep), budget=500)
        assert result['completion'] == 'deadline' and result['observed_exit'] is None
        observed(port, 'stop', receipt, 'stopped')
        observed(port, 'delete', receipt, 'missing')
        creation_presence(port, create, 'absent')
        memory_witness = None
        if manifest['identity']['platform'] == 'linux':
            memory_witness = memory_calibration(port, create, output, int(fields['mem_kib']))
        port.close()
        after = snapshot()
        assert before == after, 'inventory changed beyond owned deletion'
        save(output / 'evidence.json', {'hello': first_hello, 'package_manifest_sha256': config['package_manifest_sha256'], 'host_tools': manifest['host_tools'],
             'fixture_sha256': args.sha256, 'witness': stdout, 'memory_calibration': memory_witness,
             'nonroot_uid': 65534, 'file_bytes': len(data), 'retained_after_helper_eof': True,
             'deadline_without_exit': True, 'owned_deleted': True, 'intent_absence_before_create': True,
             'present_intent_unverified_across_epochs': True, 'intent_absence_after_owned_delete': True,
             'unapproved_intent_not_dispatched': True, 'inventory_before': before, 'inventory_after': after,
             'stderr_bytes': {p.name: p.stat().st_size for p in output.glob('*.stderr')}})
        print(json.dumps({'proof': 'passed', 'witness': stdout, 'file_bytes': len(data), 'retained_after_helper_eof': True, 'owned_deleted': True}))
    except BaseException:
        # No receipt is minted from inventory. Known receipt cleanup only.
        if receipt is not None and port.process.poll() is None:
            try:
                result, _ = port.call(operation('inspect', receipt))
                if result['result'] == 'observed' and result['observation']['state'] == 'running':
                    observed(port, 'stop', receipt, 'stopped')
                observed(port, 'delete', receipt, 'missing')
                save(output / 'failure-cleanup.json', {'owned_deleted': True})
            except BaseException:
                pass
        if port.process.poll() is None:
            port.close(eof=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--domain-json', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    prove(parser.parse_args())


if __name__ == '__main__':
    main()
