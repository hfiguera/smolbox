"""Same-host takeover invariants; fixture PIDs and private temporary ledgers."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'priv/kubernetes/controller_guard_v1.py'
spec = importlib.util.spec_from_file_location('controller_guard', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
HOST = 'a' * 32
BOOT = '11111111-2222-3333-4444-555555555555'


class ControllerGuardTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.root.chmod(0o700)
        self.births = {101: 'birth-a', 202: 'birth-b'}
        self.identity = (HOST, BOOT)
        for name, callback in [('host', lambda: self.identity), ('process', lambda pid: self.births.get(pid))]:
            patched = patch.object(guard, name, side_effect=callback)
            patched.start()
            self.addCleanup(patched.stop)
        guard.DEADLINE = time.monotonic() + 3

    def request(self, owner='owner-a', pid=101, action='acquire', **fields):
        return {**{'version': 1, 'action': action, 'directory': str(self.root),
                   'binding_generation': 'b' * 64, 'owner': owner, 'pid': pid, 'timeout_ms': 3000}, **fields}

    def ledger(self):
        return json.loads((self.root / 'controller.json').read_text())

    def test_initial_acquire_stays_unenrolled_until_completed_scan_activation(self):
        first = guard.guard(self.request())
        self.assertFalse(first['enrolled'])
        self.assertEqual(first['known_owners'], ['owner-a'])
        self.assertEqual(guard.guard(self.request()), first)
        active = guard.guard(self.request(action='activate'))
        self.assertTrue(active['enrolled'])
        self.assertEqual(guard.guard(self.request(action='check')), active)

    def test_helper_exit_or_expired_store_lease_does_not_quiesce_live_controller(self):
        guard.guard(self.request())
        before = (self.root / 'controller.json').read_bytes()
        with self.assertRaises(ValueError):
            guard.guard(self.request('owner-b', 202))
        self.assertEqual((self.root / 'controller.json').read_bytes(), before)

    def test_positive_previous_process_death_retains_complete_owner_history(self):
        first = guard.guard(self.request())
        self.births.pop(101)
        second = guard.guard(self.request('owner-b', 202))
        self.assertEqual(second['domain_id'], first['domain_id'])
        self.assertEqual(second['known_owners'], ['owner-a', 'owner-b'])
        self.assertEqual(second['generation'], 2)
        self.assertFalse(second['enrolled'])

    def test_pid_reuse_and_host_reboot_require_original_birth_not_bare_pid(self):
        guard.guard(self.request())
        self.births[101] = 'reused-birth'
        guard.guard(self.request('owner-b', 202))
        self.identity = (HOST, '22222222-3333-4444-5555-666666666666')
        self.births[303] = 'birth-c'
        third = guard.guard(self.request('owner-c', 303))
        self.assertEqual(third['known_owners'], ['owner-a', 'owner-b', 'owner-c'])

    def test_different_host_or_binding_cannot_adopt_existing_authority(self):
        guard.guard(self.request())
        self.births.pop(101)
        for fields in [{'binding_generation': 'c' * 64}, {}]:
            self.identity = ('d' * 32, BOOT) if not fields else (HOST, BOOT)
            with self.assertRaises(ValueError):
                guard.guard(self.request('owner-b', 202, **fields))

    def test_missing_ledger_check_never_mints_authority_and_missing_lock_is_not_repaired(self):
        with self.assertRaises(FileNotFoundError):
            guard.guard(self.request(action='check'))
        self.assertFalse((self.root / 'controller.json').exists())
        guard.guard(self.request())
        (self.root / 'controller.lock').unlink()
        with self.assertRaises(FileNotFoundError):
            guard.guard(self.request())
        self.assertFalse((self.root / 'controller.lock').exists())

    def test_unknown_liveness_and_corrupt_symlink_or_hardlink_metadata_fail_closed(self):
        guard.guard(self.request())
        original = (self.root / 'controller.json').read_bytes()
        with patch.object(guard, 'process', side_effect=lambda pid: self.births[pid] if pid == 202 else (_ for _ in ()).throw(PermissionError())):
            with self.assertRaises(PermissionError):
                guard.guard(self.request('owner-b', 202))
        self.assertEqual((self.root / 'controller.json').read_bytes(), original)
        (self.root / 'copy').write_bytes(original)
        (self.root / 'controller.json').unlink()
        (self.root / 'controller.json').symlink_to(self.root / 'copy')
        with self.assertRaises(OSError):
            guard.guard(self.request(action='check'))
        (self.root / 'controller.json').unlink()
        os.link(self.root / 'copy', self.root / 'controller.json')
        with self.assertRaises(ValueError):
            guard.guard(self.request(action='check'))

    def test_owner_reuse_history_bounds_and_unsafe_directory_modes_reject(self):
        guard.guard(self.request())
        self.births.pop(101)
        guard.guard(self.request('owner-b', 202))
        self.births[303] = 'birth-c'
        with self.assertRaises(ValueError):
            guard.guard(self.request('owner-a', 303))
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            guard.guard(self.request('owner-c', 303))
        self.root.chmod(0o700)


if __name__ == '__main__':
    unittest.main()
