#!/usr/bin/env python3
"""Build an offline, deterministic node-authority bundle; never contact a node."""
import argparse
import ast
import gzip
import hashlib
import io
import json
from pathlib import Path
import stat
import tarfile

ROOT = Path(__file__).resolve().parents[3]
PROGRAMS = ROOT / "priv/kubernetes/node_authority/v1"
PREFIX = "smolbox-node-authority-v1"


def canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def source_files():
    tree = ast.parse((PROGRAMS / "authority_assets.py").read_text())
    names = ast.literal_eval(
        next(
            node.value
            for node in tree.body
            if isinstance(node, ast.Assign)
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id == "PROGRAMS"
        )
    )
    if not isinstance(names, tuple) or len(set(names)) != len(names):
        raise ValueError("program inventory")
    values = {}
    for name in names:
        if Path(name).name != name or not name.endswith((".py", ".json", ".sh")):
            raise ValueError("program name")
        path = PROGRAMS / name
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o022:
            raise ValueError("unsafe source file")
        values[name] = path.read_bytes()
    return values


def build(output):
    programs = source_files()
    hashes = {
        name: hashlib.sha256(value).hexdigest() for name, value in programs.items()
    }
    manifest = {"version": 1, "files": hashes}
    programs["manifest.json"] = canonical(manifest)
    files = {"programs/" + name: value for name, value in programs.items()}
    for name in ("install.py", "access-policy.txt", "observer-rbac.yaml", "README.md"):
        files[name] = (Path(__file__).parent / name).read_bytes()
    files["configuration.schema.json"] = (
        ROOT / "test/fixtures/kubernetes/node-authority-v1/configuration.schema.json"
    ).read_bytes()
    package = {
        "version": 1,
        "files": {
            name: hashlib.sha256(value).hexdigest() for name, value in files.items()
        },
    }
    files["package-manifest.json"] = canonical(package)
    with Path(output).open("xb") as destination:
        with gzip.GzipFile(
            filename="", mode="wb", fileobj=destination, mtime=0
        ) as compressed:
            with tarfile.open(
                fileobj=compressed, mode="w|", format=tarfile.USTAR_FORMAT
            ) as archive:
                for name, content in sorted(files.items()):
                    entry = tarfile.TarInfo(PREFIX + "/" + name)
                    entry.size, entry.uid, entry.gid, entry.mtime = (
                        len(content),
                        0,
                        0,
                        0,
                    )
                    entry.mode = 0o755 if name.endswith(".sh") else 0o644
                    archive.addfile(entry, io.BytesIO(content))
    return {
        "version": 1,
        "verifier_manifest_sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
        "archive_sha256": hashlib.sha256(Path(output).read_bytes()).hexdigest(),
        "programs": hashes,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    print(json.dumps(build(arguments.output), sort_keys=True))
