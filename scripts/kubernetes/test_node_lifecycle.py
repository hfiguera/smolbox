"""Offline lifecycle witnesses; no real cgroups or daemon operations."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import node_lifecycle as lifecycle

UID = '11111111-2222-3333-4444-555555555555'


class LifecycleTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.mount = {'id': 33, 'device': root.stat().st_dev, 'inode': root.stat().st_ino}
        self.state = {'mount': self.mount, 'daemons': [{'pid': 10, 'start_ticks': 100}]}
        self.enrollment = {'lifecycle': copy.deepcopy(self.state)}
        self.ledger = {'lifecycles': {}}
        for target, value in [('ROOT', root)]:
            item = patch.object(lifecycle, target, value)
            item.start()
            self.addCleanup(item.stop)
        item = patch.object(lifecycle, 'current', side_effect=lambda *_: copy.deepcopy(self.state))
        item.start()
        self.addCleanup(item.stop)
        (root / 'kubepods.slice').mkdir()
        self.path = lifecycle.path(UID)
        self.path.mkdir()
        self.args = (lambda *_: None, lambda *_: None, lambda: None)

    def capture(self):
        lifecycle.capture(self.enrollment, self.ledger, UID, *self.args)

    def cleanup(self):
        lifecycle.cleanup(self.enrollment, self.ledger, UID, *self.args)

    def process_fixture(self):
        proc = Path(self.directory.name) / 'proc'
        proc.mkdir()
        executable = Path(self.directory.name) / 'k3s'
        executable.write_bytes(b'approved executable')
        for pid, parent, comm in [(10, 1, 'k3s-server'), (11, 10, 'containerd')]:
            entry = proc / str(pid)
            entry.mkdir()
            (entry / 'comm').write_text(comm)
            fields = ['S', str(parent)] + ['0'] * 17 + [str(pid * 100)]
            (entry / 'stat').write_text(str(pid) + ' (' + comm + ') ' + ' '.join(fields))
            (entry / 'exe').symlink_to(executable)
        return proc, executable

    def test_daemon_identity_binds_single_parent_child_births_to_one_image(self):
        proc, executable = self.process_fixture()
        with patch.object(lifecycle, 'PROC', proc), patch.object(lifecycle, 'K3S', executable):
            values = lifecycle.daemons(lambda _: b'10', lambda _: 'a' * 64, lambda: None)
            self.assertEqual([(v['pid'], v['start_ticks']) for v in values], [(10, 1000), (11, 1100)])
            wrong = ['S', '99'] + ['0'] * 17 + ['1100']
            (proc / '11/stat').write_text('11 (containerd) ' + ' '.join(wrong))
            with self.assertRaisesRegex(RuntimeError, 'containerd parent changed'):
                lifecycle.daemons(lambda _: b'10', lambda _: 'a' * 64, lambda: None)

    def test_mount_type_and_unreadable_daemon_state_are_not_absence(self):
        proc, executable = self.process_fixture()
        (proc / 'self').mkdir()
        mountinfo = proc / 'self/mountinfo'
        mountinfo.write_text('33 1 0:1 / ' + str(lifecycle.ROOT) + ' rw - cgroup2 cgroup rw\n')
        with patch.object(lifecycle, 'PROC', proc), patch.object(lifecycle, 'K3S', executable):
            self.assertEqual(lifecycle.mount()['id'], 33)
            mountinfo.write_text(mountinfo.read_text().replace('cgroup2', 'tmpfs'))
            with self.assertRaisesRegex(RuntimeError, 'cgroup2 mount unavailable'):
                lifecycle.mount()
            (proc / '10/stat').write_text('corrupt')
            with self.assertRaises((ValueError, IndexError)):
                lifecycle.daemons(lambda _: b'10', lambda _: 'a' * 64, lambda: None)

    def test_original_witness_is_required_then_absence_is_proven_without_deletion(self):
        with self.assertRaisesRegex(RuntimeError, 'witness missing'):
            self.cleanup()
        self.capture()
        first = copy.deepcopy(self.ledger)
        self.capture()
        self.assertEqual(self.ledger, first)
        with self.assertRaisesRegex(RuntimeError, 'work/cgroup remains'):
            self.cleanup()
        self.assertTrue(self.path.exists())
        self.assertFalse(lifecycle.idle(self.ledger))
        self.path.rmdir()
        self.cleanup()
        self.assertTrue(lifecycle.idle(self.ledger))
        self.assertEqual(self.ledger, first)

    def test_replaced_symlink_and_non_directory_cgroups_fail_closed(self):
        self.capture()
        self.path.rename(self.path.with_name('old'))
        self.path.mkdir()
        with self.assertRaisesRegex(RuntimeError, 'cgroup replaced'):
            self.capture()
        self.path.rmdir()
        self.path.symlink_to(self.path.with_name('old'))
        with self.assertRaises(OSError):
            self.capture()
        self.path.unlink()
        self.path.write_text('not a cgroup')
        with self.assertRaises(OSError):
            self.capture()

    def test_daemon_restart_or_mount_change_blocks_capture_and_cleanup(self):
        self.capture()
        self.path.rmdir()
        for changed in [{'mount': {**self.mount, 'id': 34}}, {'daemons': [{'pid': 10, 'start_ticks': 101}]}]:
            original = copy.deepcopy(self.state)
            self.state.update(changed)
            with self.assertRaisesRegex(RuntimeError, 'lifecycle epoch changed'):
                self.cleanup()
            with self.assertRaisesRegex(RuntimeError, 'lifecycle epoch changed'):
                self.capture()
            self.state = original

    def test_unknown_ledger_corrupt_witness_and_invalid_uid_are_not_absence(self):
        self.ledger = {}
        with self.assertRaisesRegex(RuntimeError, 'ledger unavailable'):
            self.cleanup()
        self.ledger = {'lifecycles': {UID: {'inode': 0, 'device': 1, 'mount_id': 33}}}
        with self.assertRaisesRegex(RuntimeError, 'witness corrupt'):
            self.cleanup()
        for value in ['../../other', 'pod-original', UID + '/child']:
            with self.assertRaisesRegex(RuntimeError, 'unsupported lifecycle Pod UID'):
                lifecycle.path(value)


if __name__ == '__main__':
    unittest.main()
