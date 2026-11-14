#!/usr/bin/env python3
"""Explicit offline administrator installation. No reset, repair or upgrade path."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import stat
import sys

PROGRAM_DIRECTORY = Path("/usr/local/lib/smolbox-node-authority/v1")
CONFIGURATION = Path("/etc/smolbox-node-authority/enrollment.json")
ENTRYPOINTS = {
    Path("/usr/local/libexec/smolbox-node-authority"): "entrypoint.sh",
    Path("/usr/local/libexec/smolbox-node-authority-ssh"): "ssh-command.sh",
}
INSTALL_LOCK = Path("/run/smolbox-node-authority-install.lock")
ARCHIVE_SHA256 = "89e098b1f7749c515ed95263f081c469befb0aa10b49ee589ccb3e901090608a"
K3S_SHA256 = "5cd49f0faca5b2ea4355d4761e7b1445b8aa05cd50e612fd9c370551db49e5e2"


class InstallationError(RuntimeError):
    """Only fixed, reviewed administrator diagnostics, never command output."""


def trusted_source(path):
    """Check custody before importing any program from the offline archive."""
    for item in [*reversed(path.parents), path]:
        info = item.lstat()
        if info.st_uid != 0 or stat.S_ISLNK(info.st_mode) or info.st_mode & 0o022:
            raise RuntimeError(
                "offline bundle must be in an administrator-controlled tree"
            )


class Installation:
    def __init__(
        self, source, config, runner=None, runtime_archive_sha256=ARCHIVE_SHA256
    ):
        if not isinstance(runtime_archive_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", runtime_archive_sha256
        ):
            raise InstallationError("explicit approved runtime archive digest required")
        self.runtime_archive_sha256 = runtime_archive_sha256
        import authority_assets as assets
        import authority_contract as contract
        import authority_history as history
        from authority_config import owned_path, verify_filesystem
        from authority_runner import Runner
        from authority_verifier import Verifier

        self.assets, self.contract, self.history = assets, contract, history
        self.owned_path, self.verify_filesystem = owned_path, verify_filesystem
        self.config = config
        self.runner = runner if runner is not None else Runner()
        self.source = Path(source)
        self.engine = Verifier(config, self.runner)
        self.engine.bundle = PROGRAM_DIRECTORY
        self.marker = self.engine.STATE / "authority-installing.json"
        self.approval = self.engine.STATE / "authority-approval.json"

    def require(self, condition, message):
        if not condition:
            raise InstallationError(message)
        self.runner.tick()

    def sync_directory(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        self.runner.tick()

    def write_new(self, path, data, mode):
        fd = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            mode,
        )
        with os.fdopen(fd, "wb") as target:
            os.fchmod(target.fileno(), mode)
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        self.runner.tick()
        self.sync_directory(path.parent)

    def descriptor(self, enrollment):
        return {
            "version": 1,
            "binding_generation": self.config.binding["generation"],
            "authority_generation": enrollment["authority_generation"],
            "verifier_manifest_sha256": enrollment["verifier_manifest_sha256"],
            "configuration_sha256": enrollment["configuration_sha256"],
            "history_epoch": enrollment["epoch"],
            "initial_journal": {
                "watermark": 0,
                "prefix_sha256": self.history.EMPTY_HASH,
            },
        }

    def installed_files(self, programs):
        self.verify_filesystem(self.config)
        self.owned_path(CONFIGURATION, "file", private=True)
        self.require(
            CONFIGURATION.read_bytes() == self.config.encoded,
            "installed configuration differs",
        )
        self.owned_path(PROGRAM_DIRECTORY, "directory")
        self.require(
            self.engine.programs() == programs, "installed program bundle differs"
        )
        for path, name in ENTRYPOINTS.items():
            self.require(
                path.is_symlink()
                and os.readlink(path) == str(PROGRAM_DIRECTORY / name),
                "entrypoint differs",
            )
            self.owned_path(path, "file", executable=True, installation_symlinks=True)

    def check_empty_guard(self):
        import hashlib

        guard = self.engine.read_state(self.config.paths["guard_state"])
        binding = self.config.binding
        for key in ("namespace_uid", "node_uid", "node_boot_id"):
            self.require(guard[key] == binding[key], "guard identity differs")
        import time

        self.require(
            0 <= round(time.time() * 1000) - guard["at_unix_ms"] <= 5000
            and guard["qualification_permits"] == []
            and guard["mappings"] == [],
            "guard baseline unavailable",
        )
        approved = binding["runtime_identity"]
        self.require(
            guard["program_sha256"]
            == approved["guard_sha256"]
            == self.engine.sha(self.config.paths["guard_program"])
            and guard["template_sha256"]
            == approved["guard_template_sha256"]
            == hashlib.sha256(self.engine.guard.TEMPLATE.encode()).hexdigest(),
            "guard program/template differs",
        )
        table = json.loads(
            self.engine.run(
                [
                    str(self.config.paths["nft_executable"]),
                    "-j",
                    "list",
                    "table",
                    "bridge",
                    self.engine.guard.TABLE,
                ]
            ),
            object_pairs_hook=self.history.pairs,
        )
        self.require(
            self.engine.guard.rules(table)
            == guard["isolated_ports"]
            == self.engine.guard.rules(guard["table"])
            == [],
            "guard baseline is not empty",
        )

    def preflight(self):
        self.verify_filesystem(self.config, state_required=False)
        basis = self.config.as_dict()["source_basis"]
        for name, field in (
            ("source-basis-history.json", "history_sha256"),
            ("source-basis-lifecycle.json", "lifecycle_sha256"),
        ):
            self.require(
                self.assets.sha(self.source / name, self.runner.tick) == basis[field],
                "unapproved source basis",
            )
        self.require(
            self.config.binding["runtime_identity"]["archive_sha256"]
            == self.runtime_archive_sha256,
            "unqualified runtime archive",
        )
        self.require(
            self.engine.sha(self.config.paths["k3s_executable"]) == K3S_SHA256,
            "unqualified K3s binary",
        )
        expected = {
            key: self.config.binding[key]
            for key in (
                "cluster_anchor_uid",
                "namespace_uid",
                "node_uid",
                "node_boot_id",
            )
        }
        self.require(self.engine.identity() == expected, "enrolled node differs")
        node = self.engine.kube("get", "node", self.config.binding["node_name"])
        info = node["status"]["nodeInfo"]
        self.require(
            info["kubeletVersion"] == self.contract.RUNTIME_VERSIONS["k3s_version"]
            and info["containerRuntimeVersion"]
            == "containerd://" + self.contract.RUNTIME_VERSIONS["containerd_version"]
            and info["architecture"] == "amd64"
            and info["operatingSystem"] == "linux",
            "unqualified node versions/platform",
        )
        runtime_class = self.engine.kube(
            "get", "runtimeclass", self.config.binding["runtime_class"]
        )
        self.require(
            runtime_class["metadata"]["uid"] == self.config.binding["runtime_class_uid"]
            and runtime_class["handler"] == "smolvm"
            and runtime_class["overhead"]["podFixed"]
            == {"cpu": "250m", "memory": "512Mi"},
            "runtime class differs",
        )
        self.check_observer_permissions()
        self.engine.baseline()
        self.check_empty_guard()
        # Detect old authority before publishing any new installation state.
        with self.history.connect(self.engine.DATABASE, runner=self.runner) as database:
            self.require(
                not database.execute(
                    "SELECT name FROM sqlite_master WHERE name LIKE ?",
                    (self.history.PREFIX + "%",),
                ).fetchall(),
                "history already enrolled; no adoption or reset",
            )
            self.require(
                database.execute("SELECT count(*) FROM vms").fetchone() == (0,)
                and database.execute(
                    "SELECT count(*) FROM vm_create_reservations"
                ).fetchone()
                == (0,),
                "runtime is not empty",
            )
        return expected

    def check_observer_permissions(self):
        namespace = self.config.binding["namespace"]
        scope = ["-n", namespace]
        checks = [
            (True, ["get", "namespaces/kube-system"]),
            (True, ["get", "namespaces/" + namespace]),
            (True, ["get", "nodes/" + self.config.binding["node_name"]]),
            (
                True,
                [
                    "get",
                    "runtimeclasses.node.k8s.io/"
                    + self.config.binding["runtime_class"],
                ],
            ),
            (True, ["get", "networkpolicies.networking.k8s.io/offline", *scope]),
            (True, ["get", "pods", *scope]),
            (True, ["list", "pods", *scope]),
            (False, ["create", "pods", *scope]),
            (False, ["delete", "pods", *scope]),
            (False, ["patch", "pods", *scope]),
            (False, ["create", "pods", "--subresource=exec", *scope]),
            (False, ["get", "secrets", *scope]),
            (False, ["list", "secrets", "--all-namespaces"]),
            (False, ["list", "namespaces"]),
            (False, ["list", "nodes"]),
        ]
        for allowed, arguments in checks:
            remaining = max(1, min(3000, int(self.runner.remaining() * 1000)))
            command = [
                str(self.config.paths["kubectl_executable"]),
                "--kubeconfig=" + str(self.config.paths["kubeconfig"]),
                "--request-timeout=" + str(remaining) + "ms",
                "auth",
                "can-i",
                *arguments,
            ]
            # SelfSubjectAccessReview observes authorization; it neither
            # attempts the denied mutation nor grants the endpoint an auth API.
            answer = self.runner(command, allowed_exit_codes=(0, 1)).strip()
            self.require(
                answer == (b"yes" if allowed else b"no"),
                "observer credential permissions differ or are unavailable",
            )

    def repeat(self, programs):
        self.require(
            self.config.binding["runtime_identity"]["archive_sha256"]
            == self.runtime_archive_sha256,
            "unqualified runtime archive",
        )
        self.require(
            not os.path.lexists(self.marker)
            and not list(self.engine.STATE.glob("*.part")),
            "partial installation/publication",
        )
        self.installed_files(programs)
        enrollment = self.engine.read_state(self.engine.ENROLLMENT)
        self.engine.verify_enrollment(enrollment)
        self.require(
            self.engine.read_state(self.approval) == self.descriptor(enrollment),
            "approval descriptor differs or is missing",
        )
        ledger = self.engine.read_state(self.engine.LEDGER)
        self.history.snapshot(self.engine.DATABASE, enrollment, ledger, self.runner)
        self.engine.lifecycle.same(
            enrollment, self.engine.run, self.engine.sha, self.runner.tick
        )
        self.require(
            self.engine.identity() == enrollment["identity"], "enrolled node changed"
        )
        self.check_observer_permissions()
        return self.descriptor(enrollment)

    def install(self):
        programs = self.assets.programs(self.source, self.runner.tick)
        self.owned_path(self.source, "directory")
        self.owned_path(INSTALL_LOCK.parent, "directory")
        with self.runner.locked(INSTALL_LOCK):
            if os.path.lexists(self.engine.ENROLLMENT):
                return self.repeat(programs)
            self.require(
                not any(
                    os.path.lexists(path)
                    for path in (
                        PROGRAM_DIRECTORY,
                        CONFIGURATION,
                        *ENTRYPOINTS,
                        self.marker,
                        self.approval,
                        self.engine.LEDGER,
                    )
                ),
                "partial/different installation; no repair",
            )
            for path in (
                PROGRAM_DIRECTORY.parent,
                CONFIGURATION.parent,
                *(p.parent for p in ENTRYPOINTS),
            ):
                self.owned_path(path, "directory", allow_missing=True)
            self.owned_path(
                self.engine.STATE, "directory", private=True, allow_missing=True
            )
            if self.engine.STATE.exists():
                # Preprovisioned archive inputs are allowed, unrelated authority
                # or controller files are not silently adopted.
                archive = self.config.paths["runtime_archive"]
                for index, path in enumerate(self.engine.STATE.rglob("*")):
                    self.runner.tick()
                    self.require(
                        index < 32 and (path == archive or path in archive.parents),
                        "preexisting authority state",
                    )
            identity = self.preflight()
            self.engine.STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.sync_directory(self.engine.STATE.parent)
            self.history.atomic_json(
                self.marker,
                {"version": 1, "configuration_sha256": self.config.sha256},
                self.runner.tick,
            )
            for directory in (
                PROGRAM_DIRECTORY.parent,
                CONFIGURATION.parent,
                *(p.parent for p in ENTRYPOINTS),
            ):
                missing = []
                for candidate in [*reversed(directory.parents), directory]:
                    if not candidate.exists():
                        missing.append(candidate)
                for candidate in missing:
                    candidate.mkdir(mode=0o755)
                    candidate.chmod(0o755)
                    self.sync_directory(candidate.parent)
                self.owned_path(directory, "directory")
            PROGRAM_DIRECTORY.mkdir(mode=0o755)
            PROGRAM_DIRECTORY.chmod(0o755)
            for name in (*self.assets.PROGRAMS, "manifest.json"):
                self.write_new(
                    PROGRAM_DIRECTORY / name,
                    (self.source / name).read_bytes(),
                    0o755 if name.endswith(".sh") else 0o644,
                )
            self.sync_directory(PROGRAM_DIRECTORY.parent)
            self.write_new(CONFIGURATION, self.config.encoded, 0o600)
            for path, name in ENTRYPOINTS.items():
                path.symlink_to(PROGRAM_DIRECTORY / name)
                self.sync_directory(path.parent)
            self.installed_files(programs)
            runtime = self.assets.runtime_identity(
                self.engine.RUNTIME,
                self.config.paths["runtime_archive"],
                self.runtime_archive_sha256,
                self.runner.tick,
            )
            self.require(
                runtime["template_sizes"]
                == {
                    "storage-template.ext4": 21474836480,
                    "overlay-template.ext4": 10737418240,
                },
                "unqualified disk templates",
            )
            lifecycle = self.engine.lifecycle.current(
                self.engine.run, self.engine.sha, self.runner.tick
            )

            def baseline():
                self.engine.baseline()
                self.check_empty_guard()
                self.require(
                    self.engine.identity() == identity
                    and self.engine.lifecycle.current(
                        self.engine.run, self.engine.sha, self.runner.tick
                    )
                    == lifecycle,
                    "authority changed during enrollment",
                )

            enrollment = self.history.enroll(self.engine.DATABASE, identity, baseline)
            manifest = self.contract.sha256({"version": 1, "files": programs})
            fields = {
                "version": 1,
                "binding_generation": self.config.binding["generation"],
                "history_epoch": enrollment["epoch"],
                "enrollment_nonce": secrets.token_hex(32),
                "verifier_manifest_sha256": manifest,
                "configuration_sha256": self.config.sha256,
            }
            enrollment.update(
                {
                    "active": True,
                    "programs": programs,
                    "runtime": runtime,
                    "archive_sha256": self.runtime_archive_sha256,
                    "lifecycle": lifecycle,
                    "enrollment_nonce": fields["enrollment_nonce"],
                    "verifier_manifest_sha256": manifest,
                    "configuration_sha256": self.config.sha256,
                    "authority_generation": self.contract.generation(fields),
                }
            )
            ledger = {**self.history.initial_ledger(enrollment), "lifecycles": {}}
            self.require(
                self.history.snapshot(
                    self.engine.DATABASE, enrollment, ledger, self.runner
                )["watermark"]
                == 0,
                "runtime changed during enrollment",
            )
            baseline()
            self.engine.check_runtime(enrollment, self.config.binding, {})
            self.engine.verify_enrollment(enrollment)
            with self.runner.locked(self.engine.STATE / "authority.lock"):
                self.history.atomic_json(self.engine.LEDGER, ledger, self.runner.tick)
                descriptor = self.descriptor(enrollment)
                self.history.atomic_json(self.approval, descriptor, self.runner.tick)
                # Active enrollment is published last. The endpoint additionally
                # refuses the marker until installation is fully durable.
                self.history.atomic_json(
                    self.engine.ENROLLMENT, enrollment, self.runner.tick
                )
            self.marker.unlink()
            self.sync_directory(self.engine.STATE)
            return descriptor

    def verify(self):
        programs = self.assets.programs(self.source, self.runner.tick)
        self.owned_path(self.source, "directory")
        # A verification command cannot create installation or lock state.
        self.owned_path(INSTALL_LOCK, "file", private=True)
        with self.runner.locked(INSTALL_LOCK, create=False):
            return self.repeat(programs)


def expired(*_):
    raise TimeoutError("installation deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", required=True, type=Path)
    parser.add_argument(
        "--runtime-archive-sha256",
        default=ARCHIVE_SHA256,
        help="explicit administrator-approved archive; defaults to the pinned release",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="validate existing enrollment without installation or repair",
    )
    args = parser.parse_args()
    if (
        os.geteuid() != 0
        or platform.system() != "Linux"
        or platform.machine() != "x86_64"
    ):
        raise RuntimeError(
            "administrator access on the qualified Linux x86_64 node required"
        )
    source = Path(__file__).resolve().parent / "programs"
    trusted_source(Path(__file__).absolute())
    trusted_source(source)
    for path in source.iterdir():
        trusted_source(path)
    sys.path.insert(0, str(source))
    from authority_config import Configuration, owned_path

    owned_path(args.configuration, "file", private=True)
    with args.configuration.open("rb") as reader:
        config = Configuration(reader.read(131073))
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, 30)
    os.umask(0o077)
    installation = Installation(
        source, config, runtime_archive_sha256=args.runtime_archive_sha256
    )
    print(
        json.dumps(
            installation.verify() if args.verify else installation.install(),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except InstallationError as error:
        print(
            "Node authority installation refused: "
            + str(error)
            + ". No state was reset or repaired.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    except Exception:
        # Administrator output deliberately contains neither credentials nor raw
        # command diagnostics. Partial state is retained for manual inspection.
        print(
            "Node authority installation refused; inspect existing files and authority state. No automatic repair is available.",
            file=sys.stderr,
        )
        raise SystemExit(1)
