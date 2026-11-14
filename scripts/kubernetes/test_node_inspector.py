"""Manual offline evidence invariants; all node APIs/process views are fixtures."""

import copy
import tempfile
import threading
import time
from pathlib import Path
import unittest
from unittest.mock import patch

import node_inspector as inspector


SID = "a" * 64
OTHER = "b" * 64
UID = "11111111-2222-3333-4444-555555555555"
SHA = "c" * 64
EPOCH = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


class InspectorTest(unittest.TestCase):
    def setUp(self):
        inspector.DEADLINE = time.monotonic() + 30
        cri = patch.object(inspector, "cri", return_value=[])
        cri.start()
        self.addCleanup(cri.stop)
        for name, value in [("capture", None), ("cleanup", None), ("idle", True)]:
            lifecycle = patch.object(inspector.lifecycle, name, return_value=value)
            lifecycle.start()
            self.addCleanup(lifecycle.stop)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        for name in ["VM_ROOT", "SHARE_ROOT"]:
            value = root / name
            value.mkdir()
            patcher = patch.object(inspector, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.process = {"sandbox_id": SID, "vm_directory": "a" * 16, "pid": 123,
                        "start_ticks": 456, "exe_sha256": SHA, "kvm": inspector.KVM}
        self.binding = {"generation": SHA, "runtime_identity": {"shim_sha256": SHA,
                        "guard_sha256": SHA, "guard_template_sha256": SHA}}
        self.audit = {"attempts": {SID: {"inserts": 1, "processes": {(123, 456)}}}, "material": {SID: b"live"}}
        self.ledger = {"owners": {SID: UID}}
        self.enrollment = {"epoch": EPOCH}
        self.observation = {"observer_epoch": EPOCH, "complete_history": True,
                            "sandbox_ids": [SID], "processes": [self.process]}
        self.receipt = {"binding": self.binding, "observation": self.observation,
                        "pod_uid": UID, "pod_name": "original"}
        self.request = {"pod_uid": UID, "binding": self.binding, "receipt": self.receipt}

    def capture(self):
        return inspector.capture(self.request, self.enrollment, self.audit, self.ledger, True, [])

    def cleanup(self, sandboxes=None):
        return inspector.cleanup(self.request, self.enrollment, self.audit, self.ledger, True, sandboxes or [])

    def test_capture_requires_one_original_observed_kvm_incarnation(self):
        with patch.object(inspector, "physical", return_value=[self.process]), \
             patch.object(inspector, "isolation", return_value=[]):
            value = self.capture()
            self.assertTrue(value["complete_history"] and value["isolated"])
            self.assertEqual(value["processes"], [self.process])
            for change in [{"inserts": 2}, {"processes": {(124, 457)}}]:
                original = copy.deepcopy(self.audit)
                self.audit["attempts"][SID].update(change)
                with self.assertRaises(RuntimeError):
                    self.capture()
                self.audit = original

    def test_capture_rejects_unknown_extra_attempt_or_incomplete_history(self):
        with self.assertRaises(RuntimeError):
            inspector.capture(self.request, self.enrollment, self.audit, self.ledger, False, [])
        self.ledger["owners"][OTHER] = UID
        with self.assertRaises(RuntimeError):
            self.capture()

    def test_cleanup_checks_original_birth_and_scoped_absence(self):
        self.audit["material"] = {}
        with patch.object(inspector, "kube", return_value=None), \
             patch.object(inspector, "physical", return_value=[]), \
             patch.object(inspector, "birth", return_value=999):
            proof = self.cleanup()
            self.assertEqual(proof["terminated_processes"], [self.process])
            self.assertEqual(proof["absent_records"], [SID])
            with patch.object(inspector, "birth", return_value=456):
                with self.assertRaisesRegex(RuntimeError, "original process remains"):
                    self.cleanup()

    def test_api_replacement_or_absence_without_process_proof_cannot_release(self):
        self.audit["material"] = {}
        with patch.object(inspector, "kube", return_value={"metadata": {"uid": "replacement"}}):
            with self.assertRaisesRegex(RuntimeError, "Pod name still exists"):
                self.cleanup()
        with patch.object(inspector, "kube", return_value=None), \
             patch.object(inspector, "physical", return_value=[self.process]):
            with self.assertRaisesRegex(RuntimeError, "boot process remains"):
                self.cleanup()

    def test_leaked_scoped_records_directories_and_shares_are_preserved(self):
        with patch.object(inspector, "kube", return_value=None), \
             patch.object(inspector, "physical", return_value=[]), \
             patch.object(inspector, "birth", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "record/directory/share remains"):
                self.cleanup()
            self.audit["material"] = {}
            for path in [inspector.SHARE_ROOT / SID,
                         inspector.VM_ROOT / inspector.hashlib.sha256(SID.encode()).hexdigest()[:16]]:
                path.mkdir()
                with self.assertRaisesRegex(RuntimeError, "record/directory/share remains"):
                    self.cleanup()
                self.assertTrue(path.exists())
                path.rmdir()

    def test_cleanup_rejects_history_epoch_and_additional_process_attempts(self):
        self.audit["material"] = {}
        with patch.object(inspector, "kube", return_value=None), \
             patch.object(inspector, "physical", return_value=[]), \
             patch.object(inspector, "birth", return_value=None):
            self.audit["attempts"][SID]["processes"].add((124, 457))
            with self.assertRaisesRegex(RuntimeError, "process history changed"):
                self.cleanup()
            self.ledger["owners"][OTHER] = UID
            with self.assertRaisesRegex(RuntimeError, "sandbox history changed"):
                self.cleanup()
            self.enrollment["epoch"] = "changed"
            with self.assertRaisesRegex(RuntimeError, "authority gap"):
                self.cleanup()

    def test_cleanup_requires_original_cri_absence_even_after_api_and_vm_disappear(self):
        self.audit["material"] = {}
        sandbox = {"id": SID, "metadata": {"uid": UID, "namespace": "smolbox-preview"}}
        with patch.object(inspector, "kube", return_value=None), \
             patch.object(inspector, "physical", return_value=[]), \
             patch.object(inspector, "birth", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "original CRI sandbox remains"):
                self.cleanup([sandbox])
            with patch.object(inspector, "cri", return_value=[sandbox]):
                with self.assertRaisesRegex(RuntimeError, "appeared during cleanup"):
                    self.cleanup()
            self.assertEqual(self.cleanup()["version"], 3)

    def test_idle_does_not_hide_leftover_paths_cri_or_pending_pods(self):
        self.audit["material"] = {}
        with patch.object(inspector, "physical", return_value=[]), \
             patch.object(inspector, "kube", return_value={"items": []}):
            self.assertTrue(inspector.idle(self.audit, [], self.ledger))
            for root in [inspector.VM_ROOT, inspector.SHARE_ROOT]:
                path = root / "leftover"
                path.mkdir()
                self.assertFalse(inspector.idle(self.audit, [], self.ledger))
                path.rmdir()
            self.assertFalse(inspector.idle(self.audit, [{"metadata": {"namespace": "smolbox-preview"}}], self.ledger))
            with patch.object(inspector, "kube", return_value={"items": [{"metadata": {"name": "pending"}}]}):
                self.assertFalse(inspector.idle(self.audit, [], self.ledger))

    def test_lock_contention_waits_within_original_deadline_and_owner_loss_fails(self):
        path = Path(self.directory.name) / "lock"
        with path.open("a") as first, path.open("a") as second:
            inspector.fcntl.flock(first, inspector.fcntl.LOCK_EX)
            release = threading.Timer(0.03, lambda: inspector.fcntl.flock(first, inspector.fcntl.LOCK_UN))
            release.start()
            inspector.acquire(second)
            release.join()
            inspector.fcntl.flock(second, inspector.fcntl.LOCK_UN)
            inspector.fcntl.flock(first, inspector.fcntl.LOCK_EX)
            with patch.object(inspector, "DEADLINE", time.monotonic() + 0.02):
                with self.assertRaisesRegex(RuntimeError, "inspection deadline"):
                    inspector.acquire(second)
            with patch.object(inspector, "WATCH_INPUT", True), \
                 patch.object(inspector.selectors, "DefaultSelector") as selector:
                selector.return_value.__enter__.return_value.select.return_value = ["closed input"]
                with self.assertRaisesRegex(RuntimeError, "owner/input lost"):
                    inspector.acquire(second)

    def test_only_exact_empty_journal_bound_readiness_markers_are_runtime_bookkeeping(self):
        root = Path(self.directory.name) / "rootfs"
        root.mkdir()
        (root / "asset").write_bytes(b"immutable")
        original = inspector.qualified_rootfs(root, [])
        marker = root / (".smolvm-ready." + inspector.hashlib.sha256(SID.encode()).hexdigest()[:16])
        marker.touch()
        self.assertEqual(inspector.qualified_rootfs(root, [SID]), original)
        self.assertNotEqual(inspector.qualified_rootfs(root, []), original)
        marker.write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "readiness marker"):
            inspector.qualified_rootfs(root, [SID])
        marker.unlink()
        marker.symlink_to(root / "asset")
        with self.assertRaisesRegex(RuntimeError, "readiness marker"):
            inspector.qualified_rootfs(root, [SID])
        marker.unlink()
        marker.touch()
        (root / "asset").write_bytes(b"mutated")
        self.assertNotEqual(inspector.qualified_rootfs(root, [SID]), original)


if __name__ == "__main__":
    unittest.main()
