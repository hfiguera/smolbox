"""Manual candidate archive controls; synthetic inputs, no node access."""

import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).parent / "node-authority/candidate_runtime.py"
SPEC = importlib.util.spec_from_file_location("candidate_runtime", PATH)
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


class CandidateRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base = self.root / "original.tar.gz"
        self.shim = self.root / "shim"
        executable = bytearray(128)
        executable[:7] = b"\x7fELF\x02\x01\x01"
        executable[16:18] = (2).to_bytes(2, "little")
        executable[18:20] = (62).to_bytes(2, "little")
        self.shim.write_bytes(executable)
        with tarfile.open(self.base, "w:gz", format=tarfile.PAX_FORMAT) as archive:
            for name, data in [(tool.SHIM, b"old"), ("runtime/asset", b"original")]:
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode, entry.uid, entry.gid, entry.mtime = (
                    len(data),
                    0o755,
                    123,
                    456,
                    12,
                )
                if name == tool.SHIM:
                    entry.pax_headers = {"size": str(len(data))}
                archive.addfile(entry, io.BytesIO(data))
            link = tarfile.TarInfo("runtime/link")
            link.type, link.linkname = tarfile.SYMTYPE, "asset"
            archive.addfile(link)
        self.base_digest = hashlib.sha256(self.base.read_bytes()).hexdigest()

    def build(self, name="candidate.tar.gz", digest=None):
        with patch.object(tool, "BASE_SHA256", self.base_digest):
            return tool.build(
                self.base,
                self.shim,
                digest or tool.sha(self.shim),
                "1" * 40,
                "2" * 40,
                self.root / name,
            )

    def test_only_shim_content_changes_including_pax_size_and_all_other_assets(self):
        report = self.build()
        self.assertEqual(report["scope"], "candidate_only_not_qualified")
        with tarfile.open(self.base) as original, tarfile.open(
            self.root / "candidate.tar.gz"
        ) as candidate:
            self.assertEqual(original.getnames(), candidate.getnames())
            self.assertEqual(
                candidate.extractfile(tool.SHIM).read(), self.shim.read_bytes()
            )
            for entry in original.getmembers():
                copied = candidate.getmember(entry.name)
                for field in ("mode", "uid", "gid", "mtime", "type", "linkname"):
                    self.assertEqual(getattr(copied, field), getattr(entry, field))
                if entry.isfile() and entry.name != tool.SHIM:
                    self.assertEqual(
                        original.extractfile(entry).read(),
                        candidate.extractfile(copied).read(),
                    )

    def test_two_builds_are_identical_and_existing_output_is_never_replaced(self):
        first = self.build("one.tar.gz")
        second = self.build("two.tar.gz")
        self.assertEqual(first, second)
        self.assertEqual(
            (self.root / "one.tar.gz").read_bytes(),
            (self.root / "two.tar.gz").read_bytes(),
        )
        with self.assertRaises(FileExistsError):
            self.build("one.tar.gz")

    def test_unapproved_base_or_shim_creates_no_candidate(self):
        with self.assertRaisesRegex(ValueError, "archive pin"):
            tool.build(
                self.base,
                self.shim,
                tool.sha(self.shim),
                "1" * 40,
                "2" * 40,
                self.root / "candidate.tar.gz",
            )
        with self.assertRaisesRegex(ValueError, "shim digest"):
            self.build(digest="0" * 64)
        self.assertFalse((self.root / "candidate.tar.gz").exists())

    def test_other_architecture_or_symlink_input_cannot_be_approved_by_its_hash(self):
        executable = bytearray(self.shim.read_bytes())
        executable[18:20] = (183).to_bytes(2, "little")
        self.shim.write_bytes(executable)
        with self.assertRaisesRegex(ValueError, "x86_64"):
            self.build()
        saved = self.root / "saved"
        self.shim.rename(saved)
        self.shim.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, "regular"):
            self.build()


if __name__ == "__main__":
    unittest.main()
