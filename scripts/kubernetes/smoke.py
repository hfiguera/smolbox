#!/usr/bin/env python3
"""Real RuntimeClass smoke check, executed as root inside the disposable node.

This tests the upstream Kubernetes runtime, not a SmolBox Kubernetes backend.
No SDK calls, CLI machine creation, or mock shim can satisfy this check.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
import uuid


STATE = Path("/var/lib/smolbox-kubernetes")
VM_ROOT = STATE / "cache/smolvm/vms"
SHARE_ROOT = Path("/var/lib/containerd-shim-smolvm")
PAYLOAD = bytes(range(256)) * 17
STDOUT = b"smolbox-kubernetes-stdout\n"
STDERR = b"smolbox-kubernetes-stderr\n"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(argv, data=None, timeout=30, check=True, hold_stdin=False):
    if hold_stdin:
        # The shim can process CloseIO before draining its input FIFO. Keep the
        # producer open until the length-delimited command exits. EOF behavior
        # is deliberately not qualified by this smoke check.
        require(data is not None and len(data) <= 8192, "bounded stdin payload required")
        with subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            writer = process.stdin
            try:
                writer.write(data)
                writer.flush()
                process.stdin = None
                stdout, stderr = process.communicate(timeout=timeout)
                result = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
            except BaseException:
                process.kill()
                process.communicate()
                raise
            finally:
                writer.close()
    else:
        result = subprocess.run(argv, input=data, capture_output=True, timeout=timeout, check=False)
    if check and result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace")[-4096:]
        raise RuntimeError(f"{argv[0]} exited {result.returncode}: {detail}")
    return result


class Kubernetes:
    def command(self, *args, data=None, timeout=30, check=True, hold_stdin=False):
        return run(["/usr/local/bin/kubectl", "--request-timeout=20s", *args],
                   data=data, timeout=timeout, check=check, hold_stdin=hold_stdin)

    def get(self, kind, name, namespace=None):
        args = ["get", kind, name, "-o", "json", "--ignore-not-found"]
        if namespace:
            args += ["-n", namespace]
        raw = self.command(*args).stdout
        return json.loads(raw) if raw.strip() else None

    def create(self, document):
        return json.loads(self.command("create", "-f", "-", "-o", "json",
                                       data=json.dumps(document).encode()).stdout)

    def delete_uid(self, resource_path, uid):
        # Raw DELETE preserves the API's atomic UID precondition. Never force-delete.
        body = {"apiVersion": "v1", "kind": "DeleteOptions", "gracePeriodSeconds": 10,
                "preconditions": {"uid": uid}}
        self.command("delete", f"--raw={resource_path}", "-f", "-",
                     data=json.dumps(body).encode())


def wait_for(description, predicate, timeout=120):
    deadline = time.monotonic() + timeout
    while True:
        result = predicate()
        if result:
            return result
        require(time.monotonic() < deadline, f"timed out waiting for {description}")
        time.sleep(1)


def entries(path):
    if not path.exists():
        return []
    material = []
    for item in path.iterdir():
        # Upstream retains per-name operation-lock inodes after deletion. Never
        # unlink these: another actor could still hold their original inode.
        inert_lock = (path == VM_ROOT and
                      re.fullmatch(r"\.[a-f0-9]{64}\.fork-operation\.lock", item.name) and
                      not item.is_symlink() and item.is_file() and item.stat().st_size == 0)
        if not inert_lock:
            material.append(item.name)
    return sorted(material)


def inventory(runtime):
    document = json.loads(run([str(runtime / "smolvm-bin"), "machine", "ls", "--json"]).stdout)
    require(isinstance(document, list), "unexpected SmolVM inventory shape")
    return sorted(item["name"] for item in document)


def birth(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return None if fields[0] == "Z" else fields[19]
    except (OSError, IndexError):
        return None


def kvm_processes(runtime, vm_dir):
    found = []
    expected = (runtime / "containerd-shim-smolvm-v2").resolve()
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if (proc / "exe").resolve() != expected:
                continue
            command = (proc / "cmdline").read_bytes().split(b"\0")
            if b"_boot-vm" not in command or not any(str(vm_dir).encode() in a for a in command):
                continue
            descriptors = []
            for fd in (proc / "fd").iterdir():
                try:
                    target = os.readlink(fd)
                    if "kvm-vm" in target or "kvm-vcpu" in target:
                        descriptors.append(target)
                except OSError:
                    continue
            if descriptors and birth(proc.name):
                found.append({"pid": int(proc.name), "birth": birth(proc.name),
                              "descriptors": sorted(descriptors)})
        except (OSError, RuntimeError):
            continue
    return found


def sandbox_id(pod_uid):
    sandboxes = json.loads(run(["/usr/local/bin/k3s", "crictl", "pods", "-o", "json"]).stdout)
    matches = [p["id"] for p in sandboxes.get("items", [])
               if p.get("metadata", {}).get("uid") == pod_uid]
    require(len(matches) == 1, "expected one CRI sandbox for the exact Pod UID")
    return matches[0]


def pod_document(namespace, image):
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": "smoke", "namespace": namespace,
                     "labels": {"app.kubernetes.io/managed-by": "smolbox-kubernetes-smoke"}},
        "spec": {
            "runtimeClassName": "smolvm", "restartPolicy": "Never",
            "automountServiceAccountToken": False, "terminationGracePeriodSeconds": 10,
            "containers": [{"name": "workload", "image": image,
                            "command": ["sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600 & wait $!; done"],
                            "resources": {"requests": {"cpu": "250m", "memory": "128Mi"},
                                          "limits": {"cpu": "1", "memory": "256Mi"}}}]
        }
    }


def execute_and_collect(kube, namespace):
    command = (f"mkdir -p /workspace; dd bs=1 count={len(PAYLOAD)} "
               "of=/workspace/smoke.bin 2>/dev/null; "
               "printf 'smolbox-kubernetes-stdout\\n'; "
               "printf 'smolbox-kubernetes-stderr\\n' >&2; exit 7")
    result = kube.command("exec", "-i", "-n", namespace, "smoke", "-c", "workload",
                          "--", "sh", "-c", command, data=PAYLOAD, check=False, hold_stdin=True)
    require(result.returncode == 7, f"expected workload exit 7, got {result.returncode}")
    require(result.stdout == STDOUT, "stdout bytes changed")
    require(result.stderr == STDERR + b"command terminated with exit code 7\n",
            "stderr bytes or kubectl exit evidence changed")
    collected = kube.command("exec", "-n", namespace, "smoke", "-c", "workload",
                             "--", "cat", "/workspace/smoke.bin").stdout
    require(collected == PAYLOAD,
            f"collected binary file differs from staged input: expected {len(PAYLOAD)} bytes, "
            f"got {len(collected)} bytes (sha256 {hashlib.sha256(collected).hexdigest()})")
    return {"exit_code": result.returncode, "stdin_mode": "length-delimited-producer-held-open",
            "stdout": STDOUT.decode(),
            "stderr": STDERR.decode(), "collected_bytes": len(collected),
            "collected_sha256": hashlib.sha256(collected).hexdigest()}


def smoke(kube, pins, runtime):
    namespace = "smolbox-smoke-" + uuid.uuid4().hex[:16]
    report = {"schema": 1, "scope": "single-node-k3s-upstream-runtime-smoke",
              "smolbox_kubernetes_backend": False, "namespace": namespace,
              "pins": pins, "passed": False, "cleanup_verified": False}
    before = {"machines": inventory(runtime), "vm_dirs": entries(VM_ROOT),
              "shares": entries(SHARE_ROOT)}
    namespace_uid = None
    namespace_attempted = False
    pod_uid = None
    processes = []
    try:
        node = kube.get("node", "smolbox-k3s")
        require(node is not None, "expected the dedicated development node")
        require(node["metadata"].get("labels", {}).get("smolvm-runtime") == "true",
                "node lacks the SmolVM runtime label")
        runtime_class = kube.get("runtimeclass", "smolvm")
        require(runtime_class is not None and runtime_class["handler"] == "smolvm",
                "the real SmolVM RuntimeClass is required")
        info = node.get("status", {}).get("nodeInfo", {})
        report["node"] = {key: info.get(key) for key in
                          ["osImage", "kernelVersion", "kubeletVersion", "containerRuntimeVersion"]}
        namespace_attempted = True
        created_namespace = kube.create({"apiVersion": "v1", "kind": "Namespace",
                                         "metadata": {"name": namespace,
                                                      "labels": {"app.kubernetes.io/managed-by":
                                                                 "smolbox-kubernetes-smoke"}}})
        namespace_uid = created_namespace["metadata"]["uid"]
        print(f"Creating SmolVM Pod in {namespace}", file=sys.stderr, flush=True)
        pod = kube.create(pod_document(namespace, pins["image"]))
        pod_uid = pod["metadata"]["uid"]
        report["pod_uid"] = pod_uid
        kube.command("wait", "--for=condition=Ready", "pod/smoke", "-n", namespace,
                     "--timeout=180s", "--request-timeout=190s", timeout=195)
        pod = kube.get("pod", "smoke", namespace)
        require(pod is not None and pod["metadata"]["uid"] == pod_uid,
                "Pod incarnation changed before execution")
        status = pod["status"]["containerStatuses"][0]
        require(status["restartCount"] == 0, "workload container restarted")
        report["container_id"] = status["containerID"]
        report["image_id"] = status["imageID"]
        sandbox = sandbox_id(pod_uid)
        report["sandbox_id"] = sandbox
        vm_dir = VM_ROOT / hashlib.sha256(sandbox.encode()).hexdigest()[:16]
        require((vm_dir / "name").read_text().strip() == sandbox, "VM directory ownership differs")
        processes = wait_for("sandbox KVM descriptors", lambda: kvm_processes(runtime, vm_dir), 30)
        report["kvm_processes"] = processes
        print("Verified original sandbox KVM descriptors; executing workload", file=sys.stderr, flush=True)
        kernel = kube.command("exec", "-n", namespace, "smoke", "--", "uname", "-sr").stdout.decode().strip()
        require(kernel != "Linux " + platform.release(), "guest kernel matches the Kubernetes node")
        report["guest_kernel"] = kernel
        report["node_kernel"] = platform.release()
        report["execution"] = execute_and_collect(kube, namespace)
        pod = kube.get("pod", "smoke", namespace)
        require(pod is not None and pod["metadata"]["uid"] == pod_uid and
                pod["status"]["containerStatuses"][0]["containerID"] == report["container_id"] and
                pod["status"]["containerStatuses"][0]["restartCount"] == 0,
                "container incarnation changed during execution")
        report["passed"] = True
    except Exception as error:  # Cleanup must still run after every failed assertion.
        report["error"] = str(error)[-4096:]
    finally:
        print("Deleting owned resources and verifying VM collection", file=sys.stderr, flush=True)
        try:
            require(not namespace_attempted or namespace_uid is not None,
                    "namespace creation outcome unknown; UID unavailable for safe cleanup")
            if namespace_uid:
                if pod_uid and kube.get("pod", "smoke", namespace):
                    kube.delete_uid(f"/api/v1/namespaces/{namespace}/pods/smoke", pod_uid)
                    wait_for("Pod deletion", lambda: kube.get("pod", "smoke", namespace) is None)
                kube.delete_uid(f"/api/v1/namespaces/{namespace}", namespace_uid)
                wait_for("namespace deletion", lambda: kube.get("namespace", namespace) is None)
            wait_for("owned KVM process collection",
                     lambda: all(birth(p["pid"]) != p["birth"] for p in processes), 60)
            wait_for("VM records, disks, and shares to return to baseline",
                     lambda: inventory(runtime) == before["machines"] and
                     entries(VM_ROOT) == before["vm_dirs"] and
                     entries(SHARE_ROOT) == before["shares"], 60)
            report["baseline"] = before
            report["after_cleanup"] = {"machines": inventory(runtime),
                                       "vm_dirs": entries(VM_ROOT), "shares": entries(SHARE_ROOT)}
            report["cleanup_verified"] = True
        except Exception as error:
            report["passed"] = False
            report["cleanup_error"] = str(error)[-4096:]
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0 and platform.node() == "smolbox-k3s",
            "run as root only inside the dedicated smolbox-k3s VM")
    os.environ.update({"KUBECONFIG": "/etc/rancher/k3s/k3s.yaml",
                       "XDG_DATA_HOME": str(STATE / "data"),
                       "XDG_CACHE_HOME": str(STATE / "cache"),
                       "XDG_CONFIG_HOME": str(STATE / "config")})
    pins = json.loads(Path(__file__).with_name("pins.json").read_text())
    runtime = Path(f"/opt/smolvm-{pins['smolvm']['version']}-linux-x86_64")
    try:
        k3s_version = run(["/usr/local/bin/k3s", "--version"]).stdout.decode().splitlines()[0]
        require(pins["k3s"]["version"] in k3s_version, "K3s version differs from its pin")
        report = smoke(Kubernetes(), pins, runtime)
        report["k3s_version"] = k3s_version
        report["shim_sha256"] = hashlib.sha256((runtime / "containerd-shim-smolvm-v2").read_bytes()).hexdigest()
        report["guest_packages"] = run(["dpkg-query", "-W", "-f=${Package}=${Version}\n",
                                        "ca-certificates", "curl", "jq", "python3", "zstd",
                                        "iproute2", "util-linux"]).stdout.decode().splitlines()
    except Exception as error:
        report = {"schema": 1, "passed": False, "cleanup_verified": False,
                  "error": str(error)[-4096:]}
    report["recorded_at"] = datetime.now(timezone.utc).isoformat()
    report["harness_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.report.with_suffix(".part")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.chmod(0o644)  # Contains test identities and dummy data, no kubeconfig or tokens.
    temporary.replace(args.report)
    print(json.dumps({"passed": report["passed"], "cleanup_verified": report["cleanup_verified"],
                      "report": str(args.report), "error": report.get("error"),
                      "cleanup_error": report.get("cleanup_error")}))
    return 0 if report["passed"] and report["cleanup_verified"] else 1


if __name__ == "__main__":
    sys.exit(main())
