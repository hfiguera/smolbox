"""Manual qualification-tool checks; all node/privilege observations are fixtures."""

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "scripts/kubernetes/node-authority"
BUNDLE = ROOT / "priv/kubernetes/node_authority/v1"
sys.path.insert(0, str(BUNDLE))
import authority_contract as contract


def load(name):
    spec = importlib.util.spec_from_file_location(
        "qualification_test_" + name, TOOLS / (name + ".py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool, access, builder, campaign = (
    load("qualification"),
    load("access"),
    load("bundle"),
    load("campaign"),
)


class QualificationToolTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def rejection(self, body):
        shutil.copyfile(TOOLS / "negative_ssh.py", self.root / "negative_ssh.py")
        (self.root / "evidence-fault.json").write_text('{"mode":"unavailable"}')
        return subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(self.root / "negative_ssh.py")],
            input=body,
            capture_output=True,
            timeout=2,
        )

    def test_synthetic_outage_can_only_return_matched_negative_evidence(self):
        request = {
            "version": 1,
            "action": "cleanup",
            "nonce": "1" * 64,
            "binding_generation": "2" * 64,
            "authority_generation": "3" * 64,
            "verifier_manifest_sha256": "4" * 64,
            "max_response_bytes": 65_544,
        }
        body = json.dumps(request).encode()
        result = self.rejection(b"SBA1" + struct.pack(">I", len(body)) + body)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout[:4], b"SBA1")
        size = struct.unpack(">I", result.stdout[4:8])[0]
        self.assertEqual(size, len(result.stdout) - 8)
        response = json.loads(result.stdout[8:])
        self.assertFalse(response["ok"])
        self.assertIsNone(response["value"])
        self.assertIsNone(response["journal"])
        self.assertEqual(response["error"], "unavailable")
        for key in set(request) - {"max_response_bytes"}:
            self.assertEqual(response[key], request[key])

    def test_synthetic_outage_refuses_oversized_input_and_tiny_output_grant(self):
        result = self.rejection(b"SBA1" + struct.pack(">I", 65_537))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        request = dict(
            version=1,
            action="check",
            nonce="1" * 64,
            binding_generation="2" * 64,
            authority_generation="3" * 64,
            verifier_manifest_sha256="4" * 64,
            max_response_bytes=8,
        )
        body = json.dumps(request).encode()
        result = self.rejection(b"SBA1" + struct.pack(">I", len(body)) + body)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_bundle_reader_is_pure_and_keeps_complete_reviewed_inventory(self):
        archive = self.root / "authority.tar.gz"
        approved = builder.build(archive)
        before = set(self.root.iterdir())
        files, programs, manifest = access.read_bundle(
            archive, approved["archive_sha256"]
        )
        self.assertEqual(set(self.root.iterdir()), before)
        self.assertEqual(set(programs), set(approved["programs"]) | {"manifest.json"})
        self.assertEqual(len(files), 22)
        self.assertEqual(
            contract.sha256(manifest), approved["verifier_manifest_sha256"]
        )
        with self.assertRaisesRegex(RuntimeError, "checksum differs"):
            access.read_bundle(archive, "0" * 64)
        self.assertEqual(set(self.root.iterdir()), before)

    def test_administrator_writes_are_exclusive_and_never_replace_state(self):
        file = self.root / "record.json"
        tool.write(file, b"original")
        with self.assertRaises(FileExistsError):
            tool.write(file, b"replacement")
        self.assertEqual(file.read_bytes(), b"original")
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_campaign_requires_one_dispatch_original_uid_and_positive_release(self):
        uid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        trace = self.root / "trace.jsonl"
        events = [
            {"create": True},
            {"created_pod_uid": uid},
            {"exec_operation": "exec"},
            {"delete_precondition_uid": uid},
        ]
        report = {
            "pod_uid": uid,
            "cleanup": "complete",
            "cleanup_proof_version": 3,
            "usage": {"slots": 0},
        }

        def save(values):
            trace.write_text("".join(json.dumps(value) + "\n" for value in values))

        save(events)
        self.assertEqual(
            campaign.validate(trace, report, 1)["application_exec_requests"], 1
        )
        for changed in [
            events + [{"exec_operation": "exec"}],
            events + [{"exec_operation_unavailable": True}],
            events[:-1] + [{"delete_precondition_uid": "different"}],
        ]:
            save(changed)
            with self.assertRaises(RuntimeError):
                campaign.validate(trace, report, 1)
        save(events)
        for changed in [
            {**report, "cleanup_proof_version": 2},
            {**report, "usage": {"slots": 1}},
        ]:
            with self.assertRaises(RuntimeError):
                campaign.validate(trace, changed, 1)

    def test_stage_refuses_existing_domain_before_any_command(self):
        with patch.object(tool, "ROOT", self.root), patch.object(
            tool, "command"
        ) as command:
            with self.assertRaisesRegex(RuntimeError, "fresh uninitialized domain"):
                tool.stage(self.root / "missing", "0" * 64)
            command.assert_not_called()

    def test_physical_host_cannot_invoke_guest_preparation(self):
        with patch.object(tool.os, "geteuid", return_value=0), patch.object(
            tool.os, "uname"
        ) as uname, patch.object(tool, "command") as command:
            uname.return_value.nodename = "shared-physical-host"
            with self.assertRaisesRegex(RuntimeError, "dedicated root KVM guest"):
                tool.main()
            command.assert_not_called()

    def test_runtime_candidate_approval_does_not_bypass_fresh_domain_or_digest_checks(
        self,
    ):
        with patch.object(tool, "ROOT", self.root), patch.object(
            tool, "command"
        ) as command:
            with self.assertRaisesRegex(
                RuntimeError, "approved runtime archive digest"
            ):
                tool.stage(self.root / "missing", "0" * 64, "not-a-digest")
            with self.assertRaisesRegex(RuntimeError, "fresh uninitialized domain"):
                tool.stage(self.root / "missing", "0" * 64, "f" * 64)
            command.assert_not_called()

    def inputs(self):
        vectors = json.loads(
            (
                ROOT / "test/fixtures/kubernetes/node-authority-v1/vectors.json"
            ).read_bytes()
        )
        binding = vectors["configuration"]["binding"]
        (self.root / "bundle/programs").mkdir(parents=True)
        for name in ("source-basis-history.json", "source-basis-lifecycle.json"):
            shutil.copyfile(BUNDLE / name, self.root / "bundle/programs" / name)
        (self.root / "binding.json").write_bytes(contract.canonical(binding))
        metadata = {
            "cluster_anchor": {"metadata": {"uid": binding["cluster_anchor_uid"]}},
            "namespace": {"metadata": {"uid": binding["namespace_uid"]}},
            "node": {"metadata": {"uid": binding["node_uid"]}},
            "runtime_class": {"metadata": {"uid": binding["runtime_class_uid"]}},
            "node_boot_id": binding["node_boot_id"],
            "runtime_identity": binding["runtime_identity"],
        }
        (self.root / "metadata.json").write_bytes(contract.canonical(metadata))
        return binding, metadata

    def test_configuration_is_canonical_exclusive_and_preserves_sdk_binding(self):
        binding, _ = self.inputs()
        with patch.object(tool, "ROOT", self.root), patch.object(
            tool, "CONFIGURATION", self.root / "installed.json"
        ), patch.object(tool, "core", return_value=(None, contract)):
            tool.configuration()
            encoded = (self.root / "configuration.json").read_bytes()
            configuration = contract.decode(encoded)
            self.assertEqual(configuration["binding"], binding)
            self.assertEqual(contract.canonical(configuration), encoded)
            self.assertEqual(
                configuration["paths"]["runtime_archive"],
                str(self.root / "smolvm.tar.gz"),
            )
            self.assertEqual(
                configuration["paths"]["daemon_executable"],
                "/var/lib/rancher/k3s/data/current/bin/k3s",
            )
            with self.assertRaises(FileExistsError):
                tool.configuration()
            self.assertEqual((self.root / "configuration.json").read_bytes(), encoded)

    def test_mismatched_node_or_runtime_refuses_configuration(self):
        _, metadata = self.inputs()
        for key in ("node", "runtime_identity"):
            changed = copy.deepcopy(metadata)
            if key == "node":
                changed[key]["metadata"]["uid"] = "different-node"
            else:
                changed[key]["shim_sha256"] = "f" * 64
            (self.root / "metadata.json").write_bytes(contract.canonical(changed))
            with patch.object(tool, "ROOT", self.root), patch.object(
                tool, "CONFIGURATION", self.root / "installed.json"
            ), patch.object(tool, "core", return_value=(None, contract)):
                with self.assertRaisesRegex(RuntimeError, "differs from prepared node"):
                    tool.configuration()
            self.assertFalse((self.root / "configuration.json").exists())


if __name__ == "__main__":
    unittest.main()
