"""Read-only kubelet lifecycle witness for the pinned single-node K3s lab.

Pod cgroups witness kubelet work completion, not SmolVM resource confinement.
Never remove a cgroup, stop a daemon, or infer absence from an observation error.
"""
import os
from pathlib import Path
import re
import stat

import node_history as history

ROOT = Path('/sys/fs/cgroup')
PROC = Path('/proc')
K3S = Path('/var/lib/rancher/k3s/data/current/bin/k3s')
require = history.require


def read(path, maximum):
    with path.open('rb') as source:
        value = source.read(maximum + 1)
    require(len(value) <= maximum, 'lifecycle file allocation bound')
    return value


def birth(pid):
    try:
        fields = read(PROC / str(pid) / 'stat', 4096).decode('ascii').rsplit(')', 1)[1].split()
        return int(fields[19])
    except FileNotFoundError:
        return None


def mount():
    rows = [line.split(' - ', 1) for line in read(PROC / 'self/mountinfo', 65536).decode('utf-8').splitlines()
            if line.split()[4] == str(ROOT)]
    require(len(rows) == 1 and rows[0][1].split()[0] == 'cgroup2', 'qualified cgroup2 mount unavailable')
    info = ROOT.lstat()
    require(stat.S_ISDIR(info.st_mode), 'cgroup root changed')
    return {'id': int(rows[0][0].split()[0]), 'device': info.st_dev, 'inode': info.st_ino}


def daemons(run, sha, tick):
    pid = int(run(['/usr/bin/systemctl', 'show', 'k3s.service', '--property=MainPID', '--value']).strip())
    require(1 <= pid <= 4194304, 'K3s daemon unavailable')
    executable = K3S.resolve(strict=True)
    require((PROC / str(pid) / 'exe').resolve(strict=True) == executable, 'K3s executable changed')
    found = []
    count = 0
    for proc in PROC.glob('[0-9]*'):
        count += 1
        require(count <= 4096, 'daemon process inventory bound')
        tick()
        try:
            if read(proc / 'comm', 128).strip() == b'containerd' and (proc / 'exe').resolve(strict=True) == executable:
                fields = read(proc / 'stat', 4096).decode('ascii').rsplit(')', 1)[1].split()
                require(int(fields[1]) == pid, 'containerd parent changed')
                found.append(int(proc.name))
        except FileNotFoundError:
            continue
    require(len(found) == 1, 'containerd daemon unavailable/ambiguous')
    result = []
    fd = os.open(executable, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        image = os.fstat(fd)
        # Hash the shared executable once. PID executable inode checks bind
        # both multicall daemons to those exact immutable running image bytes.
        digest = sha(Path('/proc/self/fd') / str(fd))
        for name, process in [('k3s', pid), ('containerd', found[0])]:
            ticks = birth(process)
            loaded = (PROC / str(process) / 'exe').stat()
            require(ticks is not None and (loaded.st_dev, loaded.st_ino) == (image.st_dev, image.st_ino) and
                    birth(process) == ticks, 'daemon incarnation unavailable')
            result.append({'service': name, 'pid': process, 'start_ticks': ticks, 'exe_sha256': digest})
    finally:
        os.close(fd)
    return result


def current(run, sha, tick):
    return {'mount': mount(), 'daemons': daemons(run, sha, tick)}


def same(enrollment, run, sha, tick):
    value = current(run, sha, tick)
    require(value == enrollment.get('lifecycle'), 'kubelet/containerd lifecycle epoch changed')
    return value


def path(uid):
    require(isinstance(uid, str) and re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', uid),
            'unsupported lifecycle Pod UID')
    return ROOT / 'kubepods.slice' / ('kubepods-pod' + uid.replace('-', '_') + '.slice')


def witnesses(ledger):
    values = ledger.get('lifecycles')
    require(isinstance(values, dict) and len(values) <= 1024, 'lifecycle witness ledger unavailable')
    for uid, value in values.items():
        path(uid)
        require(isinstance(value, dict) and set(value) == {'inode', 'device', 'mount_id'} and
                all(type(v) is int and v > 0 for v in value.values()), 'lifecycle witness corrupt')
    return values


def capture(enrollment, ledger, uid, run, sha, tick):
    before = same(enrollment, run, sha, tick)
    target = path(uid)
    # All ancestors are fixed kernel cgroup paths; no user path can be supplied.
    require(stat.S_ISDIR((ROOT / 'kubepods.slice').lstat().st_mode), 'kubelet cgroup parent changed')
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        require(stat.S_ISDIR(info.st_mode) and info.st_dev == before['mount']['device'] and
                (info.st_dev, info.st_ino) == (target.lstat().st_dev, target.lstat().st_ino),
                'original Pod cgroup unavailable')
        witness = {'inode': info.st_ino, 'device': info.st_dev, 'mount_id': before['mount']['id']}
        values = witnesses(ledger)
        require(uid not in values or values[uid] == witness, 'original Pod cgroup replaced')
        require(same(enrollment, run, sha, tick) == before, 'lifecycle changed during capture')
        ledger['lifecycles'] = {**values, uid: witness}
    finally:
        os.close(fd)


def cleanup(enrollment, ledger, uid, run, sha, tick):
    value = same(enrollment, run, sha, tick)
    witness = witnesses(ledger).get(uid)
    require(witness is not None and witness['mount_id'] == value['mount']['id'] and
            witness['device'] == value['mount']['device'], 'original lifecycle witness missing/changed')
    require(not os.path.lexists(path(uid)), 'original kubelet work/cgroup remains')


def idle(ledger):
    return not any(os.path.lexists(path(uid)) for uid in witnesses(ledger))
