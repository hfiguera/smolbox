#!/usr/bin/env python3
"""Opt-in ordinary Linux Port branches; failed owners retain explicit controls."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import time

from native_proof import Port, operation, save, snapshot

# Serde struct order, never JSON-map iteration order. These hashes correlate
# explicit requests with original helper results; they cannot create ownership.
SCHEMAS = {
    'receipt': ('target_id domain_generation name owner_token incarnation material_sha256 material', {'material': 'material'}),
    'material': ('schema revision record_sha256 chain_sha256 operation_id request_sha256', {}),
    'resources': ('slots cpus memory_mb disk_gb', {}),
    'approval': ('id host_overhead_mb resources', {'resources': 'resources'}),
    'child': ('operation_id name owner_token incarnation idle hold', {}),
    'plan': ('ordinary_child total_additional minimum_extra_memory_mb minimum_extra_disk_gb', {'ordinary_child': 'resources', 'total_additional': 'resources'}),
    'intent': ('source child approval plan request_sha256 source_pid epoch', {'source': 'receipt', 'child': 'child', 'approval': 'approval', 'plan': 'plan'}),
    'binding': ('intent generation raw_child_sha256', {'intent': 'intent'}),
    'source_change': ('child_origin child platform previous_lineage lineage previous_growth_sha256 growth_sha256 previous_capture_sha256 capture_sha256 checkpoint_head', {'child_origin': 'binding', 'child': 'receipt'}),
    'publication': ('schema previous receipt change', {'previous': 'receipt', 'receipt': 'receipt', 'change': 'source_change'}),
    'release_request': ('operation_id request_sha256', {}),
    'release_change': ('request binding identity_sha256 boot_sha256 mode activation_token invariant_sha256', {'request': 'release_request', 'binding': 'binding'}),
    'release': ('schema previous receipt change', {'previous': 'receipt', 'receipt': 'receipt', 'change': 'release_change'}),
    'completion': ('schema publication child identity_sha256 held release', {'publication': 'publication', 'child': 'receipt', 'release': 'release'}),
}


def ordered(value, kind):
    fields, children = SCHEMAS[kind]
    fields = fields.split()
    optional = {'release'} if kind == 'completion' else set()
    assert isinstance(value, dict) and set(value) <= set(fields), 'unknown canonical fields'
    assert set(fields) - optional <= set(value), 'missing canonical fields'
    return {key: ordered(value[key], children[key]) if key in children and value[key] is not None
            else value[key] for key in fields if key in value}


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def backing_request(completion, source, child, operation_id):
    request = dict(completion=completion, source=source, child=child,
                   operation_id=operation_id, request_sha256='', quiesced=True, backing_removed=True)
    request['request_sha256'] = digest(['smolbox-branch-backing-request-v1',
        ordered(completion, 'completion'), ordered(source, 'receipt'), ordered(child, 'receipt'),
        operation_id, True, True])
    return request


def continuation_request(completion, release, child, operation_id):
    request = dict(completion=completion, release=release, child=child,
                   operation_id=operation_id, request_sha256='', quiesced=True)
    request['request_sha256'] = digest(['smolbox-released-child-delete-continuation-request-v1',
        ordered(completion, 'completion'), ordered(release, 'release'), ordered(child, 'receipt'),
        operation_id, True])
    return request


def private_json(path):
    info = path.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
    assert info.st_mode & 0o077 == 0 and info.st_size <= 65536, 'bounded private settings required'
    with path.open('rb') as file:
        data = file.read(65537)
    assert len(data) <= 65536
    return json.loads(data)


def settings(path):
    value = private_json(path)
    assert set(value) == {'package', 'manifest_sha256', 'domain_json', 'artifact', 'branch_approval'}
    assert os.uname().sysname == 'Linux' and os.uname().machine == 'x86_64'
    for p in [value['package'], value['domain_json'], value['artifact']['path']]:
        assert Path(p).is_absolute() and str(Path(p)) == p and '..' not in Path(p).parts
    artifact = value['artifact']
    assert set(artifact) == {'path', 'sha256', 'max_bytes', 'guest_platform'}
    assert artifact['guest_platform'] == 'linux/amd64' and 0 < artifact['max_bytes'] <= 32 << 30
    approval = value['branch_approval']
    assert set(approval) == {'id', 'host_overhead_mb', 'resources'}
    assert approval['resources'] == dict(slots=1, cpus=1, memory_mb=640, disk_gb=5)
    assert approval['host_overhead_mb'] == 128 and approval['id'] == 'ordinary-branches'
    return value


class BranchProof:
    def __init__(self, port, output, approval):
        self.port, self.output, self.approval = port, output, approval
        self.members = [dict(state='missing', receipt=None, completion=None, request=None,
                             release=None, release_request=None, absence=None, backing=None,
                             continuation=None, deletion_entered=False) for _ in range(3)]
        self.closed = False
        self.wire_unresolved = False
        self.last_operation = None
        self.last_result = None
        self.source_pid = None

    def rpc(self, op, budget=30000):
        assert not self.wire_unresolved, 'original request cursor remains unresolved'
        self.last_operation = op['operation']
        try:
            outcome, events = self.port.call(op, budget=budget)
        except BaseException:
            self.wire_unresolved = True
            raise
        self.last_result = outcome.get('result')
        assert events == [], 'unexpected output on evidence operation'
        return outcome

    def observe(self, index, action, before, after):
        member = self.members[index]
        if action != 'inspect':
            assert member['state'] in before, 'unknown operation cannot replay'
            previous = member['state']
            member['state'] = 'unknown'
            if action == 'delete':
                member['deletion_entered'] = True
        budget = 30000 if action in ['inspect', 'branch_preflight'] else 120000
        result = self.rpc(operation(action, member['receipt']), budget)
        if result.get('dispatch') == 'not_dispatched' and action != 'inspect':
            member['state'] = previous
        assert result['result'] == 'observed' and result['observation']['state'] == after
        if action != 'inspect':
            member['state'] = after
        if index == 0 and action == 'start_checkpointable':
            self.source_pid = result['observation']['pid_identity']
            assert self.source_pid is not None
        return result

    def verify_completion(self, index, completion):
        request = self.members[index]['request']
        intent = completion['publication']['change']['child_origin']['intent']
        assert completion['publication']['previous'] == request['source']
        assert intent['child'] == request['child'] and intent['approval'] == request['approval']
        assert intent['epoch'] == self.port.hello['epoch'] and intent['source_pid'] == self.source_pid
        assert completion['held'] == request['child']['hold']
        if not completion['held']:
            assert completion['release']['change']['request'] == request['initial_release']

    def command(self, index, script, expected):
        # Numeric user selection is image-only; a bare guest uses its agent user.
        command = dict(argv=['/bin/sh', '-c', script], env={}, workdir='/',
                       user=None, max_output_bytes=8192)
        assert not self.wire_unresolved, 'original request cursor remains unresolved'
        self.last_operation = 'exec'
        try:
            result, events = self.port.call(operation('exec', self.members[index]['receipt'], command=command))
        except BaseException:
            self.wire_unresolved = True
            raise
        self.last_result = result.get('result')
        assert result['result'] == 'command' and result['completion'] == 'exited'
        assert result['observed_exit'] == 0
        assert b''.join(data for stream, data in events if stream == 'stdout') == expected
        assert not any(data for stream, data in events if stream != 'stdout')

    def data(self, index, expected, ram=True):
        script = 'cat /workspace/smolbox-branch-disk; '
        script += 'cat /dev/shm/smolbox-branch-memory' if ram else 'test ! -e /dev/shm/smolbox-branch-memory'
        self.command(index, script, expected)

    def block_source(self):
        result = self.rpc(operation('stop', self.members[0]['receipt']))
        assert result == dict(result='error', code='state', dispatch='not_dispatched')

    def create_child(self, index):
        member = self.members[index]
        assert member['state'] == 'missing' and member['request'] is None
        child = dict(operation_id='branch-' + secrets.token_hex(12), name='sb-port-branch-' + secrets.token_hex(8),
                     owner_token=secrets.token_hex(32), incarnation=secrets.token_hex(16), idle=True, hold=index == 2)
        request = dict(source=copy.deepcopy(self.members[0]['receipt']), child=child, approval=self.approval)
        if not child['hold']:
            request['initial_release'] = dict(operation_id='initial-' + secrets.token_hex(12), request_sha256=secrets.token_hex(32))
        save(self.output / f'child-{index}-request.json', request)
        member.update(request=request, state='unknown')
        result = self.rpc(dict(operation='create_branch', request=request), 120000)
        assert result['result'] == 'branch_created'
        completion = result['completion']
        self.verify_completion(index, completion)
        member.update(completion=completion, receipt=completion['child'],
                      state='held' if completion['held'] else 'running', release=completion.get('release'))
        self.members[0]['receipt'] = completion['publication']['receipt']
        save(self.output / f'child-{index}-completion.json', completion)
        lookup = self.rpc(dict(operation='inspect_branch_completion', request=request))
        assert lookup == dict(result='branch_completion_presence', completion=completion)
        ready = self.rpc(dict(operation='resolve_ready_branch_completion', request=request, quiesced=True))
        assert ready == lookup, 'original completion qualification differs'

    def release(self):
        member = self.members[2]
        assert member['state'] == 'held' and member['release'] is None
        request = dict(completion=member['completion'], source=self.members[0]['receipt'],
                       request=dict(operation_id='explicit-' + secrets.token_hex(12), request_sha256=secrets.token_hex(32)))
        member['release_request'] = request
        save(self.output / 'held-release-request.json', request)
        member['state'] = 'unknown'
        result = self.rpc(dict(operation='release_held_branch', request=request), 120000)
        assert result['result'] == 'held_branch_released'
        member.update(release=result['transition'], receipt=result['transition']['receipt'], state='running')
        save(self.output / 'held-release-result.json', result['transition'])
        lookup = self.rpc(dict(operation='qualify_held_branch_release', request=request))
        assert lookup == dict(result='held_branch_release_presence', transition=result['transition'])

    def delete(self, index):
        assert index != 0 or all(
            m['state'] == 'missing' and (m['absence'] or (m['receipt'] is None and m['request'] is None))
            for m in self.members[1:])
        member = self.members[index]
        if member['state'] == 'running':
            self.observe(index, 'stop', ['running'], 'stopped')
        self.observe(index, 'delete', ['stopped', 'held'], 'missing')

    def absence(self, index):
        member = self.members[index]
        assert index in [1, 2] and member['state'] == 'missing' and member['completion']
        if member['absence']:
            return
        request = dict(completion=member['completion'], child=member['receipt'],
                       operation_id=f'absent-{index}', request_sha256=secrets.token_hex(32), quiesced=True)
        save(self.output / f'child-{index}-absence-request.json', request)
        result = self.rpc(dict(operation='qualify_branch_child_absence', request=request))
        assert result['result'] == 'branch_child_absent' and result['proof']['request'] == request
        member['absence'] = result['proof']
        save(self.output / f'child-{index}-absence-proof.json', result['proof'])

    def backing(self, index):
        assert all(m['state'] == 'missing' for m in self.members)
        member = self.members[index]
        assert index in [1, 2] and member['absence'] and not member['backing']
        # Ordinary SDK source deletion removed the original per-source snapshot
        # namespace. Names locate only these original receipts, never inventory.
        for m in self.members:
            directory = Path.home() / '.cache/smolvm/vms' / hashlib.sha256(m['receipt']['name'].encode()).hexdigest()[:16]
            assert not directory.exists() and not directory.is_symlink(), 'original backing namespace remains'
        request = backing_request(member['completion'], self.members[0]['receipt'], member['receipt'], f'backing-{index}')
        save(self.output / f'child-{index}-backing-request.json', request)
        result = self.rpc(dict(operation='release_branch_backing', request=request))
        assert result['result'] == 'branch_backing_released'
        assert result['proof']['operation_id'] == request['operation_id']
        assert result['proof']['request_sha256'] == request['request_sha256']
        assert result['proof']['publication'] == member['completion']['publication']
        plan = member['completion']['publication']['change']['child_origin']['intent']['plan']
        assert result['proof']['native_bytes'] == (plan['ordinary_child']['disk_gb'] + plan['minimum_extra_disk_gb']) << 30
        member['backing'] = result['proof']
        save(self.output / f'child-{index}-backing-proof.json', result['proof'])

    def continue_delete(self, index):
        member = self.members[index]
        assert index in [1, 2] and member['state'] == 'unknown' and member['release'] and member['deletion_entered']
        if member['continuation'] is None:
            member['continuation'] = continuation_request(member['completion'], member['release'], member['receipt'], f'continue-delete-{index}')
            save(self.output / f'child-{index}-continuation-request.json', member['continuation'])
        result = self.rpc(dict(operation='continue_released_branch_deletion', request=member['continuation']))
        assert result['result'] == 'released_branch_deletion_continued'
        assert result['proof']['child'] == member['receipt']
        assert result['proof']['operation_id'] == member['continuation']['operation_id']
        assert result['proof']['request_sha256'] == member['continuation']['request_sha256']
        member['state'] = 'missing'
        save(self.output / f'child-{index}-continuation-proof.json', result['proof'])

    def resolve_ready(self, index):
        member = self.members[index]
        assert index in [1, 2] and member['state'] == 'unknown'
        assert member['request'] is not None and member['completion'] is None
        result = self.rpc(dict(operation='resolve_ready_branch_completion', request=member['request'], quiesced=True))
        assert result['result'] == 'branch_completion_presence' and result['completion'] is not None
        completion = result['completion']
        self.verify_completion(index, completion)
        member.update(completion=completion, receipt=completion['child'], release=completion.get('release'),
                      state='held' if completion['held'] else 'running')
        self.members[0]['receipt'] = completion['publication']['receipt']
        save(self.output / f'child-{index}-qualified-completion.json', completion)

    def qualify_release(self):
        member = self.members[2]
        assert member['state'] == 'unknown' and member['release'] is None and member['release_request']
        result = self.rpc(dict(operation='qualify_held_branch_release', request=member['release_request']))
        assert result['result'] == 'held_branch_release_presence' and result['transition'] is not None
        transition = result['transition']
        assert transition['change']['request'] == member['release_request']['request']
        member.update(release=transition, receipt=transition['receipt'], state='running')
        save(self.output / 'held-release-qualified.json', transition)

    def exercise(self, artifact):
        request = dict(name='sb-port-source-' + secrets.token_hex(8), owner_token=secrets.token_hex(32),
                       incarnation=secrets.token_hex(16), artifact=artifact,
                       resources=dict(cpus=1, memory_mib=512, storage_gib=1, overlay_gib=1),
                       labels={}, checkpointable=True)
        save(self.output / 'source-intent.json', request)
        self.members[0]['state'] = 'unknown'
        result = self.rpc(dict(operation='create', create=request), 120000)
        assert result['result'] == 'created'
        self.members[0].update(receipt=result['receipt'], state='stopped')
        save(self.output / 'source-created.json', result['receipt'])
        self.observe(0, 'start_checkpointable', ['stopped'], 'running')
        self.command(0, 'set -eu; mkdir -p /workspace; printf source-disk > /workspace/smolbox-branch-disk; '
                     'printf source-memory > /dev/shm/smolbox-branch-memory; command -v smolvm-branch-ready >/dev/null; '
                     'smolvm-branch-ready </dev/null >/tmp/smolbox-branch-ready.log 2>&1 &', b'')
        self.observe(0, 'branch_preflight', ['running'], 'running')
        self.create_child(1)
        self.block_source()
        self.create_child(2)
        self.data(0, b'source-disksource-memory')
        self.data(1, b'source-disksource-memory')
        self.command(1, 'printf first-disk > /workspace/smolbox-branch-disk; printf first-memory > /dev/shm/smolbox-branch-memory', b'')
        self.release()
        self.data(2, b'source-disksource-memory')
        self.command(2, 'printf second-disk > /workspace/smolbox-branch-disk; printf second-memory > /dev/shm/smolbox-branch-memory', b'')
        self.data(0, b'source-disksource-memory')
        self.data(1, b'first-diskfirst-memory')
        self.data(2, b'second-disksecond-memory')
        self.observe(1, 'stop', ['running'], 'stopped')
        self.observe(1, 'start', ['stopped'], 'running')
        self.data(1, b'first-disk', ram=False)
        self.data(0, b'source-disksource-memory')
        self.data(2, b'second-disksecond-memory')
        self.delete(1)
        self.absence(1)
        self.block_source()
        self.delete(2)
        self.absence(2)
        self.delete(0)
        self.backing(1)
        self.backing(2)
        self.port.close()
        self.closed = True

    def control(self, action):
        if action == 'status':
            return
        if action == 'shutdown-retained':
            # Explicit normal protocol shutdown preserves all disks and supplies
            # no deletion/absence/backing proof. Never signal or restart owners.
            self.port.close()
            self.closed = True
            return
        assert not self.wire_unresolved, 'no fresh control while original request cursor is unresolved'
        if action == 'qualify-held-release':
            self.qualify_release()
            return
        verb, suffix = action.rsplit('-', 1)
        index = {'source': 0, 'first': 1, 'held': 2}[suffix]
        if verb == 'stop':
            self.observe(index, 'stop', ['running'], 'stopped')
        elif verb == 'delete':
            self.delete(index)
        elif verb == 'absence':
            self.absence(index)
        elif verb == 'backing':
            self.backing(index)
        elif verb == 'continue-delete':
            self.continue_delete(index)
        elif verb == 'resolve-ready':
            self.resolve_ready(index)
        else:
            raise ValueError('unknown ordinary control')


def retain(proof, listener):
    while not proof.closed:
        if proof.port.process.poll() is not None:
            return  # Missing original helper can never be replaced or adopted.
        try:
            stream, _ = listener.accept()
        except BaseException:
            time.sleep(0.1)
            continue
        with stream:
            stream.settimeout(2)
            try:
                deadline = time.monotonic() + 2
                data = bytearray()
                while len(data) <= 64:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, 'control read deadline'
                    stream.settimeout(remaining)
                    chunk = stream.recv(65 - len(data))
                    if not chunk:
                        break
                    data.extend(chunk)
                assert 0 < len(data) <= 64
                proof.control(data.decode('ascii').strip())
                response = dict(ok=True)
            except BaseException as error:
                response = dict(ok=False, error=type(error).__name__)
            response.update(closed=proof.closed, states=[m['state'] for m in proof.members],
                            original_request_unresolved=proof.wire_unresolved)
            try:
                stream.sendall(json.dumps(response).encode())
            except BaseException:
                pass  # An observer leaving cannot retire the original helper.


def prove(settings_path, output):
    os.umask(0o077)
    approved = settings(settings_path)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    package = Path(approved['package'])
    manifest_bytes = (package / 'package.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    assert hashlib.sha256(manifest_bytes).hexdigest() == approved['manifest_sha256']
    assert manifest['identity']['platform'] == 'linux' and manifest['identity']['architecture'] == 'x86_64'
    for feature in ['checkpoints', 'branches']:
        assert manifest['policy']['sdk']['feature_versions'].get(feature) == 1
    artifact = approved['artifact']
    with Path(artifact['path']).open('rb') as file:
        assert hashlib.file_digest(file, 'sha256').hexdigest() == artifact['sha256']
    domain = private_json(Path(approved['domain_json']))
    assert set(domain) == {'target_id', 'generation'} and snapshot() == []
    config = dict(schema=2, **domain, allow_initialize=False, package_manifest_sha256=approved['manifest_sha256'],
                  approved_artifacts=[artifact], approved_branches=[approved['branch_approval']])
    save(output / 'config.json', config)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(output / 'control.sock'))
        os.chmod(output / 'control.sock', 0o600)
        listener.listen(1)
        port = Port(package, output / 'config.json', output / 'helper.stderr')
        proof = BranchProof(port, output, approved['branch_approval'])
        try:
            proof.exercise(artifact)
            assert snapshot() == [], 'ordinary branch inventory not empty'
            evidence = dict(status='passed', scope='ordinary-port-branches-linux-local-bare',
                package_manifest_sha256=approved['manifest_sha256'], helper_build_sha256=manifest['identity']['build_sha256'],
                epoch=port.hello['epoch'], source_and_two_children_independent=True, held_release=True,
                normal_child_restart=True, cold_restart_does_not_restore_ram=True, owned_deleted=True,
                owned_child_absence_proofs=2, native_backing_acknowledgements=2, original_ready_lookups=2,
                normal_owner_shutdown=True, port_branch_routing_qualified=True, public_consumer_qualified=False,
                durable_dependency_retirement_qualified=False, crash_validation_performed=False, distribution_approved=False)
            save(output / 'evidence.json', evidence)
            print(json.dumps({k: v for k, v in evidence.items() if k != 'epoch'}))
        except BaseException as error:
            # Diagnostic IO must not unwind a live original helper, even if
            # storage is full or a previous result file already exists.
            try:
                save(output / 'failure.json', dict(error_type=type(error).__name__,
                    last_operation=proof.last_operation, last_result=proof.last_result,
                    states=[m['state'] for m in proof.members], original_request_unresolved=proof.wire_unresolved,
                    original_helper_retained=not proof.closed and port.process.poll() is None,
                    forced_termination=False, crash_validation_performed=False))
            except BaseException:
                pass
            if not proof.closed and port.process.poll() is None:
                try:
                    print('ordinary branch proof failed; original helper retained for explicit controls', flush=True)
                except OSError:
                    pass
                retain(proof, listener)
            raise
    (output / 'control.sock').unlink()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    ordinary = commands.add_parser('ordinary')
    ordinary.add_argument('settings', type=Path)
    ordinary.add_argument('output', type=Path)
    control = commands.add_parser('control')
    control.add_argument('output', type=Path)
    control.add_argument('action', choices=['status', 'shutdown-retained', 'qualify-held-release'] +
                         [f'{verb}-{member}' for verb in ['stop', 'delete', 'absence', 'backing', 'continue-delete', 'resolve-ready']
                          for member in ['source', 'first', 'held'] if member != 'source' or verb in ['stop', 'delete']])
    args = parser.parse_args()
    if args.mode == 'ordinary':
        prove(args.settings, args.output)
    else:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(40)
            client.connect(str(args.output / 'control.sock'))
            client.sendall(args.action.encode())
            client.shutdown(socket.SHUT_WR)
            print(client.recv(4096).decode())
