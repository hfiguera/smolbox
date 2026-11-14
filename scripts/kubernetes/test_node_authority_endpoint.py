"""Manual pipe/socket framing checks; no installed SSH policy is claimed here."""

import copy
import json
from pathlib import Path
import socket
import struct
import sys
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv/kubernetes/node_authority/v1"))
import authority_contract as contract
import authority_endpoint as endpoint
from authority_runner import Runner

VECTORS = json.loads(
    (ROOT / "test/fixtures/kubernetes/node-authority-v1/vectors.json").read_text()
)


def frame(value):
    raw = contract.canonical(value)
    return contract.MAGIC + struct.pack(">I", len(raw)) + raw


class EndpointTest(unittest.TestCase):
    def exchange(
        self, raw, action="check", timeout_ms=1000, disconnected=False, observe=None
    ):
        client, server = socket.socketpair()
        client.settimeout(2)
        result, requests = [], []

        class Engine:
            ENROLLMENT = Path("/unused")
            binding = VECTORS["configuration"]["binding"]

            def __init__(self, config, runner):
                self.runner = runner

            def read_state(self, path):
                return {
                    "verifier_manifest_sha256": VECTORS["identity_fields"][
                        "verifier_manifest_sha256"
                    ]
                }

            def verify_enrollment(self, enrollment):
                return VECTORS["authority_generation"]

            def inspect(self, request):
                requests.append(request)
                if observe is not None:
                    observe(self.runner)
                expected = VECTORS["successes"][action]
                return {key: expected[key] for key in ("journal", "value")}

        def run():
            try:
                result.append(
                    endpoint.serve(
                        server.fileno(), server.fileno(), Runner(timeout_ms=timeout_ms)
                    )
                )
            finally:
                server.close()

        with patch.object(endpoint, "Verifier", Engine), patch.object(
            endpoint, "load_configuration", return_value=None
        ):
            worker = threading.Thread(target=run)
            worker.start()
            try:
                if raw:
                    client.sendall(raw)
                if disconnected:
                    client.shutdown(socket.SHUT_WR)
                chunks = []
                while True:
                    try:
                        chunk = client.recv(16384)
                    except ConnectionResetError:
                        break
                    if not chunk:
                        break
                    chunks.append(chunk)
                worker.join(timeout=2)
                self.assertFalse(worker.is_alive(), "endpoint failed to terminate")
                return b"".join(chunks), result, requests
            finally:
                client.close()
                worker.join(timeout=2)

    def test_each_action_projects_only_the_enrolled_original_arguments(self):
        for action in contract.ACTIONS:
            request = VECTORS["requests"][action]
            response, result, calls = self.exchange(frame(request), action=action)
            self.assertEqual(result, [0])
            self.assertEqual(response[:4], contract.MAGIC)
            size = struct.unpack(">I", response[4:8])[0]
            self.assertEqual(size, len(response) - 8)
            decoded = contract.decode(response[8:])
            contract.response(decoded, request)
            self.assertEqual(decoded, VECTORS["successes"][action])
            internal = {
                "version": 1,
                "action": action,
                "binding": VECTORS["configuration"]["binding"],
            }
            if action == "capture":
                internal["pod_uid"] = request["arguments"]["pod_uid"]
            elif action == "cleanup":
                internal["receipt"] = request["arguments"]["receipt"]
            self.assertEqual(calls, [internal])

    def test_wrong_approval_never_observes_and_only_returns_bounded_identity_error(
        self,
    ):
        for field in contract.IDENTITY_KEYS:
            request = copy.deepcopy(VECTORS["requests"]["check"])
            request[field] = "f" * 64
            raw, _, calls = self.exchange(frame(request))
            response = contract.response(contract.decode(raw[8:]), request)
            self.assertEqual(response["error"], "identity_conflict")
            self.assertEqual(calls, [])

    def test_tiny_and_exact_response_grants_never_enlarge_or_truncate_evidence(self):
        request = copy.deepcopy(VECTORS["requests"]["capture"])
        length = len(frame(VECTORS["successes"]["capture"]))
        request["max_response_bytes"] = length
        raw, result, _ = self.exchange(frame(request), action="capture")
        self.assertEqual(len(raw), length)
        self.assertEqual(result, [0])
        request["max_response_bytes"] -= 1
        raw, _, _ = self.exchange(frame(request), action="capture")
        response = contract.response(contract.decode(raw[8:]), request)
        self.assertEqual(response["error"], "output_limit")
        self.assertLessEqual(len(raw), request["max_response_bytes"])
        request["max_response_bytes"] = 9
        raw, _, _ = self.exchange(frame(request), action="capture")
        self.assertEqual(raw, b"")

    def test_short_extra_oversize_duplicate_or_unknown_input_produces_no_evidence(self):
        valid = frame(VECTORS["requests"]["check"])
        for raw in (
            b"SBA",
            b"BAD!" + valid[4:],
            contract.MAGIC + struct.pack(">I", 65537),
            contract.MAGIC + struct.pack(">I", 0),
            valid[:-1],
            valid + b"extra",
            contract.MAGIC + struct.pack(">I", 25) + b'{"version":1,"version":1}',
            frame({**VECTORS["requests"]["check"], "command": "install"}),
        ):
            response, _, calls = self.exchange(raw, disconnected=True)
            self.assertEqual(response, b"")
            self.assertEqual(calls, [])

    def test_partial_header_and_slow_observation_share_the_original_deadline(self):
        for raw, observe in (
            (b"SBA", None),
            (
                frame(VECTORS["requests"]["check"]),
                lambda runner: runner(
                    [sys.executable, "-c", "import time;time.sleep(30)"]
                ),
            ),
        ):
            started = time.monotonic()
            response, _, _ = self.exchange(raw, timeout_ms=40, observe=observe)
            self.assertEqual(response, b"")
            self.assertLess(time.monotonic() - started, 0.5)

    def test_observation_failures_never_return_raw_paths_diagnostics_or_partial_evidence(
        self,
    ):
        def fail(_):
            raise RuntimeError("private /etc/token secret stderr")

        request = VECTORS["requests"]["check"]
        raw, result, _ = self.exchange(frame(request), observe=fail)
        response = contract.response(contract.decode(raw[8:]), request)
        self.assertEqual(result, [1])
        self.assertEqual(response["error"], "unavailable")
        self.assertNotIn(b"secret", raw)
        self.assertIsNone(response["value"])


if __name__ == "__main__":
    unittest.main()
