#!/usr/bin/env python3
"""Manual bounded existing-lock holder for an observation interruption control.

Never creates/unlinks a lock or changes an authority, runtime, Pod or ledger.
EOF releases this operator-owned lock; the entire helper is capped at 30 seconds.
"""
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import stat
import sys
import time


def snapshot():
    """Observe births/KVM descriptors without exposing command or file payloads."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import access

    vms = []
    processes = list(Path("/proc").glob("[0-9]*"))
    if len(processes) > 8192:
        raise RuntimeError("process inventory bound")
    for process in processes:
        try:
            if Path(os.readlink(process / "exe")).name != "containerd-shim-smolvm-v2":
                continue
            fields = (process / "stat").read_text().rsplit(")", 1)[1].split()
            descriptors = list((process / "fd").iterdir())
            if len(descriptors) > 8192:
                raise RuntimeError("descriptor inventory bound")
            kvm = sorted(
                set(
                    target
                    for descriptor in descriptors
                    if (target := os.readlink(descriptor)).startswith("anon_inode:kvm")
                )
            )
            if fields[0] != "Z" and kvm:
                vms.append(
                    {
                        "pid": int(process.name),
                        "start_ticks": int(fields[19]),
                        "kvm": kvm,
                    }
                )
        except FileNotFoundError:
            continue
    print(
        json.dumps(
            {
                "endpoint_processes": sorted(access.endpoint_processes()),
                "vm_processes": sorted(vms, key=lambda item: item["pid"]),
            }
        ),
        flush=True,
    )


if os.geteuid() != 0 or os.uname().nodename != "smolbox-k3s":
    raise RuntimeError("dedicated root guest required")
signal.alarm(30)
if sys.argv[1:] == ["--inspect"]:
    snapshot()
    sys.exit(0)
if len(sys.argv) != 1:
    raise RuntimeError("unknown administrator action")
path = Path("/var/lib/smolbox-node-authority/authority.lock")
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    info = os.fstat(fd)
    if not (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == 0
        and info.st_nlink == 1
        and stat.S_IMODE(info.st_mode) == 0o600
    ):
        raise RuntimeError("original authority lock required")
    deadline = time.monotonic() + 28
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise RuntimeError("operator lock acquisition deadline")
            time.sleep(0.02)
    print(json.dumps({"locked": True, "pid": os.getpid()}), flush=True)
    with selectors.DefaultSelector() as selector:
        selector.register(0, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if selector.select(0.05):
                if not os.read(0, 1):
                    break
finally:
    os.close(fd)
