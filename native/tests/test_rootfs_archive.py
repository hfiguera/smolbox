"""Build-time guest archive fidelity and bounds; no runtime or VM dispatch."""
import importlib.util
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('smolbox_package', Path(__file__).resolve().parents[1] / 'package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
archive_builder = package.rootfs_archive


class RootfsArchiveTests(unittest.TestCase):
    def fixture(self, root):
        guest = root / 'agent-rootfs'
        (guest / 'usr/local/bin').mkdir(parents=True)
        (guest / 'empty').mkdir(mode=0o1777)
        agent = guest / 'usr/local/bin/smolvm-agent'
        agent.write_bytes(b'agent\x00\xff' * 30000)
        agent.chmod(0o755)
        (guest / 'init').symlink_to('/usr/local/bin/smolvm-agent')
        (guest / 'external').symlink_to('/this/host/path/must/not/be/opened')
        (guest / '.smolvm-ready.old').write_bytes(b'not guest init data')
        return guest

    def test_archive_is_reproducible_and_preserves_guest_files_modes_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            guest = self.fixture(root)
            first, second = root / 'one.tar', root / 'two.tar'
            archive_builder.create(guest, first)
            os.utime(guest / 'usr/local/bin/smolvm-agent', (1234567, 1234567))
            archive_builder.create(guest, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o400)
            self.assertEqual(first.stat().st_nlink, 1)
            with tarfile.open(first) as archive:
                names = archive.getnames()
                self.assertEqual(names, sorted(names))
                self.assertNotIn('.smolvm-ready.old', names)
                self.assertEqual(archive.extractfile('usr/local/bin/smolvm-agent').read(),
                                 (guest / 'usr/local/bin/smolvm-agent').read_bytes())
                self.assertEqual(archive.getmember('usr/local/bin/smolvm-agent').mode, 0o755)
                self.assertEqual(archive.getmember('empty').mode, stat.S_IMODE((guest / 'empty').stat().st_mode))
                self.assertTrue(archive.getmember('init').issym())
                self.assertEqual(archive.getmember('init').linkname, '/usr/local/bin/smolvm-agent')
                self.assertEqual(archive.getmember('external').linkname, '/this/host/path/must/not/be/opened')
                for entry in archive:
                    self.assertEqual((entry.uid, entry.gid, entry.mtime, entry.uname, entry.gname), (0, 0, 0, '', ''))
            self.assertEqual((guest / '.smolvm-ready.old').read_bytes(), b'not guest init data')

    def test_preexisting_output_limits_special_files_and_deadline_cannot_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            guest = self.fixture(root)
            output = root / 'agent.tar'
            output.write_bytes(b'keep')
            with self.assertRaises(FileExistsError):
                archive_builder.create(guest, output)
            self.assertEqual(output.read_bytes(), b'keep')
            output.unlink()
            with self.assertRaises(ValueError):
                archive_builder.create(guest, output, max_bytes=512)
            self.assertFalse(output.exists())
            with mock.patch.object(archive_builder, 'MAX_ENTRIES', 1):
                with self.assertRaisesRegex(ValueError, 'entries'):
                    archive_builder.create(guest, output)
            with mock.patch.object(archive_builder, 'SECONDS', 0):
                with self.assertRaisesRegex(ValueError, 'deadline'):
                    archive_builder.create(guest, output)
            os.mkfifo(guest / 'fifo')
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                archive_builder.create(guest, output)
            self.assertFalse(output.exists())
            self.assertEqual(list(root.glob('.rootfs-*')), [])

    def test_changed_input_model_never_publishes_and_output_cannot_enter_input_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            guest = self.fixture(root)
            output = root / 'agent.tar'
            actual = archive_builder.snapshot
            calls = []
            def changed(directory, deadline):
                value = actual(directory, deadline)
                calls.append(True)
                return value if len(calls) == 1 else ((0,), value[1])
            with mock.patch.object(archive_builder, 'snapshot', side_effect=changed):
                with self.assertRaisesRegex(ValueError, 'changed'):
                    archive_builder.create(guest, output)
            self.assertFalse(output.exists())
            with self.assertRaises(ValueError):
                archive_builder.create(guest, guest / 'output.tar')
            alias = root / 'alias'
            alias.symlink_to(guest, target_is_directory=True)
            with self.assertRaises(ValueError):
                archive_builder.create(alias, output)

    def test_inventory_hashes_tar_and_linux_firmware_alias_copies_bytes_without_linking(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            guest = self.fixture(root)
            libraries = root / 'lib'
            libraries.mkdir()
            (libraries / 'libkrunfw.so').write_bytes(b'approved firmware')
            with mock.patch.object(package.platform, 'system', return_value='Linux'):
                package.prepare_export_libraries(libraries)
            self.assertEqual((libraries / 'libkrunfw.so.5').read_bytes(), b'approved firmware')
            self.assertNotEqual((libraries / 'libkrunfw.so').stat().st_ino, (libraries / 'libkrunfw.so.5').stat().st_ino)
            (libraries / 'libkrunfw.so.5').write_bytes(b'explicit versioned asset')
            with mock.patch.object(package.platform, 'system', return_value='Linux'):
                package.prepare_export_libraries(libraries)
            self.assertEqual((libraries / 'libkrunfw.so.5').read_bytes(), b'explicit versioned asset')
            for name in ['storage-template.ext4', 'overlay-template.ext4', 'storage-template.ext4.zst', 'overlay-template.ext4.zst', *package.METADATA]:
                (root / name).write_bytes(b'fixture')
            self.assertNotIn('agent-rootfs.tar', {asset['path'] for asset in package.inventory(root)})
            archive_builder.create(guest, root / 'agent-rootfs.tar')
            entry = next(asset for asset in package.inventory(root) if asset['path'] == 'agent-rootfs.tar')
            self.assertEqual(entry['sha256'], package.digest(root / 'agent-rootfs.tar'))
            self.assertEqual(entry['bytes'], (root / 'agent-rootfs.tar').stat().st_size)
            self.assertEqual(entry['mode'], 0o400)


if __name__ == '__main__':
    unittest.main()
