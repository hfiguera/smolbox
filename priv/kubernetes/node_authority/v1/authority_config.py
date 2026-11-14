"""Immutable lexical configuration; privileged filesystem verification is explicit."""

from dataclasses import dataclass
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat

import authority_contract as contract

PATH_KEYS = {
    "state_directory",
    "database",
    "vm_root",
    "share_root",
    "runtime_root",
    "runtime_archive",
    "kubeconfig",
    "cri_socket",
    "k3s_executable",
    "daemon_executable",
    "kubectl_executable",
    "systemctl_executable",
    "ip_executable",
    "nft_executable",
    "nsenter_executable",
    "proc_root",
    "cgroup_root",
    "netns_root",
    "guard_program",
    "guard_state",
}
EXECUTABLES = {
    "k3s_executable",
    "daemon_executable",
    "kubectl_executable",
    "systemctl_executable",
    "ip_executable",
    "nft_executable",
    "nsenter_executable",
}
DIRECTORIES = {
    "state_directory",
    "vm_root",
    "share_root",
    "runtime_root",
    "proc_root",
    "cgroup_root",
    "netns_root",
}
TOP_KEYS = {"version", "binding", "paths", "guard", "source_basis"}
require = contract.require


def absolute(value):
    return (
        contract.text(value, 4096)
        and value.startswith("/")
        and not value.startswith("//")
        and value != "/"
        and ".." not in PurePosixPath(value).parts
        and str(PurePosixPath(value)) == value
    )


def dns_label(value):
    return (
        isinstance(value, str)
        and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", value) is not None
    )


@dataclass(frozen=True)
class Configuration:
    encoded: bytes

    def __post_init__(self):
        require(
            isinstance(self.encoded, bytes) and len(self.encoded) <= 131072,
            "configuration allocation bound",
        )
        value = json.loads(self.encoded, object_pairs_hook=contract.pairs)
        require(
            contract.canonical(value) == self.encoded, "configuration must be canonical"
        )
        require(
            contract.exact(value, TOP_KEYS)
            and type(value["version"]) is int
            and value["version"] == 1,
            "configuration schema",
        )
        binding = contract.binding(value["binding"])
        require(
            dns_label(binding["namespace"])
            and dns_label(binding["runtime_class"])
            and len(binding["node_name"]) <= 253
            and all(dns_label(part) for part in binding["node_name"].split(".")),
            "configuration enrolled names",
        )
        require(
            contract.exact(value["paths"], PATH_KEYS)
            and all(absolute(path) for path in value["paths"].values()),
            "configuration paths",
        )
        paths = value["paths"]
        require(len(set(paths.values())) == len(paths), "configuration path alias")
        guard = value["guard"]
        require(
            contract.exact(
                guard, {"table_name", "marker", "namespace_manager", "bridge"}
            )
            and all(contract.text(item, 128) for item in guard.values())
            and re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]{0,63}", guard["table_name"])
            and re.fullmatch(r"[a-zA-Z0-9_.-]{1,15}", guard["bridge"])
            and re.fullmatch(
                r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,61}[a-zA-Z0-9]|[a-zA-Z0-9]",
                guard["namespace_manager"],
            ),
            "configuration guard",
        )
        require(
            contract.exact(
                value["source_basis"], {"history_sha256", "lifecycle_sha256"}
            )
            and all(contract.digest(item) for item in value["source_basis"].values()),
            "configuration source basis",
        )

    @classmethod
    def from_dict(cls, value):
        return cls(contract.canonical(value))

    def as_dict(self):
        return json.loads(self.encoded)

    @property
    def binding(self):
        return self.as_dict()["binding"]

    @property
    def paths(self):
        return {key: Path(value) for key, value in self.as_dict()["paths"].items()}

    @property
    def guard(self):
        return self.as_dict()["guard"]

    @property
    def sha256(self):
        return contract.sha256(self.as_dict())


def owned_path(
    path,
    kind,
    private=False,
    executable=False,
    installation_symlinks=False,
    allow_missing=False,
):
    """Check actual root custody; only approved executable installation links resolve."""
    path = Path(path)
    pending, links = path, 0
    while True:
        redirected = False
        components = [*reversed(pending.parents), pending]
        for index, component in enumerate(components):
            try:
                info = component.lstat()
            except FileNotFoundError:
                require(allow_missing, "missing authority path")
                return pending
            require(info.st_uid == 0, "unowned or symlinked authority path")
            if stat.S_ISLNK(info.st_mode):
                require(
                    installation_symlinks and links < 40,
                    "unowned or symlinked authority path",
                )
                links += 1
                target = Path(os.readlink(component))
                target = target if target.is_absolute() else component.parent / target
                # Normalize link-relative '..' only after checking the link's
                # own ancestors. Every target chain is checked on the next pass.
                pending = Path(os.path.abspath(target)) / pending.relative_to(component)
                redirected = True
                break
            socket = index == len(components) - 1 and kind == "socket"
            allowed = (
                not info.st_mode & 0o022
                if not socket
                else info.st_gid == 0 and not info.st_mode & 0o007
            )
            require(allowed, "writable authority path")
            if index < len(components) - 1:
                require(stat.S_ISDIR(info.st_mode), "authority ancestor kind")
        if not redirected:
            break
    path = pending
    predicates = {
        "file": stat.S_ISREG,
        "directory": stat.S_ISDIR,
        "socket": stat.S_ISSOCK,
    }
    require(predicates[kind](info.st_mode), "authority file kind")
    if private:
        require(
            stat.S_IMODE(info.st_mode) == (0o700 if kind == "directory" else 0o600),
            "authority private mode",
        )
    if executable:
        require(info.st_mode & 0o111 != 0, "authority executable mode")
    return path


def verify_filesystem(config, action="check"):
    paths = config.paths
    require(
        paths["proc_root"] == Path("/proc")
        and paths["cgroup_root"] == Path("/sys/fs/cgroup")
        and paths["netns_root"] == Path("/run/netns"),
        "unqualified kernel roots",
    )
    require(action in contract.ACTIONS, "filesystem observation action")
    optional_cleanup = {
        "vm_root",
        "share_root",
        "runtime_root",
        "runtime_archive",
        "netns_root",
        "guard_program",
        "guard_state",
        "ip_executable",
        "nft_executable",
        "nsenter_executable",
    }
    for key, path in paths.items():
        kind = (
            "socket"
            if key == "cri_socket"
            else "directory" if key in DIRECTORIES else "file"
        )
        owned_path(
            path,
            kind,
            private=key in {"state_directory", "kubeconfig"},
            executable=key in EXECUTABLES,
            installation_symlinks=key in EXECUTABLES,
            allow_missing=action == "cleanup" and key in optional_cleanup,
        )
    return config
