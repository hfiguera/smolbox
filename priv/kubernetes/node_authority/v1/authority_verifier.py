"""Standalone read-only evidence engine; no lab installer or workload mutation."""

import hashlib
import json
import os
from pathlib import Path
import stat
import time
import authority_assets as assets
import authority_contract as contract
import authority_history as history
from authority_config import verify_filesystem
from authority_guard import Guard
from authority_lifecycle import Lifecycle
from authority_runner import Runner

require = history.require


class Verifier:
    KVM = contract.KVM

    def __init__(self, config, runner=None):
        self.config = config
        self.paths = config.paths
        self.binding = config.binding
        self.guard_settings = config.guard
        self.runner = runner if runner is not None else Runner()
        self.STATE = self.paths["state_directory"]
        self.DATABASE = self.paths["database"]
        self.VM_ROOT = self.paths["vm_root"]
        self.SHARE_ROOT = self.paths["share_root"]
        self.RUNTIME = self.paths["runtime_root"]
        self.ENROLLMENT = self.STATE / "authority-enrollment.json"
        self.LEDGER = self.STATE / "authority-ledger.json"
        self.lifecycle = Lifecycle(config)
        self.guard = Guard(config, self.run)
        self.bundle = Path(__file__).parent

    def tick(self):
        self.runner.tick()

    def sha(self, path):
        return assets.sha(path, self.tick)

    def entries(self, path):
        return assets.entries(path, self.VM_ROOT, self.tick)

    def programs(self):
        return assets.programs(self.bundle, self.tick)

    def run(self, arguments):
        if (
            len(arguments) >= 2
            and arguments[0] == str(self.paths["k3s_executable"])
            and arguments[1] == "crictl"
        ):
            if not any(arg.startswith("--runtime-endpoint=") for arg in arguments):
                arguments = [
                    *arguments[:2],
                    "--runtime-endpoint=unix://" + str(self.paths["cri_socket"]),
                    *arguments[2:],
                ]
        return self.runner(arguments)

    def kube(self, *arguments, absent=False):
        remaining = max(
            1, min(3000, int((self.runner.deadline - time.monotonic()) * 1000))
        )
        raw = self.run(
            [
                str(self.paths["kubectl_executable"]),
                "--kubeconfig=" + str(self.paths["kubeconfig"]),
                "--request-timeout=" + str(remaining) + "ms",
                *arguments,
                "-o",
                "json",
            ]
        )
        if absent and not raw.strip():
            return None
        return json.loads(raw, object_pairs_hook=history.pairs)

    def read_state(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            require(
                stat.S_ISREG(info.st_mode)
                and info.st_nlink == 1
                and info.st_uid == os.geteuid()
                and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_size <= history.MAX_RECORD,
                "authority state ownership/size",
            )
            return history.decode(source.read(history.MAX_RECORD + 1))

    def verify_enrollment(self, enrollment):
        programs = self.programs()
        manifest = contract.sha256({"version": 1, "files": programs})
        require(
            enrollment.get("active") is True
            and enrollment.get("configuration_sha256") == self.config.sha256
            and enrollment.get("programs") == programs
            and enrollment.get("verifier_manifest_sha256") == manifest,
            "enrolled verifier changed",
        )
        basis = self.config.as_dict()["source_basis"]
        require(
            self.sha(self.bundle / "source-basis-history.json")
            == basis["history_sha256"]
            and self.sha(self.bundle / "source-basis-lifecycle.json")
            == basis["lifecycle_sha256"],
            "unapproved verifier source basis",
        )
        fields = {
            "version": 1,
            "binding_generation": self.binding["generation"],
            "history_epoch": enrollment["epoch"],
            "enrollment_nonce": enrollment["enrollment_nonce"],
            "verifier_manifest_sha256": manifest,
            "configuration_sha256": self.config.sha256,
        }
        require(
            enrollment.get("authority_generation") == contract.generation(fields),
            "enrolled authority changed",
        )
        return enrollment["authority_generation"]

    def inspect(self, request):
        require(
            isinstance(request, dict)
            and type(request.get("version")) is int
            and request["version"] == 1
            and isinstance(request.get("action"), str)
            and request["action"] in contract.ACTIONS
            and request.get("binding") == self.binding,
            "unsupported inspection target",
        )
        verify_filesystem(self.config, request["action"])
        require(
            not os.path.lexists(self.STATE / "authority-installing.json"),
            "authority installation incomplete",
        )
        enrollment = self.read_state(self.ENROLLMENT)
        generation = self.verify_enrollment(enrollment)
        expected_keys = {"version", "action", "binding"} | (
            {"receipt"}
            if request["action"] == "cleanup"
            else {"pod_uid"} if request["action"] == "capture" else set()
        )
        require(set(request) == expected_keys, "inspection arguments")
        if request["action"] == "cleanup":
            contract.receipt(
                request["receipt"],
                {
                    "binding_generation": self.binding["generation"],
                    "authority_generation": generation,
                },
            )
            require(
                request["receipt"]["binding"] == self.binding, "cleanup binding differs"
            )
        else:
            require(
                set(request)
                == {"version", "action", "binding"}
                | ({"pod_uid"} if request["action"] == "capture" else set()),
                "inspection arguments",
            )
            if request["action"] == "capture":
                require(contract.history_epoch(request["pod_uid"]), "capture Pod UID")
        current = self.identity()
        expected = {
            key: self.binding[key]
            for key in (
                "cluster_anchor_uid",
                "namespace_uid",
                "node_uid",
                "node_boot_id",
            )
        }
        require(current == enrollment["identity"] == expected, "enrolled node changed")
        with self.runner.locked(self.STATE / "authority.lock"):
            ledger = self.read_state(self.LEDGER)
            audit = history.snapshot(self.DATABASE, enrollment, ledger, self.runner)
            if request["action"] != "cleanup":
                self.check_runtime(enrollment, self.binding, audit["attempts"])
            self.lifecycle.same(enrollment, self.run, self.sha, self.tick)
            sandboxes = self.cri()
            ledger, complete = history.reconcile(
                audit, ledger, sandboxes, self.binding["namespace"]
            )
            if request["action"] == "capture":
                value = self.capture(
                    request, enrollment, audit, ledger, complete, sandboxes
                )
            elif request["action"] == "cleanup":
                value = self.cleanup(
                    request, enrollment, audit, ledger, complete, sandboxes
                )
            else:
                value = {
                    "observer_epoch": generation,
                    "complete_history": complete,
                    "idle": self.idle(audit, sandboxes, ledger),
                }
            after = history.snapshot(self.DATABASE, enrollment, ledger, self.runner)
            require(
                after["hashes"] == audit["hashes"] and self.identity() == current,
                "runtime or node changed during inspection",
            )
            require(
                len(json.dumps(ledger, separators=(",", ":")).encode())
                <= history.MAX_RECORD,
                "ledger allocation bound",
            )
            self.verify_enrollment(enrollment)
            self.tick()
            history.atomic_json(self.LEDGER, ledger, self.tick)
        return {
            "value": value,
            "journal": {
                "history_epoch": enrollment["epoch"],
                "watermark": ledger["watermark"],
                "prefix_sha256": ledger["watermark_hash"],
            },
        }

    def identity(self):
        anchor = self.kube("get", "namespace", "kube-system")
        namespace = self.kube("get", "namespace", self.binding["namespace"])
        node = self.kube("get", "node", self.binding["node_name"])
        boot = (
            Path(self.paths["proc_root"] / "sys/kernel/random/boot_id")
            .read_text()
            .strip()
        )
        require(
            node["status"]["nodeInfo"]["bootID"] == boot, "node boot identity changed"
        )
        require(
            namespace["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by")
            == self.guard_settings["namespace_manager"],
            "namespace is not enrolled",
        )
        return {
            "cluster_anchor_uid": anchor["metadata"]["uid"],
            "namespace_uid": namespace["metadata"]["uid"],
            "node_uid": node["metadata"]["uid"],
            "node_boot_id": boot,
        }

    def birth(self, pid):
        try:
            fields = (
                self.lifecycle.read(self.paths["proc_root"] / f"{pid}/stat", 4096)
                .decode("ascii")
                .rsplit(")", 1)[1]
                .split()
            )
            return None if fields[0] == "Z" else int(fields[19])
        except FileNotFoundError:
            return None

    def physical(self, attempts):
        directories = {
            hashlib.sha256(sid.encode()).hexdigest()[:16]: sid for sid in attempts
        }
        require(len(directories) == len(attempts), "VM directory alias")
        for name in self.entries(self.VM_ROOT):
            require(
                name in directories and (not (self.VM_ROOT / name).is_symlink()),
                "unmapped VM directory",
            )
        for name in self.entries(self.SHARE_ROOT):
            require(
                name in attempts and (not (self.SHARE_ROOT / name).is_symlink()),
                "unmapped host share",
            )
        found = []
        processes = []
        for count, entry in enumerate(self.paths["proc_root"].iterdir(), 1):
            self.tick()
            require(count <= 8192, "process inventory bound")
            processes.append(entry)
        require(len(processes) <= 8192, "process inventory bound")
        for proc in processes:
            self.tick()
            if not proc.name.isdigit():
                continue
            try:
                argv = self.lifecycle.read(proc / "cmdline", 65536).split(b"\x00")
                descriptors = []
                for fd in (proc / "fd").iterdir():
                    self.tick()
                    try:
                        target = os.readlink(fd)
                        if "kvm-vm" in target or "kvm-vcpu" in target:
                            descriptors.append(target)
                    except FileNotFoundError:
                        continue
                if b"_boot-vm" not in argv:
                    require(not descriptors, "unmapped KVM process")
                    continue
                require(
                    (proc / "exe").resolve()
                    == self.RUNTIME / "containerd-shim-smolvm-v2",
                    "boot executable changed",
                )
                index = argv.index(b"_boot-vm")
                require(
                    index == 1 and len(argv) == 4 and (argv[-1] == b""),
                    "boot arguments changed",
                )
                matches = [
                    sid
                    for directory, sid in directories.items()
                    if str(self.VM_ROOT / directory / "boot-config.json").encode()
                    == argv[index + 1]
                ]
                require(len(matches) == 1, "unmapped boot process")
                ticks = self.birth(proc.name)
                if ticks is not None:
                    found.append(
                        {
                            "sandbox_id": matches[0],
                            "vm_directory": hashlib.sha256(
                                matches[0].encode()
                            ).hexdigest()[:16],
                            "pid": int(proc.name),
                            "start_ticks": ticks,
                            "exe_sha256": self.sha(proc / "exe"),
                            "kvm": sorted(descriptors),
                        }
                    )
            except FileNotFoundError:
                continue
        return sorted(found, key=lambda item: item["sandbox_id"])

    def cri(self):
        raw = self.run(
            [str(self.paths["k3s_executable"]), "crictl", "pods", "-o", "json"]
        )
        value = json.loads(raw, object_pairs_hook=history.pairs)
        require(isinstance(value.get("items"), list), "CRI inventory unavailable")
        return value["items"]

    def baseline(self):
        require(
            not any(
                s.get("metadata", {}).get("namespace") == self.binding["namespace"]
                for s in self.cri()
            ),
            "enrolled CRI is not empty",
        )
        require(
            self.kube("get", "pods", "-n", self.binding["namespace"])["items"] == [],
            "preview is not empty",
        )
        require(
            not self.entries(self.VM_ROOT)
            and (not self.entries(self.SHARE_ROOT))
            and (not self.physical({})),
            "physical baseline is not empty",
        )

    def qualified_rootfs(self, root, sandbox_ids):
        markers = {
            ".smolvm-ready." + hashlib.sha256(sid.encode()).hexdigest()[:16]
            for sid in sandbox_ids
        }
        manifest = []
        for index, path in enumerate(root.rglob("*")):
            self.tick()
            require(index < 20000, "runtime rootfs inventory bound")
            name = path.relative_to(root).as_posix()
            if name in markers:
                info = path.lstat()
                require(
                    stat.S_ISREG(info.st_mode)
                    and info.st_size == 0
                    and (info.st_nlink == 1),
                    "unqualified runtime readiness marker",
                )
            elif path.is_symlink():
                manifest.append([name, "symlink", os.readlink(path)])
            elif path.is_file():
                manifest.append([name, "file", self.sha(path)])
            else:
                require(path.is_dir(), "unsupported rootfs entry")
        return assets.manifest_digest(manifest)

    def check_runtime(self, enrollment, binding, sandbox_ids):
        approved = binding["runtime_identity"]
        paths = {
            "shim_sha256": "containerd-shim-smolvm-v2",
            "libkrun_sha256": "lib/libkrun.so",
            "kernel_sha256": "lib/libkrunfw.so.5.5.0",
        }
        require(
            approved["archive_sha256"] == enrollment["archive_sha256"],
            "runtime archive changed",
        )
        for field, path in paths.items():
            require(
                self.sha(self.RUNTIME / path)
                == approved[field]
                == enrollment["runtime"]["sha256"][path],
                "runtime asset changed",
            )
        rootfs = self.qualified_rootfs(self.RUNTIME / "agent-rootfs", sandbox_ids)
        require(
            rootfs == enrollment["runtime"]["agent_rootfs"]
            and rootfs["sha256"] == approved["rootfs_sha256"],
            "runtime rootfs changed",
        )

    def isolation(self, binding, uid, sandbox_ids, sandboxes):
        guard = self.read_state(self.paths["guard_state"])
        require(
            guard["namespace_uid"] == binding["namespace_uid"]
            and guard["node_uid"] == binding["node_uid"]
            and (guard["node_boot_id"] == binding["node_boot_id"]),
            "guard identity changed",
        )
        now = round(time.time() * 1000)
        require(
            0 <= now - guard["at_unix_ms"] <= 5000
            and guard["qualification_permits"] == [],
            "guard stale/permitted",
        )
        approved = binding["runtime_identity"]
        require(
            guard["program_sha256"]
            == approved["guard_sha256"]
            == self.sha(Path(str(self.paths["guard_program"])))
            and guard["template_sha256"]
            == approved["guard_template_sha256"]
            == hashlib.sha256(self.guard.TEMPLATE.encode()).hexdigest(),
            "guard program changed",
        )
        table = json.loads(
            self.run(
                [
                    str(self.paths["nft_executable"]),
                    "-j",
                    "list",
                    "table",
                    "bridge",
                    self.guard.TABLE,
                ]
            ),
            object_pairs_hook=history.pairs,
        )
        ports = self.guard.rules(table)
        require(
            ports == guard["isolated_ports"] == self.guard.rules(guard["table"]),
            "guard rules changed",
        )
        pod = self.kube("get", "pods", "-n", self.binding["namespace"])["items"]
        pod = [item for item in pod if item["metadata"]["uid"] == uid]
        require(len(pod) == 1, "original Pod unavailable")
        links = json.loads(
            self.run([str(self.paths["ip_executable"]), "-j", "link", "show"]),
            object_pairs_hook=history.pairs,
        )
        mappings = self.guard.mapped_ports(pod, sandboxes, links)
        require(
            sorted((m["sandbox_id"] for m in mappings)) == sandbox_ids,
            "guard attempt mapping gap",
        )
        for item in mappings:
            require(
                item in guard["mappings"] and item["interface"] in ports,
                "sandbox is not isolated",
            )
        return sorted(
            [
                {
                    "sandbox_id": m["sandbox_id"],
                    "name": m["interface"],
                    "ifindex": m["ifindex"],
                }
                for m in mappings
            ],
            key=lambda item: item["sandbox_id"],
        )

    def capture(self, request, enrollment, audit, ledger, complete, sandboxes):
        uid, binding = (request["pod_uid"], request["binding"])
        ids = sorted((sid for sid, owner in ledger["owners"].items() if owner == uid))
        require(complete and len(ids) == 1, "attempt history unavailable/unsupported")
        sid = ids[0]
        attempt = audit["attempts"][sid]
        require(
            attempt["inserts"] == 1 and sid in audit["material"],
            "sandbox recreated/absent",
        )
        processes = [
            p for p in self.physical(audit["attempts"]) if p["sandbox_id"] == sid
        ]
        require(
            len(processes) == 1
            and processes[0]["kvm"] == self.KVM
            and (
                attempt["processes"]
                == {(processes[0]["pid"], processes[0]["start_ticks"])}
            )
            and (
                processes[0]["exe_sha256"] == binding["runtime_identity"]["shim_sha256"]
            ),
            "process incarnation/history gap",
        )
        interfaces = self.isolation(binding, uid, ids, sandboxes)
        require(
            processes
            == [p for p in self.physical(audit["attempts"]) if p["sandbox_id"] == sid],
            "process changed during capture",
        )
        self.lifecycle.capture(enrollment, ledger, uid, self.run, self.sha, self.tick)
        return {
            "version": 1,
            "binding_generation": binding["generation"],
            "pod_uid": uid,
            "sandbox_ids": ids,
            "processes": processes,
            "interfaces": interfaces,
            "observer_epoch": enrollment["authority_generation"],
            "observed_at_ms": round(time.time() * 1000),
            "guard_sha256": binding["runtime_identity"]["guard_sha256"],
            "guard_template_sha256": binding["runtime_identity"][
                "guard_template_sha256"
            ],
            "complete_history": True,
            "isolated": True,
        }

    def cleanup(self, request, enrollment, audit, ledger, complete, sandboxes):
        receipt = request["receipt"]
        capture = receipt["observation"]
        require(
            complete
            and capture["observer_epoch"] == enrollment["authority_generation"]
            and (capture["complete_history"] is True)
            and (receipt["binding"] == request["binding"]),
            "cleanup authority gap",
        )
        ids = sorted(
            (
                sid
                for sid, owner in ledger["owners"].items()
                if owner == receipt["pod_uid"]
            )
        )
        require(ids == capture["sandbox_ids"], "cleanup sandbox history changed")
        require(
            self.kube(
                "get",
                "pod",
                receipt["pod_name"],
                "-n",
                self.binding["namespace"],
                "--ignore-not-found",
                absent=True,
            )
            is None,
            "Pod name still exists",
        )
        require(
            not any(
                (
                    s.get("metadata", {}).get("uid") == receipt["pod_uid"]
                    for s in sandboxes
                )
            ),
            "original CRI sandbox remains",
        )
        self.lifecycle.cleanup(
            enrollment, ledger, receipt["pod_uid"], self.run, self.sha, self.tick
        )
        physical_processes = self.physical(audit["attempts"])
        require(
            not any((p["sandbox_id"] in ids for p in physical_processes)),
            "owned boot process remains",
        )
        for process in capture["processes"]:
            sid = process["sandbox_id"]
            require(
                audit["attempts"][sid]["inserts"] == 1
                and audit["attempts"][sid]["processes"]
                == {(process["pid"], process["start_ticks"])},
                "cleanup process history changed",
            )
            require(
                self.birth(process["pid"]) != process["start_ticks"],
                "original process remains",
            )
        directories = sorted(
            (hashlib.sha256(sid.encode()).hexdigest()[:16] for sid in ids)
        )
        require(
            all(
                (
                    sid not in audit["material"]
                    and (not os.path.lexists(self.SHARE_ROOT / sid))
                    for sid in ids
                )
            )
            and all(
                (
                    not os.path.lexists(self.VM_ROOT / directory)
                    for directory in directories
                )
            ),
            "owned record/directory/share remains",
        )
        require(
            not any(
                (
                    s.get("metadata", {}).get("uid") == receipt["pod_uid"]
                    for s in self.cri()
                )
            ),
            "original CRI sandbox appeared during cleanup",
        )
        self.lifecycle.cleanup(
            enrollment, ledger, receipt["pod_uid"], self.run, self.sha, self.tick
        )
        return {
            "version": 3,
            "observed_at_ms": round(time.time() * 1000),
            "observer_epoch": enrollment["authority_generation"],
            "api_absent": True,
            "terminated_processes": capture["processes"],
            "absent_records": ids,
            "absent_vm_directories": directories,
            "absent_shares": ids,
            "complete_history": True,
        }

    def idle(self, audit, sandboxes, ledger):
        return (
            self.lifecycle.idle(ledger)
            and (not audit["material"])
            and (not self.physical(audit["attempts"]))
            and (not self.entries(self.VM_ROOT))
            and (not self.entries(self.SHARE_ROOT))
            and (
                not any(
                    (
                        s.get("metadata", {}).get("namespace")
                        == self.binding["namespace"]
                        for s in sandboxes
                    )
                )
            )
            and (not self.kube("get", "pods", "-n", self.binding["namespace"])["items"])
        )
