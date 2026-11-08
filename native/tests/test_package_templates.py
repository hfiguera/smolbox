import importlib.util
from pathlib import Path
import shutil
import subprocess
import struct
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('smolbox_package', Path(__file__).resolve().parents[1] / 'package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


@unittest.skipUnless(shutil.which('zstd'), 'package build requires zstd')
class PackageTemplatesTests(unittest.TestCase):
    def test_compression_uses_the_resized_plain_bytes_and_preserves_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, target = root / 'template.ext4', root / 'template.ext4.zst'
            contents = b'owned fixture' + bytes(262144)
            source.write_bytes(contents)
            package.compress_template(source, target)
            result = subprocess.run([shutil.which('zstd'), '--quiet', '-d', '-c', str(target)],
                                    capture_output=True, check=True, timeout=15)
            self.assertEqual(result.stdout, contents)
            self.assertEqual(source.read_bytes(), contents)


class TemplatePreparationTests(unittest.TestCase):
    def fixture(self, root, blocks):
        path = root / 'owned.ext4'
        header = bytearray(2048)
        struct.pack_into('<H', header, 1024 + 56, 0xef53)
        struct.pack_into('<I', header, 1024 + 4, blocks)
        struct.pack_into('<I', header, 1024 + 24, 2)
        with path.open('wb') as file:
            file.write(header)
            file.truncate(package.TEMPLATE_BYTES)
        return path, bytes(header)

    def test_matching_baseline_preserves_bytes_without_resizing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, header = self.fixture(Path(temporary), 262144)
            with mock.patch.object(package.subprocess, 'run') as resize:
                package.prepare_owned_template(path, '/approved/resize2fs')
                resize.assert_not_called()
            with path.open('rb') as file:
                self.assertEqual(file.read(2048), header)
            self.assertTrue(package.template_at_baseline(path))

    def test_backing_length_alone_never_skips_required_filesystem_resize(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, _ = self.fixture(Path(temporary), 131072)
            self.assertFalse(package.template_at_baseline(path))
            with mock.patch.object(package.subprocess, 'run') as resize:
                with self.assertRaisesRegex(ValueError, 'geometry'):
                    package.prepare_owned_template(path, '/approved/resize2fs')
                resize.assert_called_once_with(
                    ['/approved/resize2fs', '-f', str(path), '1048576K'],
                    check=True, capture_output=True, timeout=120)

    def test_invalid_superblock_cannot_approve_a_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, _ = self.fixture(Path(temporary), 262144)
            with path.open('r+b') as file:
                file.seek(1024 + 56)
                file.write(b'\x00\x00')
            self.assertFalse(package.template_at_baseline(path))


if __name__ == '__main__':
    unittest.main()
