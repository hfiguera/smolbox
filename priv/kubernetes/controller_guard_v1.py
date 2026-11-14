"""Fixed same-host controller authority; no machine or Kubernetes operation."""
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid

MAX = 65536
DEADLINE = time.monotonic() + 3


def require(condition):
    if not condition:
        raise ValueError('controller authority unavailable')


def tick():
    require(time.monotonic() < DEADLINE)


def exact(count):
    value = bytearray()
    while len(value) < count:
        tick()
        data = os.read(0, min(16384, count - len(value)))
        require(data)
        value.extend(data)
    return bytes(value)


def pairs(entries):
    value = {}
    for key, data in entries:
        require(key not in value)
        value[key] = data
    return value


def command(arguments):
    with subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env={**os.environ, 'TZ': 'UTC', 'LC_ALL': 'C'}) as child:
        value = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    tick()
                    for key, _ in selector.select(min(0.05, max(0, DEADLINE - time.monotonic()))):
                        data = os.read(key.fd, 16384)
                        value.extend(data)
                        require(len(value) <= MAX)
                        if not data:
                            selector.unregister(key.fd)
            code = child.wait(timeout=max(0.01, DEADLINE - time.monotonic()))
            return code, bytes(value).decode('utf-8').strip()
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=1)


def checked(arguments):
    code, value = command(arguments)
    require(code == 0 and value)
    return value


def host():
    system = platform.system()
    if system == 'Linux':
        identity = Path('/etc/machine-id').read_text().strip()
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    elif system == 'Darwin':
        boot = checked(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']).lower()
        raw = checked(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice'])
        identities = re.findall(r'"IOPlatformUUID"\s*=\s*"([a-fA-F0-9-]{36})"', raw)
        require(len(identities) == 1)
        identity = identities[0].lower()
    else:
        raise ValueError('unsupported controller host')
    require(re.fullmatch(r'[a-f0-9-]{32,36}', identity) and re.fullmatch(r'[a-f0-9-]{36}', boot))
    return identity, boot


def process(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    if platform.system() == 'Linux':
        try:
            raw = (Path('/proc') / str(pid) / 'stat').read_text()
            return 'linux:' + raw.rsplit(')', 1)[1].split()[19]
        except FileNotFoundError:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return None
            raise
    code, value = command(['/bin/ps', '-p', str(pid), '-o', 'lstart='])
    if code != 0 or not value:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        raise ValueError('process observation unavailable')
    # Coarse equality conservatively blocks a reused PID in the same second.
    return 'darwin:' + ' '.join(value.split())


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}', value)


def descriptor(directory, name, create=False):
    flags = os.O_RDONLY if not create else os.O_RDWR | os.O_CREAT
    fd = os.open(name, flags | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
    info = os.fstat(fd)
    try:
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and
                stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= MAX)
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_ledger(directory):
    try:
        fd = descriptor(directory, 'controller.json')
    except FileNotFoundError:
        return None
    try:
        raw = os.read(fd, MAX + 1)
        require(len(raw) <= MAX)
        value = json.loads(raw, object_pairs_hook=pairs)
    finally:
        os.close(fd)
    require(isinstance(value, dict) and set(value) == {'version', 'binding_generation', 'host_id', 'domain_id', 'owners', 'enrolled'})
    require(value['version'] == 1 and type(value['enrolled']) is bool and isinstance(value['owners'], list) and 1 <= len(value['owners']) <= 256)
    require(isinstance(value['domain_id'], str) and re.fullmatch(r'[a-f0-9-]{36}', value['domain_id']))
    owners = set()
    for owner in value['owners']:
        require(isinstance(owner, dict) and set(owner) == {'owner', 'pid', 'birth', 'boot_id'} and
                identifier(owner['owner']) and owner['owner'] not in owners and
                type(owner['pid']) is int and 0 < owner['pid'] <= 2147483647 and
                isinstance(owner['birth'], str) and 0 < len(owner['birth']) <= 128 and
                isinstance(owner['boot_id'], str) and re.fullmatch(r'[a-f0-9-]{36}', owner['boot_id']))
        owners.add(owner['owner'])
    return value


def write_ledger(directory, ledger):
    raw = json.dumps(ledger, separators=(',', ':')).encode()
    require(len(raw) <= MAX)
    name = '.controller-' + os.urandom(16).hex()
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                 0o600, dir_fd=directory)
    try:
        remaining = memoryview(raw)
        while remaining:
            tick()
            count = os.write(fd, remaining[:16384])
            require(count > 0)
            remaining = remaining[count:]
        os.fsync(fd)
        os.replace(name, 'controller.json', src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        os.close(fd)
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass


def guard(request):
    require(set(request) == {'version', 'action', 'directory', 'binding_generation', 'owner', 'pid', 'timeout_ms'})
    require(type(request['version']) is int and request['version'] == 1 and request['action'] in ['acquire', 'check', 'activate'])
    require(isinstance(request['directory'], str) and len(request['directory'].encode()) <= 4096 and
            request['directory'].startswith('/') and '\x00' not in request['directory'] and
            '..' not in Path(request['directory']).parts)
    require(isinstance(request['binding_generation'], str) and re.fullmatch(r'[a-f0-9]{64}', request['binding_generation']))
    require(identifier(request['owner']) and type(request['pid']) is int and 0 < request['pid'] <= 2147483647)
    require(type(request['timeout_ms']) is int and 0 < request['timeout_ms'] <= 3000)
    identity, boot = host()
    current_birth = process(request['pid'])
    require(current_birth is not None)
    directory = os.open(request['directory'], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    lock = None
    try:
        info = os.fstat(directory)
        require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700)
        try:
            os.stat('controller.json', dir_fd=directory, follow_symlinks=False)
            existing = True
        except FileNotFoundError:
            existing = False
        lock = descriptor(directory, 'controller.lock', create=request['action'] == 'acquire' and not existing)
        while True:
            tick()
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                time.sleep(min(0.02, max(0, DEADLINE - time.monotonic())))
        held, named = os.fstat(lock), os.stat('controller.lock', dir_fd=directory, follow_symlinks=False)
        require((held.st_dev, held.st_ino) == (named.st_dev, named.st_ino))
        ledger = read_ledger(directory)
        current = {'owner': request['owner'], 'pid': request['pid'], 'birth': current_birth, 'boot_id': boot}
        if ledger is None:
            require(request['action'] == 'acquire')
            ledger = {'version': 1, 'binding_generation': request['binding_generation'], 'host_id': identity,
                      'domain_id': str(uuid.uuid4()), 'owners': [current], 'enrolled': False}
            write_ledger(directory, ledger)
        else:
            require(ledger['binding_generation'] == request['binding_generation'] and ledger['host_id'] == identity)
            previous = ledger['owners'][-1]
            if previous != current:
                require(request['action'] == 'acquire' and len(ledger['owners']) < 256 and
                        request['owner'] not in [entry['owner'] for entry in ledger['owners']])
                require(previous['boot_id'] != boot or process(previous['pid']) != previous['birth'])
                ledger['owners'].append(current)
                write_ledger(directory, ledger)
        if request['action'] == 'activate' and not ledger['enrolled']:
            # Only the SDK's completed authenticated empty-corpus scan calls
            # this action. The host helper never accesses store credentials.
            ledger['enrolled'] = True
            write_ledger(directory, ledger)
        require(process(request['pid']) == current_birth)
        return {'version': 1, 'binding_generation': ledger['binding_generation'],
                'domain_id': ledger['domain_id'], 'generation': len(ledger['owners']),
                'owner': request['owner'], 'known_owners': [entry['owner'] for entry in ledger['owners']],
                'host_id': identity, 'boot_id': boot, 'pid': request['pid'], 'birth': current_birth,
                'enrolled': ledger['enrolled']}
    finally:
        if lock is not None:
            os.close(lock)
        os.close(directory)


def main():
    global DEADLINE
    signal.signal(signal.SIGALRM, lambda *_: require(False))
    signal.setitimer(signal.ITIMER_REAL, 3)
    require(exact(4) == b'SBG1')
    count = int.from_bytes(exact(4), 'big')
    require(0 < count <= 8192)
    request = json.loads(exact(count), object_pairs_hook=pairs)
    require(isinstance(request, dict))
    timeout = request.get('timeout_ms')
    require(type(timeout) is int and 0 < timeout <= 3000)
    DEADLINE = min(DEADLINE, time.monotonic() + timeout / 1000)
    try:
        response = {'ok': True, 'grant': guard(request)}
    except BaseException:
        response = {'ok': False, 'error': 'controller authority unavailable'}
    raw = json.dumps(response, separators=(',', ':')).encode()
    require(len(raw) <= MAX)
    remaining = memoryview(b'SBG1' + len(raw).to_bytes(4, 'big') + raw)
    while remaining:
        tick()
        count = os.write(1, remaining[:16384])
        require(count > 0)
        remaining = remaining[count:]


if __name__ == '__main__':
    main()
