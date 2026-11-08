"""Integrity checks for the offline SDK source used by native builds."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("bootstrap", Path(__file__).resolve().parents[1] / "bootstrap.py")
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOOTSTRAP)


class SourceIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cargo = self.root / "Cargo.toml"
        self.cargo.write_text('''[workspace.dependencies]
smolvm = { path = "target/upstream/smolvm", version = "=1.22.0" }
smolvm-pack = { path = "target/upstream/smolvm/crates/smolvm-pack", version = "=1.22.0" }
smolvm-protocol = { path = "target/upstream/smolvm/crates/smolvm-protocol", version = "=1.22.0" }
''')
        (self.root / "vendor").mkdir()
        self.archive = self.root / "vendor" / "source.tar.gz"
        self.make_archive("source.txt", b"original\n")
        self.manifest = {
            "schema": 2, "revision": "9f446ae00219148ca4a703914f44a8e2fab11655",
            "archive": self.archive.name, "archive_sha256": BOOTSTRAP.digest(self.archive),
            "patches": [], "inventory": "clean-inventory.json",
        }
        expected = {"source.txt": {"sha256": hashlib.sha256(b"original\n").hexdigest(), "executable": False}}
        inventory = self.root / "vendor" / self.manifest["inventory"]
        inventory.write_text(json.dumps(expected))
        self.manifest["inventory_sha256"] = BOOTSTRAP.digest(inventory)
        self.save_manifest()
        BOOTSTRAP.ROOT = self.root
        BOOTSTRAP.DESTINATION = self.root / "target" / "upstream" / "smolvm"

    def make_archive(self, name, data):
        with tarfile.open(self.archive, "w:gz") as stream:
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            stream.addfile(entry, io.BytesIO(data))

    def save_manifest(self):
        (self.root / "vendor" / "source.json").write_text(json.dumps(self.manifest))

    def test_clean_cache_is_separate_and_matches_all_upstream_bytes_and_modes(self):
        BOOTSTRAP.bootstrap()
        BOOTSTRAP.bootstrap(clean=True)
        clean = BOOTSTRAP.DESTINATION.with_name("smolvm-clean")
        self.assertEqual((BOOTSTRAP.DESTINATION / "source.txt").read_text(), "original\n")
        file = clean / "source.txt"
        self.assertEqual(file.read_text(), "original\n")
        BOOTSTRAP.bootstrap(clean=True, check=True)
        file.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "differs"):
            BOOTSTRAP.bootstrap(clean=True, check=True)
        BOOTSTRAP.bootstrap(clean=True)
        extra = clean / "unrecorded.txt"
        extra.write_text("extra")
        with self.assertRaisesRegex(ValueError, "differs"):
            BOOTSTRAP.bootstrap(clean=True, check=True)
        extra.unlink()
        file.write_text("modified source")
        with self.assertRaisesRegex(ValueError, "differs"):
            BOOTSTRAP.bootstrap(clean=True, check=True)

    def test_source_refuses_patch_configuration_and_inventory_substitution(self):
        self.manifest["patches"] = [{"path": "nonexistent.patch", "sha256": "0" * 64}]
        self.save_manifest()
        for clean in [False, True]:
            with self.assertRaisesRegex(ValueError, "cannot apply patches"):
                BOOTSTRAP.bootstrap(clean=clean)
        self.manifest["patches"] = []
        self.save_manifest()
        inventory = self.root / "vendor" / "clean-inventory.json"
        inventory.write_text("{}")
        with self.assertRaisesRegex(ValueError, "inventory checksum"):
            BOOTSTRAP.bootstrap()
        self.manifest["inventory_sha256"] = BOOTSTRAP.digest(inventory)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "archive differs"):
            BOOTSTRAP.bootstrap()

    def test_verified_source_and_cached_source_are_checked_by_content(self):
        original = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        BOOTSTRAP.bootstrap()
        file = BOOTSTRAP.DESTINATION / "source.txt"
        self.assertEqual(file.read_text(), "original\n")
        self.assertEqual(hashlib.sha256(self.archive.read_bytes()).hexdigest(), original)
        BOOTSTRAP.bootstrap(check=True)
        file.write_text("edited dependency\n")
        with self.assertRaisesRegex(ValueError, "differs"):
            BOOTSTRAP.bootstrap(check=True)
        BOOTSTRAP.bootstrap()
        self.assertEqual(file.read_text(), "original\n")

    def test_archive_tampering_cannot_replace_an_existing_source(self):
        BOOTSTRAP.bootstrap()
        file = BOOTSTRAP.DESTINATION / "source.txt"
        with self.archive.open("ab") as stream:
            stream.write(b"changed")
        with self.assertRaisesRegex(ValueError, "archive checksum"):
            BOOTSTRAP.bootstrap()
        self.assertEqual(file.read_text(), "original\n")

    def test_cargo_fork_overrides_and_dependency_substitution_are_rejected(self):
        original = self.cargo.read_text()
        self.cargo.write_text(original + '\n[patch.crates-io]\nsmolvm = { path = "fork" }\n')
        with self.assertRaisesRegex(ValueError, "overrides"):
            BOOTSTRAP.bootstrap()
        self.cargo.write_text(original.replace('target/upstream/smolvm"', 'fork"'))
        with self.assertRaisesRegex(ValueError, "source pin"):
            BOOTSTRAP.bootstrap()
        self.cargo.write_text(original)
        crate = self.root / "bridge"
        crate.mkdir()
        (crate / "Cargo.toml").write_text('[replace]\n"smolvm:1.22.0" = { path = "fork" }\n')
        with self.assertRaisesRegex(ValueError, "overrides"):
            BOOTSTRAP.bootstrap()
        (crate / "Cargo.toml").write_text('[dependencies]\nrenamed = { package = "smolvm", git = "https://example.invalid/fork" }\n')
        with self.assertRaisesRegex(ValueError, "bypasses"):
            BOOTSTRAP.bootstrap()

    def test_archive_traversal_is_rejected_before_extraction(self):
        self.make_archive("../outside.txt", b"must not escape")
        self.manifest["archive_sha256"] = BOOTSTRAP.digest(self.archive)
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "unsafe"):
            BOOTSTRAP.bootstrap()
        self.assertFalse((self.root / "target" / "upstream" / "outside.txt").exists())

    def test_symlink_destination_is_not_deleted_or_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("untouched")
        BOOTSTRAP.DESTINATION.parent.mkdir(parents=True)
        BOOTSTRAP.DESTINATION.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            BOOTSTRAP.bootstrap()
        self.assertEqual(sentinel.read_text(), "untouched")


if __name__ == "__main__":
    unittest.main()
