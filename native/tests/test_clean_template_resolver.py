"""Ordinary clean SDK resolver checks; temporary files only, no VM or domain."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid


@unittest.skipUnless(os.environ.get('SMOLBOX_CLEAN_TEMPLATE_RESOLVER'), 'requires built clean SDK fixture')
class CleanResolverTests(unittest.TestCase):
    def setUp(self):
        self.binary = Path(os.environ['SMOLBOX_CLEAN_TEMPLATE_RESOLVER']).resolve()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.account = self.home / '.smolvm'
        self.account.mkdir()
        self.name = 'smolbox-template-fixture-' + uuid.uuid4().hex
        self.plain = self.binary.parent / self.name
        self.compressed = self.binary.parent / (self.name + '.zst')
        for path in [self.plain, self.compressed]:
            self.addCleanup(path.unlink, missing_ok=True)
        self.environment = dict(os.environ, HOME=str(self.home))
        self.environment.pop('SMOLVM_TEMPLATE_DIR', None)

    def resolve(self):
        result = subprocess.run([str(self.binary), self.name], env=self.environment,
                                capture_output=True, check=True, timeout=15)
        return result.stdout.decode().strip()

    def compress(self, root, content):
        source = self.home / 'input'
        source.write_bytes(content)
        subprocess.run([shutil.which('zstd') or 'zstd', '--quiet', '-o',
                        str(root / (self.name + '.zst')), str(source)],
                       check=True, capture_output=True, timeout=15)

    def test_all_plain_candidates_precede_compressed_home_and_home_plain_wins(self):
        self.compress(self.account, b'home compressed')
        self.plain.write_bytes(b'executable plain')
        self.assertEqual(self.resolve(), str(self.plain))
        self.assertFalse((self.account / self.name).exists())
        (self.account / self.name).write_bytes(b'home plain')
        self.assertEqual(self.resolve(), str(self.account / self.name))

    def test_compressed_home_precedes_executable_and_normal_restart_reuses_plain(self):
        self.compress(self.account, b'home compressed')
        self.compress(self.binary.parent, b'executable compressed')
        selected = self.account / self.name
        self.assertEqual(self.resolve(), str(selected))
        self.assertEqual(selected.read_bytes(), b'home compressed')
        inode = selected.stat().st_ino
        self.assertEqual(self.resolve(), str(selected))
        self.assertEqual(selected.stat().st_ino, inode)
        self.assertFalse(self.plain.exists())

    def test_missing_asset_has_no_resolution_and_executable_compressed_can_expand(self):
        self.assertEqual(self.resolve(), '')
        self.compress(self.binary.parent, b'executable compressed')
        self.assertEqual(self.resolve(), str(self.plain))
        self.assertEqual(self.plain.read_bytes(), b'executable compressed')


if __name__ == '__main__':
    unittest.main()
