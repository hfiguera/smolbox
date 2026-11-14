"""Bounded read-only asset/path helpers extracted from the qualified lab probes."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tarfile

from authority_history import require

PROGRAMS = (
    "authority_assets.py",
    "authority_config.py",
    "authority_contract.py",
    "authority_guard.py",
    "authority_history.py",
    "authority_lifecycle.py",
    "authority_runner.py",
    "authority_verifier.py",
    "source-basis-history.json",
    "source-basis-lifecycle.json",
)


def entries(path, vm_root, tick):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return []
    require(stat.S_ISDIR(info.st_mode), "inventory root is not a directory")
    material = []
    for count, item in enumerate(path.iterdir(), 1):
        tick()
        require(count <= 4096, "directory inventory bound")
        # Retain upstream per-name operation-lock inodes, as in the lab probe.
        info = item.lstat()
        inert = (
            path == vm_root
            and re.fullmatch(r"\.[a-f0-9]{64}\.fork-operation\.lock", item.name)
            and stat.S_ISREG(info.st_mode)
            and info.st_size == 0
        )
        if not inert:
            material.append(item.name)
    return sorted(material)


def sha(path, tick):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1048576):
            tick()
            value.update(chunk)
    tick()
    return value.hexdigest()


def manifest_digest(manifest):
    value = hashlib.sha256()
    for entry in sorted(manifest):
        value.update(json.dumps(entry, separators=(",", ":")).encode() + b"\n")
    return {
        "sha256": value.hexdigest(),
        "entries": len(manifest),
        "scheme": "sorted-posix-path-type-content-v1",
    }


def archive_identity(archive, runtime, expected_sha, tick):
    require(sha(archive, tick) == expected_sha, "runtime archive differs from pin")
    assets, rootfs, expanded = {}, [], 0
    prefix = runtime.name + "/"
    with tarfile.open(archive, "r|gz") as source:
        for index, member in enumerate(source):
            tick()
            if member.isdir() and member.name.rstrip("/") == runtime.name:
                continue
            require(
                index < 20000 and member.name.startswith(prefix),
                "unexpected archive layout",
            )
            name = member.name[len(prefix) :]
            require(
                name and ".." not in Path(name).parts and name not in assets,
                "archive name alias",
            )
            if member.isfile():
                expanded += member.size
                require(
                    expanded <= 268435456, "runtime archive expansion limit exceeded"
                )
                value = hashlib.sha256()
                with source.extractfile(member) as content:
                    while chunk := content.read(1048576):
                        tick()
                        value.update(chunk)
                entry = ["file", value.hexdigest()]
                assets[name] = value.hexdigest()
            elif member.issym():
                entry = ["symlink", member.linkname]
            else:
                require(member.isdir(), "unsupported archive entry")
                continue
            if name.startswith("agent-rootfs/"):
                rootfs.append([name[len("agent-rootfs/") :], *entry])
    return assets, manifest_digest(rootfs)


def runtime_identity(runtime, archive, expected_sha, tick):
    paths = [
        "containerd-shim-smolvm-v2",
        "smolvm-bin",
        "lib/libkrun.so",
        "lib/libkrunfw.so.5.5.0",
        "storage-template.ext4.zst",
        "overlay-template.ext4.zst",
    ]
    archived, archive_rootfs = archive_identity(archive, runtime, expected_sha, tick)
    values = {name: sha(runtime / name, tick) for name in paths}
    require(
        all(archived.get(name) == value for name, value in values.items()),
        "installed runtime asset differs from archive",
    )
    manifest = []
    for index, path in enumerate((runtime / "agent-rootfs").rglob("*")):
        tick()
        require(index < 20000, "runtime rootfs inventory bound")
        name = path.relative_to(runtime / "agent-rootfs").as_posix()
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            manifest.append([name, "symlink", os.readlink(path)])
        elif stat.S_ISREG(info.st_mode):
            manifest.append([name, "file", sha(path, tick)])
        else:
            require(stat.S_ISDIR(info.st_mode), "unsupported rootfs entry")
    installed = manifest_digest(manifest)
    require(installed == archive_rootfs, "installed rootfs differs from archive")
    return {
        "sha256": values,
        "archive_verified": True,
        "template_sizes": {
            name: (runtime / name).stat().st_size
            for name in ["storage-template.ext4", "overlay-template.ext4"]
        },
        "agent_rootfs": installed,
    }


def programs(directory, tick):
    parent = directory.lstat()
    require(
        stat.S_ISDIR(parent.st_mode)
        and parent.st_uid == os.geteuid()
        and not parent.st_mode & 0o022,
        "verifier directory ownership",
    )
    names = set()
    for count, item in enumerate(directory.iterdir(), 1):
        tick()
        require(count <= 256, "program inventory bound")
        names.add(item.name)
    require(names == set(PROGRAMS), "unexpected verifier program")
    for name in PROGRAMS:
        info = (directory / name).lstat()
        require(
            stat.S_ISREG(info.st_mode)
            and info.st_nlink == 1
            and info.st_uid == os.geteuid()
            and not info.st_mode & 0o022,
            "verifier program ownership",
        )
    return {name: sha(directory / name, tick) for name in PROGRAMS}
