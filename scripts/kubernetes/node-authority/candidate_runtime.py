#!/usr/bin/env python3
"""Build a manual v1.34.0 candidate by replacing only its reviewed shim binary.

No installation, runtime mutation, qualification or reservation release occurs.
The new archive and shim identities require fresh explicit enrollment approvals.
"""
import argparse
import copy
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import stat
import tarfile

BASE_SHA256 = "89e098b1f7749c515ed95263f081c469befb0aa10b49ee589ccb3e901090608a"
SHIM = "smolvm-1.34.0-linux-x86_64/containerd-shim-smolvm-v2"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1048576):
            digest.update(chunk)
    return digest.hexdigest()


def build(base, shim, expected_shim, source_revision, fix_revision, output):
    for path in (base, shim):
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode), "regular approved inputs required")
    require(sha(base) == BASE_SHA256, "original archive pin differs")
    require(
        re.fullmatch(r"[0-9a-f]{64}", expected_shim) and sha(shim) == expected_shim,
        "reviewed shim digest differs",
    )
    require(
        all(
            re.fullmatch(r"[0-9a-f]{40}", value)
            for value in (source_revision, fix_revision)
        ),
        "exact source and upstream-fix revisions required",
    )
    require(shim.stat().st_size <= 256 * 1024**2, "shim size bound")
    binary = shim.read_bytes()
    require(
        len(binary) >= 64
        and binary[:7] == b"\x7fELF\x02\x01\x01"
        and int.from_bytes(binary[16:18], "little") in (2, 3)
        and int.from_bytes(binary[18:20], "little") == 62,
        "Linux x86_64 executable required",
    )
    with tarfile.open(base, "r:gz") as source:
        members = source.getmembers()
        require(
            len(members) <= 4096
            and len({item.name for item in members}) == len(members)
            and sum(item.name == SHIM and item.isfile() for item in members) == 1,
            "complete unique original shim inventory required",
        )
        with output.open("xb") as destination:
            with gzip.GzipFile(
                filename="", fileobj=destination, mode="wb", mtime=0
            ) as compressed:
                with tarfile.open(
                    fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT
                ) as archive:
                    for original in members:
                        member = copy.copy(original)
                        if member.name == SHIM:
                            member.size = len(binary)
                            member.pax_headers = dict(original.pax_headers)
                            if "size" in member.pax_headers:
                                member.pax_headers["size"] = str(len(binary))
                            archive.addfile(member, io.BytesIO(binary))
                        else:
                            archive.addfile(
                                member,
                                (
                                    source.extractfile(original)
                                    if original.isfile()
                                    else None
                                ),
                            )
    output.chmod(0o600)
    return {
        "version": 1,
        "scope": "candidate_only_not_qualified",
        "runtime_version": "1.34.0",
        "base_archive_sha256": BASE_SHA256,
        "archive_sha256": sha(output),
        "shim_sha256": expected_shim,
        "source_revision": source_revision,
        "upstream_fix_revision": fix_revision,
        "replaced_members": [SHIM],
        "original_member_count": len(members),
        "other_member_content_and_metadata_preserved": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base", "shim", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--shim-sha256", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--upstream-fix-revision", required=True)
    options = parser.parse_args()
    report = build(
        options.base,
        options.shim,
        options.shim_sha256,
        options.source_revision,
        options.upstream_fix_revision,
        options.output,
    )
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
