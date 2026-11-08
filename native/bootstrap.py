#!/usr/bin/env python3
"""Verify and materialize pinned SDK inputs; never edit research input."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parent
DESTINATION = ROOT / "target" / "upstream" / "smolvm"


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(root: Path) -> dict[str, str]:
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError("unexpected native source symlink")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def clean_inventory(root: Path) -> dict[str, dict]:
    return {
        name: {"sha256": sha256, "executable": bool((root / name).stat().st_mode & 0o111)}
        for name, sha256 in inventory(root).items()
    }


def verify_dependency_configuration() -> None:
    """Native crates may not replace the verified SDK with a Cargo fork."""
    paths = [ROOT / "Cargo.toml", *ROOT.glob("*/Cargo.toml"),
             *ROOT.glob("tests/*/Cargo.toml")]
    sdk_names = {"smolvm", "smolvm-pack", "smolvm-protocol"}

    def verify_tables(value: dict, manifest_path: Path) -> None:
        for key, table in value.items():
            if not isinstance(table, dict):
                continue
            if key in {"dependencies", "dev-dependencies", "build-dependencies"}:
                for name, dependency in table.items():
                    package = dependency.get("package", name) if isinstance(dependency, dict) else name
                    if package not in sdk_names:
                        continue
                    if dependency == {"workspace": True}:
                        continue
                    suffix = "" if package == "smolvm" else f"/crates/{package}"
                    allowed = ROOT / f"target/upstream/smolvm-clean{suffix}"
                    if (manifest_path.parent != ROOT / "tests/clean-sdk-api"
                            or not isinstance(dependency, dict)
                            or set(dependency) != {"path", "version"}
                            or dependency["version"] != "=1.22.0"
                            or (manifest_path.parent / dependency["path"]).resolve() != allowed.resolve()):
                        raise ValueError("native SDK dependency bypasses verified workspace source")
            else:
                verify_tables(table, manifest_path)

    for path in paths:
        manifest = tomllib.loads(path.read_text())
        if "patch" in manifest or "replace" in manifest:
            raise ValueError("native Cargo dependency overrides are unsupported")
        if path != ROOT / "Cargo.toml":
            verify_tables(manifest, path)
    manifest = tomllib.loads((ROOT / "Cargo.toml").read_text())
    dependencies = manifest["workspace"]["dependencies"]
    for name, path in {
        "smolvm": "target/upstream/smolvm",
        "smolvm-pack": "target/upstream/smolvm/crates/smolvm-pack",
        "smolvm-protocol": "target/upstream/smolvm/crates/smolvm-protocol",
    }.items():
        if dependencies.get(name) != {"path": path, "version": "=1.22.0"}:
            raise ValueError("native SDK dependency differs from verified source pin")


def bootstrap(check: bool = False, clean: bool = False) -> None:
    source = json.loads((ROOT / "vendor" / "source.json").read_text())
    if source["schema"] != 2 or source["revision"] != "9f446ae00219148ca4a703914f44a8e2fab11655":
        raise ValueError("unsupported native source pin")
    destination = DESTINATION.with_name("smolvm-clean") if clean else DESTINATION
    if source["patches"] != []:
        raise ValueError("clean native source cannot apply patches")
    verify_dependency_configuration()
    archive = ROOT / "vendor" / source["archive"]
    if digest(archive) != source["archive_sha256"]:
        raise ValueError("native source archive checksum mismatch")
    # Regenerate the expected source in an owned staging directory every time.
    # A marker alone cannot authorize an edited cached dependency.
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="smolbox-source-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "source"
        staged.mkdir()
        with tarfile.open(archive, "r:gz") as stream:
            for member in stream.getmembers():
                name = PurePosixPath(member.name)
                if name.is_absolute() or ".." in name.parts or not (member.isfile() or member.isdir()):
                    raise ValueError("unsafe native source archive member")
            stream.extractall(staged, filter="data")
        expected_path = ROOT / "vendor" / source["inventory"]
        if digest(expected_path) != source["inventory_sha256"]:
            raise ValueError("clean native source inventory checksum mismatch")
        expected = json.loads(expected_path.read_text())
        if clean_inventory(staged) != expected:
            raise ValueError("archive differs from clean upstream inventory")
        if destination.is_symlink():
            raise ValueError("native source destination is a symlink")
        if destination.exists() and clean_inventory(destination) == expected:
            print("Verified unmodified native source.")
            return
        if check:
            raise ValueError("native dependency is absent or differs from the verified source")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(staged), destination)
        print("Materialized unmodified native source.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify an existing tree without replacing it")
    parser.add_argument("--clean", action="store_true", help="use the independent API/resolver fixture cache")
    args = parser.parse_args()
    bootstrap(args.check, args.clean)
