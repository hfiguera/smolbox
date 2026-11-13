#!/usr/bin/env python3
"""Manual Phase 0 probes, root only inside the disposable Kubernetes node."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import socketserver
import tarfile
import threading
import uuid

from smoke import (Kubernetes, STATE, VM_ROOT, SHARE_ROOT, birth, entries, inventory,
                   kvm_processes, require, run, sandbox_id, wait_for)
from websocket_probe import execute


MANAGER = "smolbox-kubernetes-preview"


def owned_object(kube, kind, name, document, namespace=None):
    existing = kube.get(kind, name, namespace)
    if existing:
        require(existing["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") == MANAGER,
                f"unowned {kind} already exists")
        if "spec" in document:
            # The API omits empty ingress/egress arrays on read-back.
            defaults = {"ingress": [], "egress": []} if kind == "networkpolicy" else {}
            require({**defaults, **existing["spec"]} == {**defaults, **document["spec"]},
                    f"{kind} policy differs")
        for field in document.keys() - {"metadata", "apiVersion", "kind", "spec"}:
            require(existing.get(field) == document[field], f"{kind} {field} differs")
        return existing
    return kube.create(document)


def rootfs_digest(root):
    manifest = []
    for path in root.rglob("*"):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            entry = [name, "symlink", os.readlink(path)]
        elif path.is_file():
            entry = [name, "file", hashlib.sha256(path.read_bytes()).hexdigest()]
        else:
            continue
        manifest.append(entry)
    return manifest_digest(manifest)


def manifest_digest(manifest):
    digest = hashlib.sha256()
    for entry in sorted(manifest):
        digest.update(json.dumps(entry, separators=(",", ":")).encode() + b"\n")
    return {"sha256": digest.hexdigest(), "entries": len(manifest), "scheme": "sorted-posix-path-type-content-v1"}


def archive_identity(archive, runtime, expected_sha):
    digest = hashlib.sha256()
    with archive.open("rb") as file:
        while chunk := file.read(1048576):
            digest.update(chunk)
    require(digest.hexdigest() == expected_sha, "runtime archive differs from pin")
    assets = {}
    rootfs = []
    expanded = 0
    prefix = runtime.name + "/"
    with tarfile.open(archive, "r|gz") as source:
        for index, member in enumerate(source):
            if member.isdir() and member.name.rstrip("/") == runtime.name:
                continue
            require(index < 20000 and member.name.startswith(prefix), "unexpected archive layout")
            name = member.name[len(prefix):]
            if member.isfile():
                expanded += member.size
                require(expanded <= 268435456, "runtime archive expansion limit exceeded")
                content = source.extractfile(member)
                digest = hashlib.sha256()
                while chunk := content.read(1048576):
                    digest.update(chunk)
                entry = ["file", digest.hexdigest()]
                assets[name] = digest.hexdigest()
            elif member.issym():
                entry = ["symlink", member.linkname]
            else:
                require(member.isdir(), "unsupported archive entry")
                continue
            if name.startswith("agent-rootfs/"):
                rootfs.append([name[len("agent-rootfs/"):], *entry])
    return assets, manifest_digest(rootfs)


def runtime_identity(runtime, archive, expected_sha):
    paths = ["containerd-shim-smolvm-v2", "smolvm-bin", "lib/libkrun.so", "lib/libkrunfw.so.5.5.0",
             "storage-template.ext4.zst", "overlay-template.ext4.zst"]
    assets, archive_rootfs = archive_identity(archive, runtime, expected_sha)
    digests = {name: hashlib.sha256((runtime / name).read_bytes()).hexdigest() for name in paths}
    require(all(assets.get(name) == digest for name, digest in digests.items()), "installed runtime asset differs from archive")
    installed_rootfs = rootfs_digest(runtime / "agent-rootfs")
    require(installed_rootfs == archive_rootfs, "installed rootfs differs from archive")
    return {"sha256": digests, "archive_verified": True,
            "template_sizes": {name: (runtime / name).stat().st_size for name in
                               ["storage-template.ext4", "overlay-template.ext4"]},
            "agent_rootfs": installed_rootfs}


def remote_json(kube, namespace, pod, program, *arguments):
    result = kube.command("exec", "-n", namespace, pod, "-c", "workload", "--",
                          "python3", "-I", "-S", "-c", program, *arguments, timeout=45)
    return json.loads(result.stdout)


RESOURCE_PROBE = r"""
import json, os, pathlib, platform
def read(path):
    try: return pathlib.Path(path).read_text()
    except OSError: return None
print(json.dumps({'kernel':platform.release(),'python':platform.python_version(),
 'cpus':os.cpu_count(),'meminfo':read('/proc/meminfo'),'cgroup':read('/proc/self/cgroup'),
 'memory_max':read('/sys/fs/cgroup/memory.max'),'cpu_max':read('/sys/fs/cgroup/cpu.max'),
 'pids_max':read('/sys/fs/cgroup/pids.max'),'ipv6_addresses':read('/proc/net/if_inet6'),
 'ipv6_routes':read('/proc/net/ipv6_route'),
 'process_status':read('/proc/self/status'),
 'workspace_writable':os.access('/workspace',os.W_OK)}))
"""

NETWORK_PROBE = r"""
import json, socket, sys, time
destinations=json.loads(sys.argv[1]); results={}
for name,host,port in destinations:
    start=time.monotonic()
    try:
        with socket.create_connection((host,port),timeout=1): pass
        results[name]={'connected':True}
    except OSError as e:
        results[name]={'connected':False,'errno':e.errno,'error_type':type(e).__name__}
    results[name]['elapsed_ms']=round((time.monotonic()-start)*1000)
# Ask the cluster DNS for its own service, without relying on resolver caches.
try:
    query=b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'+b''.join(bytes([len(x)])+x for x in [b'kubernetes',b'default',b'svc',b'cluster',b'local'])+b'\0\0\x01\0\x01'
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.settimeout(1); s.sendto(query,('10.43.0.10',53)); packet,_=s.recvfrom(512)
        results['cluster_dns_udp']={'connected':packet[:2]==b'\x12\x34'}
except OSError as e: results['cluster_dns_udp']={'connected':False,'errno':e.errno,'error_type':type(e).__name__}
print(json.dumps(results))
"""


class Canary(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b"smolbox-network-canary\n")


class IPv6Server(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True


class IPv4Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


def connected(host, port):
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def qualify(kube, policy, pins, runtime):
    namespace = policy["namespace"]
    labels = {"app.kubernetes.io/managed-by": MANAGER}
    report = {"schema": 1, "phase": 0, "passed": False, "cleanup_verified": False,
              "scope": "phase0-runtime-probes", "preview_policy": policy, "pins": pins, "checks": {}}
    report["runtime"] = runtime_identity(runtime, Path(__file__).with_name("smolvm.tar.gz"), pins["smolvm"]["sha256"])
    baseline = {"machines": inventory(runtime), "vm_dirs": entries(VM_ROOT), "shares": entries(SHARE_ROOT)}
    ns = owned_object(kube, "namespace", namespace,
                      {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace, "labels": labels}})
    report["namespace_uid"] = ns["metadata"]["uid"]
    network_policy = {"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                      "metadata": {"name": "offline", "namespace": namespace, "labels": labels},
                      "spec": {"podSelector": {}, "policyTypes": ["Ingress", "Egress"], "ingress": [], "egress": []}}
    np = owned_object(kube, "networkpolicy", "offline", network_policy, namespace)
    report["network_policy_uid"] = np["metadata"]["uid"]
    pod_name = "qualify-" + uuid.uuid4().hex[:16]
    pod_labels = {**labels, "smolbox.dev/qualification": pod_name}
    uid = None
    allow_uid = None
    guard_permitted = False
    processes = []
    server = IPv4Server(("0.0.0.0", 0), Canary)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    nodeport_server = IPv4Server(("0.0.0.0", 31080), Canary)
    nodeport_server.daemon_threads = True
    threading.Thread(target=nodeport_server.serve_forever, daemon=True).start()
    ipv6_server = IPv6Server(("::", 0), Canary)
    ipv6_server.daemon_threads = True
    threading.Thread(target=ipv6_server.serve_forever, daemon=True).start()
    try:
        document = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": pod_name, "namespace": namespace, "labels": pod_labels},
                    "spec": {"runtimeClassName": policy["runtime_class"], "restartPolicy": "Never",
                             "automountServiceAccountToken": False, "terminationGracePeriodSeconds": 10,
                             "nodeSelector": {"kubernetes.io/hostname": policy["node"], "kubernetes.io/arch": "amd64"},
                             "containers": [{"name": "workload", "image": policy["image"], "imagePullPolicy": "IfNotPresent",
                                             "command": ["python3", "-I", "-S", "-c",
                                                         "import os,socket; os.makedirs('/workspace',exist_ok=True); "
                                                         "s=socket.socket(); s.bind(('0.0.0.0',8080)); s.listen(); "
                                                         "exec(\"while True:\\n c,_=s.accept(); c.sendall(b'canary'); c.close()\")"],
                                             "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]},
                                                                 "seccompProfile": {"type": "RuntimeDefault"}},
                                             "resources": {"requests": policy["container_requests"], "limits": policy["container_limits"]}}]}}
        print("Creating offline qualification Pod", flush=True)
        pod = kube.create(document)
        uid = pod["metadata"]["uid"]
        report["pod_uid"] = uid
        kube.command("wait", "--for=condition=Ready", f"pod/{pod_name}", "-n", namespace,
                     "--timeout=240s", "--request-timeout=250s", timeout=255)
        pod = kube.get("pod", pod_name, namespace)
        report["admitted_overhead"] = pod["spec"].get("overhead")
        report["checks"]["scheduler_memory_accounting"] = pod["spec"].get("overhead", {}).get("memory") == "512Mi"
        report["container"] = pod["status"]["containerStatuses"][0]
        report["pod_ip"] = pod["status"]["podIP"]
        sandbox = sandbox_id(uid)
        report["sandbox_id"] = sandbox
        vm_dir = VM_ROOT / hashlib.sha256(sandbox.encode()).hexdigest()[:16]
        processes = wait_for("qualification KVM process", lambda: kvm_processes(runtime, vm_dir), 30)
        report["kvm_processes"] = processes
        report["process_status"] = [{"pid": p["pid"], "status": Path(f"/proc/{p['pid']}/status").read_text(),
                                      "cgroup": Path(f"/proc/{p['pid']}/cgroup").read_text()} for p in processes]
        report["vm_files"] = {p.name: p.stat().st_size for p in vm_dir.iterdir() if p.is_file() and not p.is_symlink()}
        resources = remote_json(kube, namespace, pod_name, RESOURCE_PROBE)
        report["resources"] = resources
        report["checks"]["fixed_resources"] = resources["cpus"] == 2 and 900000 < int(resources["meminfo"].split("MemTotal:")[1].split()[0]) < 1048576
        report["checks"]["python_workspace"] = resources["workspace_writable"]
        print("Checking controlled node traffic and cluster/public destinations", flush=True)
        port = server.server_address[1]
        guard = Path("/usr/local/lib/smolbox-kubernetes/offline_guard.py")
        require(guard.is_file(), "install the preview offline guard before qualification")
        run(["/usr/bin/python3", str(guard), "permit", uid])
        guard_permitted = True
        with socket.create_connection(("10.0.2.15", port), timeout=2):
            pass
        allow = kube.create({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                             "metadata": {"name": pod_name, "namespace": namespace, "labels": labels},
                             "spec": {"podSelector": {"matchLabels": {"smolbox.dev/qualification": pod_name}},
                                      "policyTypes": ["Ingress", "Egress"],
                                      "ingress": [{"from": [{"ipBlock": {"cidr": "10.0.2.15/32"}},
                                                              {"ipBlock": {"cidr": "10.42.0.1/32"}}],
                                                   "ports": [{"protocol": "TCP", "port": 8080}]}],
                                      "egress": [{"to": [{"ipBlock": {"cidr": "10.0.2.15/32"}}],
                                                  "ports": [{"protocol": "TCP", "port": port}]}]}})
        allow_uid = allow["metadata"]["uid"]
        # A failed connection without a working positive control cannot prove
        # enforcement: a broken guest network would produce the same result.
        control = None
        for _attempt in range(10):
            control = remote_json(kube, namespace, pod_name, NETWORK_PROBE,
                                  json.dumps([["node_canary", "10.0.2.15", port]]))
            if control["node_canary"]["connected"]:
                break
            threading.Event().wait(1)
        report["network_positive_control"] = control
        report["checks"]["network_positive_control"] = control["node_canary"]["connected"]
        report["ingress_positive_control"] = connected(report["pod_ip"], 8080)
        report["checks"]["ingress_positive_control"] = report["ingress_positive_control"]
        cni = json.loads(run(["/usr/sbin/ip", "-j", "-6", "addr", "show", "cni0"]).stdout)
        v6 = [a["local"] for link in cni for a in link["addr_info"] if a["scope"] == "link"]
        require(len(v6) == 1, "one IPv6 canary address required")
        ipv6_destination = ["node_ipv6_linklocal", v6[0] + "%eth0", ipv6_server.server_address[1]]
        report["ipv6_positive_control"] = remote_json(kube, namespace, pod_name, NETWORK_PROBE, json.dumps([ipv6_destination]))
        report["checks"]["ipv6_positive_control"] = report["ipv6_positive_control"]["node_ipv6_linklocal"]["connected"]
        kube.delete_uid(f"/apis/networking.k8s.io/v1/namespaces/{namespace}/networkpolicies/{pod_name}", allow_uid)
        wait_for("canary allowance removal", lambda: kube.get("networkpolicy", pod_name, namespace) is None)
        allow_uid = None
        run(["/usr/bin/python3", str(guard), "unpermit", uid])
        guard_permitted = False
        report["offline_guard"] = json.loads((STATE / "offline-guard.json").read_text())
        require(not report["offline_guard"]["qualification_permits"] and
                any(m["pod_uid"] == uid and m["interface"] in report["offline_guard"]["isolated_ports"]
                    for m in report["offline_guard"]["mappings"]), "Pod guard evidence missing")
        threading.Event().wait(2)
        destinations = [["node_canary", "10.0.2.15", port], ["pod_gateway_canary", "10.42.0.1", port],
                        ["nodeport_canary", "10.0.2.15", 31080],
                        ["cluster_api", "10.43.0.1", 443], ["cluster_dns_tcp", "10.43.0.10", 53],
                        ["public_tls", "1.1.1.1", 443], ["metadata_http", "169.254.169.254", 80]]
        destinations.append(ipv6_destination)
        report["network"] = remote_json(kube, namespace, pod_name, NETWORK_PROBE, json.dumps(destinations))
        report["checks"]["offline_network"] = all(not result["connected"] for result in report["network"].values())
        report["ingress_denied"] = not connected(report["pod_ip"], 8080)
        report["checks"]["ingress_denied"] = report["ingress_denied"]
        report["offline_guard_counters"] = json.loads(run(["/usr/sbin/nft", "-j", "list", "table", "bridge", "smolbox_preview_guard"]).stdout)
        print("Checking raw WebSocket v5 binary channels and exits", flush=True)
        for exit_code in [0, 7]:
            program = f"import os; os.write(1,bytes(range(256))*17); os.write(2,b'\\x00\\xffstderr'); raise SystemExit({exit_code})"
            result = execute(namespace, pod_name, ["python3", "-I", "-S", "-c", program])
            require(result["stdout"] == bytes(range(256)) * 17 and result["stderr"] == b"\x00\xffstderr", "WebSocket binary channels differ")
            require(result["exit_code"] == exit_code, "WebSocket exit differs")
            report.setdefault("websocket", []).append({"protocol": result["protocol"], "exit_code": result["exit_code"],
                                                        "stdout_bytes": len(result["stdout"]), "stderr_bytes": len(result["stderr"]),
                                                        "status": result["status"]})
        report["checks"]["websocket_v5"] = True
        pod = kube.get("pod", pod_name, namespace)
        require(pod["metadata"]["uid"] == uid and pod["status"]["containerStatuses"][0]["containerID"] == report["container"]["containerID"]
                and pod["status"]["containerStatuses"][0]["restartCount"] == 0, "qualification container changed")
    except Exception as error:
        report["error"] = str(error)[-2048:]
    finally:
        server.shutdown()
        server.server_close()
        nodeport_server.shutdown()
        nodeport_server.server_close()
        ipv6_server.shutdown()
        ipv6_server.server_close()
        if guard_permitted:
            try:
                run(["/usr/bin/python3", str(guard), "unpermit", uid])
            except Exception as error:
                report["guard_cleanup_error"] = str(error)[-2048:]
        if allow_uid:
            try:
                kube.delete_uid(f"/apis/networking.k8s.io/v1/namespaces/{namespace}/networkpolicies/{pod_name}", allow_uid)
            except Exception as error:
                report["policy_cleanup_error"] = str(error)[-2048:]
        if uid:
            try:
                kube.delete_uid(f"/api/v1/namespaces/{namespace}/pods/{pod_name}", uid)
                wait_for("qualification Pod deletion", lambda: kube.get("pod", pod_name, namespace) is None)
                wait_for("qualification VM collection", lambda: all(birth(p["pid"]) != p["birth"] for p in processes), 60)
                wait_for("qualification inventories", lambda: inventory(runtime) == baseline["machines"] and
                         entries(VM_ROOT) == baseline["vm_dirs"] and entries(SHARE_ROOT) == baseline["shares"], 60)
                report["cleanup_verified"] = True
            except Exception as error:
                report["cleanup_error"] = str(error)[-2048:]
    report["passed"] = (bool(report["checks"]) and all(report["checks"].values()) and report["cleanup_verified"]
                        and "error" not in report and "policy_cleanup_error" not in report and "guard_cleanup_error" not in report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0 and platform.node() == "smolbox-k3s", "dedicated root lab guest required")
    os.environ.update({"KUBECONFIG": "/etc/rancher/k3s/k3s.yaml", "XDG_DATA_HOME": str(STATE / "data"),
                       "XDG_CACHE_HOME": str(STATE / "cache"), "XDG_CONFIG_HOME": str(STATE / "config")})
    scripts = Path(__file__).parent
    pins = json.loads((scripts / "pins.json").read_text())
    policy = json.loads((scripts / "preview-policy.json").read_text())
    try:
        report = qualify(Kubernetes(), policy, pins, Path(f"/opt/smolvm-{pins['smolvm']['version']}-linux-x86_64"))
    except Exception as error:
        report = {"schema": 1, "phase": 0, "passed": False, "cleanup_verified": False,
                  "error": str(error)[-2048:]}
    report["recorded_at"] = datetime.now(timezone.utc).isoformat()
    report["source_basis"] = json.loads((scripts / "source-basis.json").read_text())
    report["harness_sha256"] = {name: hashlib.sha256((scripts / name).read_bytes()).hexdigest()
                               for name in ["qualify.py", "smoke.py", "websocket_probe.py", "preview-policy.json", "offline_guard.py", "source-basis.json"]}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    args.report.chmod(0o644)
    print(json.dumps({key: report.get(key) for key in ["passed", "checks", "cleanup_verified", "error", "cleanup_error"]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
