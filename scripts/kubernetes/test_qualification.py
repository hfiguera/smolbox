"""Manual offline regressions for Phase 0 evidence and isolation checks."""

import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import tarfile
import tempfile
import time
import unittest
from unittest.mock import Mock

import offline_guard
import qualify
from websocket_probe import Connection


def frame(opcode, payload=b"", final=True):
    first = opcode | (0x80 if final else 0)
    if len(payload) < 126:
        header = bytes([first, len(payload)])
    else:
        header = bytes([first, 126]) + struct.pack("!H", len(payload))
    return header + payload


class Socket:
    def __init__(self, wire):
        self.wire = wire
        self.sent = []

    def settimeout(self, _timeout):
        pass

    def recv(self, size):
        chunk, self.wire = self.wire[:min(size, 7)], self.wire[min(size, 7):]
        return chunk

    def sendall(self, wire):
        self.sent.append(wire)


class ProtocolTest(unittest.TestCase):
    def connection(self, wire):
        connection = Connection.__new__(Connection)
        connection.socket = Socket(wire)
        connection.pending = b""
        connection.deadline = time.monotonic() + 1
        return connection

    def test_fragmented_binary_channels_ping_and_real_nonzero_status(self):
        status = {"status": "Failure", "reason": "NonZeroExitCode",
                  "details": {"causes": [{"reason": "ExitCode", "message": "7"}]}}
        connection = self.connection(frame(2, b"\x01\x00\xff", False) + frame(9, b"ping") +
                                     frame(0, b"tail") + frame(2, b"\x02\xfe") +
                                     frame(2, b"\x03" + json.dumps(status).encode()) + frame(8))
        result = connection.collect()
        self.assertEqual(result["stdout"], b"\x00\xfftail")
        self.assertEqual(result["stderr"], b"\xfe")
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(connection.socket.sent[0][0], 0x8A)

    def test_silent_success_requires_success_status(self):
        result = self.connection(frame(2, b'\x03{"status":"Success"}') + frame(8)).collect()
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["stdout"], b"")
        with self.assertRaisesRegex(RuntimeError, "status required"):
            self.connection(frame(8)).collect()

    def test_connection_loss_after_output_does_not_fabricate_exit(self):
        with self.assertRaisesRegex(RuntimeError, "connection lost"):
            self.connection(frame(2, b"\x01partial")).collect()

    def test_oversized_frame_is_rejected_before_reading_body(self):
        with self.assertRaisesRegex(RuntimeError, "frame limit"):
            self.connection(bytes([0x82, 127]) + struct.pack("!Q", 1048577)).collect()

    def test_transport_status_is_not_a_workload_exit(self):
        with self.assertRaisesRegex(RuntimeError, "workload exit"):
            self.connection(frame(2, b'\x03{"status":"Failure","reason":"InternalError"}') + frame(8)).collect()

    def test_missing_or_conflicting_exit_cannot_pass(self):
        for causes in [[], [{"reason": "ExitCode", "message": "7"}, {"reason": "ExitCode", "message": "0"}]]:
            status = {"status": "Failure", "reason": "NonZeroExitCode", "details": {"causes": causes}}
            with self.assertRaisesRegex(RuntimeError, "one exit code"):
                self.connection(frame(2, b"\x03" + json.dumps(status).encode()) + frame(8)).collect()


def guard_table():
    objects = [{"table": {"name": offline_guard.TABLE, "family": "bridge", "comment": offline_guard.MARKER}},
               {"set": {"name": "isolated_ports", "type": "ifname", "elem": ["veth1234"]}}]
    for name, hook, key in [("from_pod", "prerouting", "iifname"), ("to_pod", "postrouting", "oifname")]:
        objects.append({"chain": {"name": name, "hook": hook, "prio": -300, "type": "filter", "policy": "accept"}})
        objects.append({"rule": {"chain": name, "expr": [
            {"match": {"op": "==", "left": {"meta": {"key": key}}, "right": "@isolated_ports"}},
            {"counter": {"packets": 12, "bytes": 1024}}, {"drop": None}]}})
    return {"nftables": objects}


class PolicyTest(unittest.TestCase):
    def test_guard_requires_both_drop_hooks_and_real_ports(self):
        original = guard_table()
        self.assertEqual(offline_guard.rules(original), ["veth1234"])
        changed = copy.deepcopy(original)
        changed["nftables"][-1]["rule"]["expr"][-1] = {"accept": None}
        with self.assertRaisesRegex(RuntimeError, "rule changed"):
            offline_guard.rules(changed)
        changed = copy.deepcopy(original)
        changed["nftables"][1]["set"]["elem"] = ["enp0s1"]
        with self.assertRaisesRegex(RuntimeError, "port"):
            offline_guard.rules(changed)

    def test_foreign_guard_table_is_never_adopted(self):
        changed = guard_table()
        changed["nftables"][0]["table"]["comment"] = "another owner"
        with self.assertRaisesRegex(RuntimeError, "unowned"):
            offline_guard.rules(changed)

    def test_api_omitted_empty_rules_do_not_enable_policy_mutation(self):
        kube = Mock()
        original = {"metadata": {"labels": {"app.kubernetes.io/managed-by": qualify.MANAGER}},
                    "spec": {"podSelector": {}, "policyTypes": ["Ingress", "Egress"]}}
        kube.get.return_value = original
        document = {**original, "spec": {**original["spec"], "ingress": [], "egress": []}}
        self.assertIs(qualify.owned_object(kube, "networkpolicy", "offline", document), original)
        kube.create.assert_not_called()
        original["spec"]["egress"] = [{}]
        with self.assertRaisesRegex(RuntimeError, "policy differs"):
            qualify.owned_object(kube, "networkpolicy", "offline", document)
        kube.create.assert_not_called()


class ArtifactTest(unittest.TestCase):
    def test_pinned_archive_rootfs_manifest_matches_installed_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary) / "runtime"
            rootfs = runtime / "agent-rootfs"
            rootfs.mkdir(parents=True)
            (rootfs / "test").write_bytes(b"rootfs bytes")
            (rootfs / "link").symlink_to("test")
            (rootfs / "a").mkdir()
            (rootfs / "a/nested").write_bytes(b"nested")
            (rootfs / "a.conf").write_bytes(b"full path ordering differs from Path component ordering")
            archive = Path(temporary) / "archive.tar.gz"
            with tarfile.open(archive, "w:gz") as target:
                target.add(runtime, arcname=runtime.name)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            _, manifest = qualify.archive_identity(archive, runtime, digest)
            self.assertEqual(manifest, qualify.rootfs_digest(rootfs))
            (rootfs / "test").write_bytes(b"tampered")
            self.assertNotEqual(manifest, qualify.rootfs_digest(rootfs))
            with self.assertRaisesRegex(RuntimeError, "archive differs"):
                qualify.archive_identity(archive, runtime, "0" * 64)

    def test_escaping_archive_layout_is_rejected_without_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "archive.tar.gz"
            with tarfile.open(archive, "w:gz") as target:
                member = tarfile.TarInfo("../escape")
                member.size = 4
                target.addfile(member, io.BytesIO(b"data"))
            with self.assertRaisesRegex(RuntimeError, "layout"):
                qualify.archive_identity(archive, Path("/runtime"), hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertFalse((Path(temporary) / "escape").exists())


if __name__ == "__main__":
    unittest.main()
