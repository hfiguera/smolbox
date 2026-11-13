"""Offline checks of the evidence gate; no cluster, SSH, SDK or VM is started."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import smoke


class FakeKubernetes:
    def __init__(self, exit_code=7):
        self.exit_code = exit_code
        self.deleted = []

    def get(self, kind, _name, _namespace=None):
        if kind == "node":
            return {"metadata": {"labels": {"smolvm-runtime": "true"}}}
        if kind == "runtimeclass":
            return {"handler": "smolvm"}
        if kind == "pod":
            if any(path.endswith("/pods/smoke") for path, _ in self.deleted):
                return None
            return {"metadata": {"uid": "pod-uid"}, "status": {"containerStatuses": [
                {"restartCount": 0, "containerID": "containerd://original", "imageID": "image"}
            ]}}
        if kind == "namespace":
            return None
        raise AssertionError(kind)

    def create(self, document):
        uid = "namespace-uid" if document["kind"] == "Namespace" else "pod-uid"
        return {"metadata": {"uid": uid}}

    def command(self, *args, **_options):
        if args[0] == "wait":
            return subprocess.CompletedProcess(args, 0, b"ready", b"")
        if "uname" in args:
            return subprocess.CompletedProcess(args, 0, b"Linux guest-kernel\n", b"")
        if "-i" in args:
            return subprocess.CompletedProcess(args, self.exit_code, smoke.STDOUT,
                                               smoke.STDERR + b"command terminated with exit code 7\n")
        return subprocess.CompletedProcess(args, 0, smoke.PAYLOAD, b"")

    def delete_uid(self, path, uid):
        self.deleted.append((path, uid))


class EvidenceTest(unittest.TestCase):
    def run_smoke(self, kube, kvm=True):
        def immediate(_description, predicate, _timeout=120):
            value = predicate()
            smoke.require(value, "observation unavailable")
            return value

        processes = [{"pid": 123, "birth": "456", "descriptors": ["anon_inode:kvm-vm"]}]
        with patch.object(smoke, "inventory", return_value=[]), \
                patch.object(smoke, "entries", return_value=[]), \
                patch.object(smoke, "sandbox_id", return_value="sandbox-id"), \
                patch.object(Path, "read_text", return_value="sandbox-id"), \
                patch.object(smoke, "kvm_processes", return_value=processes if kvm else []), \
                patch.object(smoke, "birth", return_value=None), \
                patch.object(smoke, "wait_for", side_effect=immediate):
            return smoke.smoke(kube, {"image": "fixture"}, Path("/fixture"))

    def test_success_requires_binary_collection_nonzero_exit_and_owned_cleanup(self):
        kube = FakeKubernetes()
        report = self.run_smoke(kube)
        self.assertTrue(report["passed"])
        self.assertTrue(report["cleanup_verified"])
        self.assertEqual(report["execution"]["exit_code"], 7)
        self.assertEqual(report["execution"]["collected_bytes"], len(smoke.PAYLOAD))
        self.assertEqual([uid for _, uid in kube.deleted], ["pod-uid", "namespace-uid"])

    def test_transport_style_exit_255_fails_but_still_cleans_up(self):
        kube = FakeKubernetes(exit_code=255)
        report = self.run_smoke(kube)
        self.assertFalse(report["passed"])
        self.assertIn("expected workload exit 7", report["error"])
        self.assertTrue(report["cleanup_verified"])
        self.assertEqual(len(kube.deleted), 2)

    def test_missing_kvm_evidence_cannot_pass_as_an_ordinary_container(self):
        report = self.run_smoke(FakeKubernetes(), kvm=False)
        self.assertFalse(report["passed"])
        self.assertTrue(report["cleanup_verified"])
        self.assertNotIn("execution", report)

    def test_cleanup_failure_invalidates_successful_execution(self):
        kube = FakeKubernetes()
        kube.delete_uid = Mock(side_effect=RuntimeError("UID precondition failed"))
        report = self.run_smoke(kube)
        self.assertIn("execution", report)
        self.assertFalse(report["passed"])
        self.assertFalse(report["cleanup_verified"])
        self.assertIn("UID precondition failed", report["cleanup_error"])

    def test_lost_namespace_creation_response_cannot_claim_verified_cleanup(self):
        kube = FakeKubernetes()
        kube.create = Mock(side_effect=TimeoutError("create response lost"))
        report = self.run_smoke(kube)
        self.assertFalse(report["passed"])
        self.assertFalse(report["cleanup_verified"])
        self.assertIn("UID unavailable", report["cleanup_error"])
        self.assertEqual(kube.deleted, [])

    def test_binary_corruption_fails_collection(self):
        kube = FakeKubernetes()
        kube.command = Mock(side_effect=[
            subprocess.CompletedProcess([], 7, smoke.STDOUT,
                                        smoke.STDERR + b"command terminated with exit code 7\n"),
            subprocess.CompletedProcess([], 0, smoke.PAYLOAD[:-1], b"")
        ])
        with self.assertRaisesRegex(RuntimeError, "binary file differs"):
            smoke.execute_and_collect(kube, "fixture")

    def test_delete_uses_the_atomic_uid_precondition_without_force(self):
        kube = smoke.Kubernetes()
        kube.command = Mock()
        kube.delete_uid("/api/v1/namespaces/owned/pods/smoke", "original-uid")
        args, options = kube.command.call_args
        self.assertEqual(args, ("delete", "--raw=/api/v1/namespaces/owned/pods/smoke", "-f", "-"))
        body = json.loads(options["data"])
        self.assertEqual(body["preconditions"], {"uid": "original-uid"})
        self.assertGreater(body["gracePeriodSeconds"], 0)

    def test_length_delimited_input_finishes_without_closing_the_producer(self):
        command = [sys.executable, "-c",
                   "import sys; data=sys.stdin.buffer.read(4352); "
                   "sys.stdout.buffer.write(data); sys.exit(7)"]
        result = smoke.run(command, data=smoke.PAYLOAD, hold_stdin=True, check=False, timeout=2)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, smoke.PAYLOAD)

    def test_stalled_length_delimited_reader_is_bounded(self):
        command = [sys.executable, "-c", "import sys; sys.stdin.buffer.read(8192)"]
        with self.assertRaises(subprocess.TimeoutExpired):
            smoke.run(command, data=b"short", hold_stdin=True, timeout=0.1)

    def test_only_exact_empty_regular_operation_locks_are_exempt_from_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / ("." + "a" * 64 + ".fork-operation.lock")
            lock.touch()
            with patch.object(smoke, "VM_ROOT", root):
                self.assertEqual(smoke.entries(root), [])
                lock.write_bytes(b"unexpected material")
                self.assertEqual(smoke.entries(root), [lock.name])
                lock.unlink()
                (root / "leaked-vm").mkdir()
                lock.symlink_to(root / "leaked-vm")
                self.assertEqual(smoke.entries(root), sorted([lock.name, "leaked-vm"]))


if __name__ == "__main__":
    unittest.main()
