#!/usr/bin/env python3
"""Fixed evidence endpoint, root only inside the disposable K3s guest.

Inspection never mutates a Kubernetes object or runtime machine. It advances
only its own evidence ledger. Runtime audit triggers are installed separately
by the administrator, once, against a positively empty baseline.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time

import node_history as history
import node_lifecycle as lifecycle
import offline_guard
from qualify import manifest_digest, runtime_identity
from smoke import entries


STATE = Path("/var/lib/smolbox-kubernetes")
DATABASE = STATE / "data/smolvm/server/smolvm.db"
VM_ROOT = STATE / "cache/smolvm/vms"
SHARE_ROOT = Path("/var/lib/containerd-shim-smolvm")
RUNTIME = Path("/opt/smolvm-1.34.0-linux-x86_64")
ENROLLMENT = STATE / "node-history-enrollment.json"
LEDGER = STATE / "node-history-ledger.json"
PROGRAMS = ["node_lifecycle.py", "node_history.py", "node_inspector.py", "offline_guard.py", "qualify.py", "smoke.py", "websocket_probe.py"]
IDENTITY_FIELDS = ["cluster_anchor_uid", "namespace_uid", "node_uid", "node_boot_id"]
KVM = ["anon_inode:kvm-vcpu:0", "anon_inode:kvm-vcpu:1", "anon_inode:kvm-vm"]
LIFECYCLE_SHA256 = "cc138716a7a22e1d22c33f26cb8188cc5b11937d19fa27acfe643400126d288e"
WATCH_INPUT = False
DEADLINE = 0
require = history.require


def tick():
    require(time.monotonic() < DEADLINE, "inspection deadline")


def run(arguments):
    tick()
    with subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as process:
        chunks, size = [], 0
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, "stdout")
                selector.register(process.stderr, selectors.EVENT_READ, "stderr")
                if WATCH_INPUT:
                    selector.register(0, selectors.EVENT_READ, "parent")
                while any(key.data != "parent" for key in selector.get_map().values()):
                    tick()
                    for key, _ in selector.select(min(0.1, max(0, DEADLINE - time.monotonic()))):
                        require(key.data != "parent", "inspection owner/input lost")
                        data = os.read(key.fd, 16384)
                        size += len(data)
                        require(size <= 2097152, "inspection command byte bound")
                        if not data:
                            selector.unregister(key.fd)
                        elif key.data == "stdout":
                            chunks.append(data)
                require(process.wait(timeout=max(0.01, DEADLINE - time.monotonic())) == 0,
                        "inspection command unavailable")
        finally:
            if process.poll() is None:
                # Only this program's own read-only observation child is killed.
                process.kill()
                process.wait(timeout=2)
        return b"".join(chunks)


def kube(*arguments, absent=False):
    raw = run(["/usr/local/bin/kubectl", "--request-timeout=3s", *arguments, "-o", "json"])
    if absent and not raw.strip():
        return None
    return json.loads(raw, object_pairs_hook=history.pairs)


def identity():
    anchor = kube("get", "namespace", "kube-system")
    namespace = kube("get", "namespace", "smolbox-preview")
    node = kube("get", "node", "smolbox-k3s")
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    require(node["status"]["nodeInfo"]["bootID"] == boot, "node boot identity changed")
    require(namespace["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") ==
            "smolbox-kubernetes-preview", "namespace is not enrolled")
    return {"cluster_anchor_uid": anchor["metadata"]["uid"],
            "namespace_uid": namespace["metadata"]["uid"],
            "node_uid": node["metadata"]["uid"], "node_boot_id": boot}


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1048576):
            tick()
            digest.update(chunk)
    return digest.hexdigest()


def programs():
    directory = Path(__file__).parent
    values = {name: sha(directory / name) for name in PROGRAMS}
    require(values["node_lifecycle.py"] == LIFECYCLE_SHA256, "unapproved lifecycle program")
    return values


def birth(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return None if fields[0] == "Z" else int(fields[19])
    except FileNotFoundError:
        return None


def physical(attempts):
    directories = {hashlib.sha256(sid.encode()).hexdigest()[:16]: sid for sid in attempts}
    require(len(directories) == len(attempts), "VM directory alias")
    for name in entries(VM_ROOT):
        require(name in directories and not (VM_ROOT / name).is_symlink(), "unmapped VM directory")
    for name in entries(SHARE_ROOT):
        require(name in attempts and not (SHARE_ROOT / name).is_symlink(), "unmapped host share")
    found = []
    processes = list(Path("/proc").iterdir())
    require(len(processes) <= 8192, "process inventory bound")
    for proc in processes:
        tick()
        if not proc.name.isdigit():
            continue
        try:
            argv = (proc / "cmdline").read_bytes().split(b"\0")
            descriptors = []
            for fd in (proc / "fd").iterdir():
                try:
                    target = os.readlink(fd)
                    if "kvm-vm" in target or "kvm-vcpu" in target:
                        descriptors.append(target)
                except FileNotFoundError:
                    continue
            if b"_boot-vm" not in argv:
                require(not descriptors, "unmapped KVM process")
                continue
            require((proc / "exe").resolve() == RUNTIME / "containerd-shim-smolvm-v2",
                    "boot executable changed")
            index = argv.index(b"_boot-vm")
            require(index == 1 and len(argv) == 4 and argv[-1] == b"", "boot arguments changed")
            matches = [sid for directory, sid in directories.items()
                       if str(VM_ROOT / directory / "boot-config.json").encode() == argv[index + 1]]
            require(len(matches) == 1, "unmapped boot process")
            ticks = birth(proc.name)
            if ticks is not None:
                found.append({"sandbox_id": matches[0],
                              "vm_directory": hashlib.sha256(matches[0].encode()).hexdigest()[:16],
                              "pid": int(proc.name), "start_ticks": ticks,
                              "exe_sha256": sha(proc / "exe"), "kvm": sorted(descriptors)})
        except FileNotFoundError:
            continue
    return sorted(found, key=lambda item: item["sandbox_id"])


def cri():
    raw = run(["/usr/local/bin/k3s", "crictl", "pods", "-o", "json"])
    value = json.loads(raw, object_pairs_hook=history.pairs)
    require(isinstance(value.get("items"), list), "CRI inventory unavailable")
    return value["items"]


def baseline():
    require(kube("get", "pods", "-n", "smolbox-preview")["items"] == [], "preview is not empty")
    require(not entries(VM_ROOT) and not entries(SHARE_ROOT) and not physical({}), "physical baseline is not empty")


def install():
    require(not ENROLLMENT.exists() and not LEDGER.exists(), "history exists; no rebaseline")
    pins = history.decode(Path("/etc/smolbox-kubernetes-lab/pins.json").read_bytes())
    runtime = runtime_identity(RUNTIME, Path("/home/lab/smolbox-kubernetes/smolvm.tar.gz"), pins["smolvm"]["sha256"])
    enrollment = history.enroll(DATABASE, identity(), baseline)
    enrollment.update({"lifecycle": lifecycle.current(run, sha, tick), "programs": programs(), "runtime": runtime,
                       "archive_sha256": pins["smolvm"]["sha256"]})
    history.atomic_json(ENROLLMENT, enrollment)
    history.atomic_json(LEDGER, {**history.initial_ledger(enrollment), "lifecycles": {}})
    return {"epoch": enrollment["epoch"], "identity": enrollment["identity"], "programs": enrollment["programs"]}


def qualified_rootfs(root, sandbox_ids):
    # The pinned engine pre-creates this per-VM, zero-byte doorbell fallback.
    # It is runtime bookkeeping, not a shipped rootfs asset. Only exact names
    # derived from journaled attempts may be omitted; every other byte remains
    # compared with the original archive manifest.
    markers = {".smolvm-ready." + hashlib.sha256(sid.encode()).hexdigest()[:16]
               for sid in sandbox_ids}
    manifest = []
    for path in root.rglob("*"):
        tick()
        name = path.relative_to(root).as_posix()
        if name in markers:
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_size == 0 and info.st_nlink == 1,
                    "unqualified runtime readiness marker")
        elif path.is_symlink():
            manifest.append([name, "symlink", os.readlink(path)])
        elif path.is_file():
            manifest.append([name, "file", sha(path)])
        else:
            require(path.is_dir(), "unsupported rootfs entry")
    return manifest_digest(manifest)


def check_runtime(enrollment, binding, sandbox_ids):
    approved = binding["runtime_identity"]
    paths = {"shim_sha256": "containerd-shim-smolvm-v2", "libkrun_sha256": "lib/libkrun.so",
             "kernel_sha256": "lib/libkrunfw.so.5.5.0"}
    require(approved["archive_sha256"] == enrollment["archive_sha256"], "runtime archive changed")
    for field, path in paths.items():
        require(sha(RUNTIME / path) == approved[field] == enrollment["runtime"]["sha256"][path],
                "runtime asset changed")
    rootfs = qualified_rootfs(RUNTIME / "agent-rootfs", sandbox_ids)
    require(rootfs == enrollment["runtime"]["agent_rootfs"] and rootfs["sha256"] == approved["rootfs_sha256"],
            "runtime rootfs changed")


def isolation(binding, uid, sandbox_ids, sandboxes):
    guard = history.decode((STATE / "offline-guard.json").read_bytes())
    require(guard["namespace_uid"] == binding["namespace_uid"] and
            guard["node_uid"] == binding["node_uid"] and guard["node_boot_id"] == binding["node_boot_id"],
            "guard identity changed")
    now = round(time.time() * 1000)
    require(0 <= now - guard["at_unix_ms"] <= 5000 and guard["qualification_permits"] == [], "guard stale/permitted")
    approved = binding["runtime_identity"]
    require(guard["program_sha256"] == approved["guard_sha256"] ==
            sha(Path("/usr/local/lib/smolbox-kubernetes/offline_guard.py")) and
            guard["template_sha256"] == approved["guard_template_sha256"] ==
            hashlib.sha256(offline_guard.TEMPLATE.encode()).hexdigest(), "guard program changed")
    table = json.loads(run(["/usr/sbin/nft", "-j", "list", "table", "bridge", offline_guard.TABLE]))
    ports = offline_guard.rules(table)
    require(ports == guard["isolated_ports"] == offline_guard.rules(guard["table"]), "guard rules changed")
    pod = kube("get", "pods", "-n", "smolbox-preview")["items"]
    pod = [item for item in pod if item["metadata"]["uid"] == uid]
    require(len(pod) == 1, "original Pod unavailable")
    links = json.loads(run(["/usr/sbin/ip", "-j", "link", "show"]))
    # Reuse the qualified mapping verifier, but put its observation children
    # under this endpoint's single deadline, byte cap and owner-loss detection.
    offline_guard.command = lambda argv: subprocess.CompletedProcess(argv, 0, run(argv), b"")
    mappings = offline_guard.mapped_ports(pod, sandboxes, links)
    require(sorted(m["sandbox_id"] for m in mappings) == sandbox_ids, "guard attempt mapping gap")
    for item in mappings:
        require(item in guard["mappings"] and item["interface"] in ports, "sandbox is not isolated")
    return sorted([{"sandbox_id": m["sandbox_id"], "name": m["interface"], "ifindex": m["ifindex"]}
                   for m in mappings], key=lambda item: item["sandbox_id"])


def capture(request, enrollment, audit, ledger, complete, sandboxes):
    uid, binding = request["pod_uid"], request["binding"]
    ids = sorted(sid for sid, owner in ledger["owners"].items() if owner == uid)
    require(complete and len(ids) == 1, "attempt history unavailable/unsupported")
    sid = ids[0]
    attempt = audit["attempts"][sid]
    require(attempt["inserts"] == 1 and sid in audit["material"], "sandbox recreated/absent")
    processes = [p for p in physical(audit["attempts"]) if p["sandbox_id"] == sid]
    require(len(processes) == 1 and processes[0]["kvm"] == KVM and
            attempt["processes"] == {(processes[0]["pid"], processes[0]["start_ticks"])} and
            processes[0]["exe_sha256"] == binding["runtime_identity"]["shim_sha256"], "process incarnation/history gap")
    interfaces = isolation(binding, uid, ids, sandboxes)
    require(processes == [p for p in physical(audit["attempts"]) if p["sandbox_id"] == sid], "process changed during capture")
    lifecycle.capture(enrollment, ledger, uid, run, sha, tick)
    return {"version": 1, "binding_generation": binding["generation"], "pod_uid": uid,
            "sandbox_ids": ids, "processes": processes, "interfaces": interfaces,
            "observer_epoch": enrollment["epoch"], "observed_at_ms": round(time.time() * 1000),
            "guard_sha256": binding["runtime_identity"]["guard_sha256"],
            "guard_template_sha256": binding["runtime_identity"]["guard_template_sha256"],
            "complete_history": True, "isolated": True}


def cleanup(request, enrollment, audit, ledger, complete, sandboxes):
    receipt = request["receipt"]
    capture = receipt["observation"]
    require(complete and capture["observer_epoch"] == enrollment["epoch"] and
            capture["complete_history"] is True and receipt["binding"] == request["binding"], "cleanup authority gap")
    ids = sorted(sid for sid, owner in ledger["owners"].items() if owner == receipt["pod_uid"])
    require(ids == capture["sandbox_ids"], "cleanup sandbox history changed")
    require(kube("get", "pod", receipt["pod_name"], "-n", "smolbox-preview", "--ignore-not-found", absent=True) is None,
            "Pod name still exists")
    require(not any(s.get("metadata", {}).get("uid") == receipt["pod_uid"] for s in sandboxes),
            "original CRI sandbox remains")
    lifecycle.cleanup(enrollment, ledger, receipt["pod_uid"], run, sha, tick)
    physical_processes = physical(audit["attempts"])
    require(not any(p["sandbox_id"] in ids for p in physical_processes), "owned boot process remains")
    for process in capture["processes"]:
        sid = process["sandbox_id"]
        require(audit["attempts"][sid]["inserts"] == 1 and
                audit["attempts"][sid]["processes"] == {(process["pid"], process["start_ticks"])},
                "cleanup process history changed")
        require(birth(process["pid"]) != process["start_ticks"], "original process remains")
    directories = sorted(hashlib.sha256(sid.encode()).hexdigest()[:16] for sid in ids)
    require(all(sid not in audit["material"] and not os.path.lexists(SHARE_ROOT / sid) for sid in ids) and
            all(not os.path.lexists(VM_ROOT / directory) for directory in directories), "owned record/directory/share remains")
    require(not any(s.get("metadata", {}).get("uid") == receipt["pod_uid"] for s in cri()),
            "original CRI sandbox appeared during cleanup")
    lifecycle.cleanup(enrollment, ledger, receipt["pod_uid"], run, sha, tick)
    return {"version": 3, "observed_at_ms": round(time.time() * 1000), "observer_epoch": enrollment["epoch"],
            "api_absent": True, "terminated_processes": capture["processes"], "absent_records": ids,
            "absent_vm_directories": directories, "absent_shares": ids, "complete_history": True}


def idle(audit, sandboxes, ledger):
    return (lifecycle.idle(ledger) and not audit["material"] and not physical(audit["attempts"]) and
            not entries(VM_ROOT) and not entries(SHARE_ROOT) and
            not any(s.get("metadata", {}).get("namespace") == "smolbox-preview" for s in sandboxes) and
            not kube("get", "pods", "-n", "smolbox-preview")["items"])


def acquire(lock):
    while True:
        tick()
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if WATCH_INPUT:
                with selectors.DefaultSelector() as selector:
                    selector.register(0, selectors.EVENT_READ)
                    require(not selector.select(0), "inspection owner/input lost")
            time.sleep(min(0.05, max(0, DEADLINE - time.monotonic())))


def inspect(request):
    require(request.get("version") == 1 and request.get("action") in ["check", "capture", "cleanup"], "inspection schema")
    binding = request["binding"]
    require(binding["namespace"] == "smolbox-preview" and binding["node_name"] == "smolbox-k3s" and
            re.fullmatch(r"[a-f0-9]{64}", binding["generation"]), "unsupported inspection target")
    enrollment = history.decode(ENROLLMENT.read_bytes())
    require(programs() == enrollment["programs"], "inspector program changed")
    current = identity()
    require(current == enrollment["identity"] == {key: binding[key] for key in IDENTITY_FIELDS}, "enrolled node changed")
    with (STATE / "node-history.lock").open("a") as lock:
        acquire(lock)
        ledger = history.decode(LEDGER.read_bytes())
        audit = history.snapshot(DATABASE, enrollment, ledger)
        if request["action"] != "cleanup":
            check_runtime(enrollment, binding, audit["attempts"])
        lifecycle.same(enrollment, run, sha, tick)
        sandboxes = cri()
        ledger, complete = history.reconcile(audit, ledger, sandboxes, "smolbox-preview")
        if request["action"] == "capture":
            value = capture(request, enrollment, audit, ledger, complete, sandboxes)
        elif request["action"] == "cleanup":
            value = cleanup(request, enrollment, audit, ledger, complete, sandboxes)
        else:
            value = {"epoch": enrollment["epoch"], "complete_history": complete,
                     "idle": idle(audit, sandboxes, ledger)}
        after = history.snapshot(DATABASE, enrollment, ledger)
        require(after["hashes"] == audit["hashes"] and
                Path("/proc/sys/kernel/random/boot_id").read_text().strip() == current["node_boot_id"],
                "runtime changed during inspection")
        require(len(json.dumps(ledger, separators=(",", ":")).encode()) <= history.MAX_RECORD, "ledger allocation bound")
        history.atomic_json(LEDGER, ledger)
    return {"version": 1, "action": request["action"], "value": value,
            "inspector_sha256": enrollment["programs"]["node_inspector.py"],
            "history_sha256": enrollment["programs"]["node_history.py"],
            "journal_watermark": ledger["watermark"], "journal_hash": ledger["watermark_hash"]}


def exact(count):
    result = bytearray()
    while len(result) < count:
        chunk = os.read(0, min(16384, count - len(result)))
        require(chunk, "short inspection request")
        result.extend(chunk)
    return bytes(result)


def main():
    global DEADLINE, WATCH_INPUT
    DEADLINE = time.monotonic() + 30
    require(os.geteuid() == 0 and platform.node() == "smolbox-k3s" and
            Path(__file__).parent == Path("/usr/local/lib/smolbox-kubernetes/node-history"), "dedicated inspector required")
    os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(RuntimeError("inspection deadline")))
    signal.alarm(30)
    if sys.argv[1:] == ["install"]:
        result = install()
        print(json.dumps(result, sort_keys=True))
        return
    require(sys.argv[1:] == ["inspect"], "unsupported inspector command")
    require(exact(4) == b"SBH1", "inspection framing")
    length = struct.unpack(">I", exact(4))[0]
    require(0 < length <= 65536, "inspection request bound")
    request = history.decode(exact(length))
    WATCH_INPUT = True
    try:
        response = {"ok": True, **inspect(request)}
    except BaseException:
        response = {"ok": False, "version": 1, "error": "node evidence unavailable"}
    raw = json.dumps(response, separators=(",", ":")).encode()
    require(len(raw) <= 65536, "inspection response bound")
    sys.stdout.buffer.write(b"SBH1" + struct.pack(">I", len(raw)) + raw)
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
