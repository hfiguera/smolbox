#!/usr/bin/env python3
"""Manual administrator preparation/custody in a fresh dedicated K3s guest only.

Never used by the SDK or evidence endpoint. No authority reset, upgrade, history
replacement, workload creation, or shared physical-host installation is provided.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import sys

ROOT = Path("/root/node-authority-qualification")
LAB = Path("/home/lab/smolbox-kubernetes")
STATE = Path("/var/lib/smolbox-kubernetes")
RUNTIME = Path("/opt/smolvm-1.34.0-linux-x86_64")
DATABASE = STATE / "data/smolvm/server/smolvm.db"
CONFIGURATION = Path("/etc/smolbox-node-authority/enrollment.json")
ARCHIVE_SHA256 = "89e098b1f7749c515ed95263f081c469befb0aa10b49ee589ccb3e901090608a"
K3S_SHA256 = "5cd49f0faca5b2ea4355d4761e7b1445b8aa05cd50e612fd9c370551db49e5e2"
CONTROLLER_RBAC_SHA256 = (
    "03f80ad9adfbd5eb86ed275b28e756f3b07b6d78205e342784c96e2befa27545"
)
GUARD_SHA256 = "cac7a26eb375089efd8d45579c9b6fc977f3217415023ec66696c2b32cec1c4e"
GUARD_TEMPLATE_SHA256 = (
    "d0ea5d6a0df4d3cb84055c4e88d831db54d9c162e637aaed7cf9402ae72e938e"
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        while chunk := source.read(1048576):
            value.update(chunk)
    return value.hexdigest()


def canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode()


def write(path, data, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as stream:
        os.fchmod(stream.fileno(), mode)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def command(argv, *, env=None, timeout=30):
    result = subprocess.run(
        argv, check=True, capture_output=True, env=env, timeout=timeout
    )
    require(
        len(result.stdout) + len(result.stderr) <= 2097152,
        "administrator command output bound",
    )
    return result.stdout


def kube(*args):
    return command(
        [
            "/usr/local/bin/kubectl",
            "--kubeconfig=/etc/rancher/k3s/k3s.yaml",
            "--request-timeout=5s",
            *args,
        ]
    )


def get(kind, name, namespace=None):
    scope = ["-n", namespace] if namespace else []
    return json.loads(kube("get", kind, name, *scope, "-o", "json"))


def trusted_directory(path):
    for item in [*reversed(path.parents), path]:
        info = item.lstat()
        require(
            info.st_uid == 0
            and stat.S_ISDIR(info.st_mode)
            and not info.st_mode & 0o022,
            "root-controlled administrator inputs required",
        )


def core(installed=False):
    directory = (
        Path("/usr/local/lib/smolbox-node-authority/v1")
        if installed
        else ROOT / "bundle/programs"
    )
    trusted_directory(directory)
    sys.path.insert(0, str(directory))
    import authority_assets
    import authority_contract

    return authority_assets, authority_contract


def credentials(name, directory):
    token = kube(
        "create", "token", name, "-n", "smolbox-preview", "--duration=4h"
    ).strip()
    require(
        32 <= len(token) <= 16384 and len(token.split(b".")) == 3,
        "service-account token shape",
    )
    ca = Path("/var/lib/rancher/k3s/server/tls/server-ca.crt").read_bytes()
    configuration = {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [
            {
                "name": "node",
                "cluster": {
                    "server": "https://127.0.0.1:6443",
                    "certificate-authority-data": base64.b64encode(ca).decode(),
                },
            }
        ],
        "contexts": [
            {
                "name": "node",
                "context": {
                    "cluster": "node",
                    "user": name,
                    "namespace": "smolbox-preview",
                },
            }
        ],
        "current-context": "node",
        "users": [{"name": name, "user": {"token": token.decode("ascii")}}],
    }
    write(directory / (name + ".kubeconfig"), canonical(configuration))
    if name == "smolbox-controller":
        write(directory / "controller.token", token + b"\n")
        write(directory / "node-ca.crt", ca)
    return directory / (name + ".kubeconfig")


def stage(bundle, expected, runtime_archive_sha256=ARCHIVE_SHA256):
    require(
        isinstance(runtime_archive_sha256, str)
        and re.fullmatch(r"[0-9a-f]{64}", runtime_archive_sha256),
        "explicit approved runtime archive digest required",
    )
    require(
        not ROOT.exists()
        and not CONFIGURATION.exists()
        and not Path("/var/lib/smolbox-node-authority").exists()
        and not (STATE / "node-history-enrollment.json").exists()
        and not DATABASE.exists(),
        "fresh uninitialized domain required; no replacement",
    )
    require(sha("/usr/local/bin/k3s") == K3S_SHA256, "K3s pin differs")
    require(sha(LAB / "smolvm.tar.gz") == runtime_archive_sha256, "runtime pin differs")
    require(
        sha(LAB / "runtime-rbac.yaml") == CONTROLLER_RBAC_SHA256,
        "controller RBAC source differs",
    )
    sys.path.insert(0, str(Path(__file__).parent))
    import access

    files, _, manifest = access.read_bundle(bundle, expected)
    ROOT.mkdir(mode=0o700)
    (ROOT / "bundle").mkdir(mode=0o700)
    (ROOT / "bundle/programs").mkdir(mode=0o755)
    for name, value in files.items():
        write(ROOT / "bundle" / name, value, 0o755 if name.endswith(".sh") else 0o644)
    shutil.copyfile(LAB / "smolvm.tar.gz", ROOT / "smolvm.tar.gz")
    (ROOT / "smolvm.tar.gz").chmod(0o600)
    require(
        sha(ROOT / "smolvm.tar.gz") == runtime_archive_sha256,
        "copied runtime pin differs",
    )

    # Explicit administrator initialization creates the runtime's empty base
    # schema once. The observation endpoint never invokes this mutating CLI.
    environment = {
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME": "/root",
        "XDG_DATA_HOME": str(STATE / "data"),
        "XDG_CACHE_HOME": str(STATE / "cache"),
        "XDG_CONFIG_HOME": str(STATE / "config"),
        "SMOLVM_LIB_DIR": str(RUNTIME / "lib"),
        "SMOLVM_AGENT_ROOTFS": str(RUNTIME / "agent-rootfs"),
    }
    require(
        json.loads(
            command(
                [str(RUNTIME / "smolvm-bin"), "machine", "ls", "--json"],
                env=environment,
            )
        )
        == [],
        "initial runtime inventory is not empty",
    )
    with sqlite3.connect("file:" + str(DATABASE) + "?mode=ro", uri=True) as database:
        require(
            database.execute("SELECT count(*) FROM vms").fetchone() == (0,)
            and database.execute(
                "SELECT count(*) FROM vm_create_reservations"
            ).fetchone()
            == (0,),
            "initial runtime rows/reservations exist",
        )

    kube("apply", "-f", str(ROOT / "bundle/observer-rbac.yaml"))
    kube("apply", "-f", str(LAB / "runtime-rbac.yaml"))
    directory = Path("/etc/smolbox-node-authority")
    directory.mkdir(mode=0o755)
    observer = credentials("smolbox-node-evidence", ROOT)
    write(directory / "observer.kubeconfig", observer.read_bytes())
    credentials("smolbox-controller", ROOT)
    assets, contract = core()
    runtime = assets.runtime_identity(
        RUNTIME, ROOT / "smolvm.tar.gz", runtime_archive_sha256, lambda: None
    )
    guard = json.loads((STATE / "offline-guard.json").read_bytes())
    require(
        sha("/usr/local/lib/smolbox-kubernetes/offline_guard.py") == GUARD_SHA256
        and guard["program_sha256"] == GUARD_SHA256
        and guard["template_sha256"] == GUARD_TEMPLATE_SHA256,
        "offline guard differs from reviewed source basis",
    )
    identity = {
        "archive_sha256": runtime_archive_sha256,
        "shim_sha256": runtime["sha256"]["containerd-shim-smolvm-v2"],
        "libkrun_sha256": runtime["sha256"]["lib/libkrun.so"],
        "kernel_sha256": runtime["sha256"]["lib/libkrunfw.so.5.5.0"],
        "rootfs_sha256": runtime["agent_rootfs"]["sha256"],
        "guard_sha256": sha("/usr/local/lib/smolbox-kubernetes/offline_guard.py"),
        "guard_template_sha256": guard["template_sha256"],
        **contract.RUNTIME_VERSIONS,
    }
    metadata = {
        "version": 1,
        "scope": "prepared_not_enrolled",
        "bundle_sha256": expected,
        "verifier_manifest_sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
        "cluster_anchor": get("namespace", "kube-system"),
        "namespace": get("namespace", "smolbox-preview"),
        "node": get("node", "smolbox-k3s"),
        "runtime_class": get("runtimeclass", "smolbox-preview"),
        "network_policy": get("networkpolicy", "offline", "smolbox-preview"),
        "runtime_identity": identity,
        "runtime_assets": runtime,
        "node_boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
    }
    write(ROOT / "metadata.json", canonical(metadata))
    print(
        "Prepared pinned runtime/credentials and redacted metadata; no authority enrolled."
    )


def configuration():
    require(
        not CONFIGURATION.exists(),
        "authority already installed; no configuration replacement",
    )
    _, contract = core()
    from authority_config import Configuration

    binding = contract.binding(json.loads((ROOT / "binding.json").read_bytes()))
    metadata = json.loads((ROOT / "metadata.json").read_bytes())
    expected = {
        "cluster_anchor_uid": metadata["cluster_anchor"]["metadata"]["uid"],
        "namespace": "smolbox-preview",
        "namespace_uid": metadata["namespace"]["metadata"]["uid"],
        "node_name": "smolbox-k3s",
        "node_uid": metadata["node"]["metadata"]["uid"],
        "node_boot_id": metadata["node_boot_id"],
        "runtime_class": "smolbox-preview",
        "runtime_class_uid": metadata["runtime_class"]["metadata"]["uid"],
        "runtime_identity": metadata["runtime_identity"],
    }
    require(
        all(binding[key] == value for key, value in expected.items()),
        "SDK binding differs from prepared node",
    )
    value = {
        "version": 1,
        "binding": binding,
        "paths": {
            "state_directory": "/var/lib/smolbox-node-authority",
            "database": str(DATABASE),
            "vm_root": str(STATE / "cache/smolvm/vms"),
            "share_root": "/var/lib/containerd-shim-smolvm",
            "runtime_root": str(RUNTIME),
            "runtime_archive": str(ROOT / "smolvm.tar.gz"),
            "kubeconfig": "/etc/smolbox-node-authority/observer.kubeconfig",
            "cri_socket": "/run/k3s/containerd/containerd.sock",
            "k3s_executable": "/usr/local/bin/k3s",
            "daemon_executable": "/var/lib/rancher/k3s/data/current/bin/k3s",
            "kubectl_executable": "/usr/local/bin/kubectl",
            "systemctl_executable": "/usr/bin/systemctl",
            "ip_executable": "/usr/sbin/ip",
            "nft_executable": "/usr/sbin/nft",
            "nsenter_executable": "/usr/bin/nsenter",
            "proc_root": "/proc",
            "cgroup_root": "/sys/fs/cgroup",
            "netns_root": "/run/netns",
            "guard_program": "/usr/local/lib/smolbox-kubernetes/offline_guard.py",
            "guard_state": str(STATE / "offline-guard.json"),
        },
        "guard": {
            "table_name": "smolbox_preview_guard",
            "marker": "SmolBox preview offline guard v1",
            "namespace_manager": "smolbox-kubernetes-preview",
            "bridge": "cni0",
        },
        "source_basis": {
            "history_sha256": sha(ROOT / "bundle/programs/source-basis-history.json"),
            "lifecycle_sha256": sha(
                ROOT / "bundle/programs/source-basis-lifecycle.json"
            ),
        },
    }
    validated = Configuration.from_dict(value)
    write(ROOT / "configuration.json", validated.encoded)
    print(
        "Wrote immutable administrator configuration; installer remains a separate action."
    )


def custody(report):
    _, _ = core(installed=True)
    import authority_history as history
    from authority_config import Configuration
    from authority_verifier import Verifier

    config = Configuration(CONFIGURATION.read_bytes())
    engine = Verifier(config)
    result = engine.inspect(
        {"version": 1, "action": "check", "binding": config.binding}
    )
    require(
        result["value"]["idle"] is True and result["value"]["complete_history"] is True,
        "final node is not positively empty with complete history",
    )
    enrollment = engine.read_state(engine.ENROLLMENT)
    ledger = engine.read_state(engine.LEDGER)
    audit = history.snapshot(engine.DATABASE, enrollment, ledger, engine.runner)
    value = {
        "version": 1,
        "scope": "real_final_node_custody",
        "authority_generation": enrollment["authority_generation"],
        "history_epoch": enrollment["epoch"],
        "configuration_sha256": config.sha256,
        "verifier_manifest_sha256": enrollment["verifier_manifest_sha256"],
        "positive_check": result,
        "attempt_count": len(audit["attempts"]),
        "enrollment_sha256": sha(engine.ENROLLMENT),
        "ledger_sha256": sha(engine.LEDGER),
    }
    write(report, canonical(value))
    print(json.dumps(value, sort_keys=True))


def main():
    require(
        os.geteuid() == 0
        and os.uname().nodename == "smolbox-k3s"
        and os.uname().machine == "x86_64"
        and command(["/usr/bin/systemd-detect-virt"]).strip() == b"kvm",
        "dedicated root KVM guest required",
    )
    trusted_directory(Path(__file__).resolve().parent)
    source = Path(__file__).resolve().lstat()
    require(
        source.st_uid == 0
        and stat.S_ISREG(source.st_mode)
        and source.st_nlink == 1
        and not source.st_mode & 0o022,
        "root-controlled administrator tool required",
    )
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["stage", "configuration", "custody"])
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--archive-sha256")
    parser.add_argument("--runtime-archive-sha256", default=ARCHIVE_SHA256)
    parser.add_argument("--report", type=Path)
    options = parser.parse_args()
    if options.action == "stage":
        stage(options.bundle, options.archive_sha256, options.runtime_archive_sha256)
    elif options.action == "configuration":
        configuration()
    else:
        custody(options.report)


if __name__ == "__main__":
    main()
