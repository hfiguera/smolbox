"""Manual, stdlib-only tests of the standalone node authority data contract."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test/fixtures/kubernetes/node-authority-v1"
SPEC = importlib.util.spec_from_file_location(
    "authority_contract", ROOT / "priv/kubernetes/node_authority/v1/authority_contract.py")
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


class AuthorityContractTest(unittest.TestCase):
    def setUp(self):
        self.vectors = json.loads((FIXTURES / "vectors.json").read_text())

    def test_canonical_generation_configuration_and_receipt_vectors(self):
        vectors = self.vectors
        for field in ("configuration", "identity_fields", "receipt"):
            canonical_key = "identity_canonical" if field == "identity_fields" else field + "_canonical"
            self.assertEqual(contract.canonical(vectors[field]).decode(), vectors[canonical_key])
        self.assertEqual(contract.generation(vectors["identity_fields"]), vectors["authority_generation"])
        self.assertEqual(contract.sha256(vectors["configuration"]), vectors["identity_fields"]["configuration_sha256"])
        self.assertEqual(contract.sha256(vectors["receipt"]), vectors["receipt_sha256"])
        for key in vectors["identity_fields"]:
            if key == "version":
                continue
            changed = copy.deepcopy(vectors["identity_fields"])
            changed[key] = "11111111-2222-4333-8444-555555555555" if key == "history_epoch" else "f" * 64
            self.assertNotEqual(contract.generation(changed), vectors["authority_generation"])

    def test_each_action_has_a_valid_success_and_rejection(self):
        for action in contract.ACTIONS:
            request = contract.request(self.vectors["requests"][action])
            for kind in ("successes", "rejections"):
                response = self.vectors[kind][action]
                self.assertEqual(contract.response(contract.decode(contract.canonical(response)), request), response)

    def test_schema_fields_match_executable_contract(self):
        schema = json.loads((FIXTURES / "protocol.schema.json").read_text())["$defs"]
        for name, keys in (("request", contract.REQUEST_KEYS), ("response", contract.RESPONSE_KEYS)):
            self.assertEqual(set(schema[name]["required"]), keys)
            self.assertEqual(set(schema[name]["properties"]), keys)
            self.assertFalse(schema[name]["additionalProperties"])
        config = json.loads((FIXTURES / "configuration.schema.json").read_text())
        self.assertEqual(set(config["required"]), set(self.vectors["configuration"]))
        for name, keys in (("binding", contract.BINDING_KEYS), ("receipt", contract.RECEIPT_KEYS),
                           ("observation", contract.OBSERVATION_KEYS), ("proof", contract.PROOF_KEYS)):
            self.assertEqual(set(schema[name]["required"]), keys)
            self.assertFalse(schema[name]["additionalProperties"])

    def test_no_duplicate_keys_compressed_frames_floats_or_unbounded_json(self):
        for raw in (b'{"version":1,"version":1}', b'{"value":NaN}', b'{"value":1.0}',
                    b'{"value":"\\u0000"}', b'{"value":"\\u00e9"}', b'[]',
                    b'[' * 25 + b'0' + b']' * 25, b'{}extra', b'x' * 65537):
            with self.assertRaises((ValueError, UnicodeError)):
                contract.decode(raw)

    def test_replay_and_cross_action_target_epoch_or_manifest_are_rejected(self):
        original = self.vectors["requests"]["capture"]
        for key in contract.IDENTITY_KEYS | {"nonce", "action"}:
            response = copy.deepcopy(self.vectors["successes"]["capture"])
            response[key] = "check" if key == "action" else "f" * 64
            with self.assertRaisesRegex(ValueError, "response identity"):
                contract.response(response, original)

    def test_rejections_cannot_smuggle_evidence_or_diagnostics(self):
        original = self.vectors["requests"]["check"]
        for key, replacement in (("error", "private node path /etc/token"), ("error", []),
                                 ("value", {}), ("journal", {}), ("extra", "value")):
            response = copy.deepcopy(self.vectors["rejections"]["check"])
            response[key] = replacement
            with self.assertRaises(ValueError):
                contract.response(response, original)

    def test_action_arguments_budget_and_receipt_digest_are_exact(self):
        for key, replacement in (("version", True), ("version", 2), ("action", []),
                                 ("action", "install"), ("timeout_ms", 30001),
                                 ("timeout_ms", True), ("max_response_bytes", 65545),
                                 ("arguments", {"path": "/private"}), ("extra", None)):
            request = copy.deepcopy(self.vectors["requests"]["check"])
            request[key] = replacement
            with self.assertRaises(ValueError):
                contract.request(request)
        for changed in ("receipt", "receipt_sha256"):
            request = copy.deepcopy(self.vectors["requests"]["cleanup"])
            if changed == "receipt":
                request["arguments"][changed]["pod_uid"] = "replacement"
            else:
                request["arguments"][changed] = "f" * 64
            with self.assertRaisesRegex(ValueError, "cleanup arguments"):
                contract.request(request)

    def test_callback_grants_include_response_frame_overhead(self):
        response = self.vectors["successes"]["capture"]
        request = copy.deepcopy(self.vectors["requests"]["capture"])
        size = len(contract.canonical(response)) + 8
        request["max_response_bytes"] = size
        self.assertEqual(contract.response(response, request), response)
        request["max_response_bytes"] -= 1
        with self.assertRaisesRegex(ValueError, "response budget"):
            contract.response(response, request)

    def test_receipts_cannot_downgrade_epoch_or_hide_untyped_identity(self):
        original = self.vectors["requests"]["cleanup"]
        for path, changed in ((["observation", "observer_epoch"], self.vectors["identity_fields"]["history_epoch"]),
                              (["phase"], "created"), (["image_id"], "other-image"),
                              (["observation", "pod_uid"], "11111111-2222-4333-8444-000000000000"),
                              (["observation", "processes", 0, "pid"], True),
                              (["binding", "generation"], "f" * 64), (["extra"], None)):
            request = copy.deepcopy(original)
            container = request["arguments"]["receipt"]
            for key in path[:-1]:
                container = container[key]
            container[path[-1]] = changed
            request["arguments"]["receipt_sha256"] = contract.sha256(request["arguments"]["receipt"])
            with self.assertRaises(ValueError):
                contract.request(request)

    def test_typed_success_cannot_weaken_cleanup_or_capture(self):
        for action, changes in (("cleanup", {"version": 2, "api_absent": False,
                                             "absent_shares": [], "terminated_processes": []}),
                                ("capture", {"complete_history": False, "sandbox_ids": [],
                                             "interfaces": [], "observer_epoch": "f" * 64})):
            for key, changed in changes.items():
                response = copy.deepcopy(self.vectors["successes"][action])
                response["value"][key] = changed
                with self.assertRaises(ValueError):
                    contract.response(response, self.vectors["requests"][action])


if __name__ == "__main__":
    unittest.main()
