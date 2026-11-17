"""Manual passive-trace parser checks; no node or network observation is claimed."""

import hashlib
import json
import unittest

from fault_proxy import InputObservation, observed_uid


def frame(payload):
    mask = b"MASK"
    size = len(payload)
    prefix = (
        bytes([0x82, 0x80 | size])
        if size < 126
        else b"\x82\xfe" + size.to_bytes(2, "big")
    )
    return (
        prefix
        + mask
        + bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    )


def request(operation="exec", helper=b"reviewed-helper"):
    header = json.dumps(
        {
            "version": 1,
            "operation": operation,
            "argv": ["private-command"],
            "env": [["PRIVATE", "secret"]],
        }
    ).encode()
    return (
        b"SBP1"
        + len(helper).to_bytes(4, "big")
        + helper
        + b"SBK1"
        + len(header).to_bytes(4, "big")
        + header
    )


class InputObservationTest(unittest.TestCase):
    def test_only_canonical_pod_uids_can_enter_trace(self):
        uid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        self.assertEqual(observed_uid(uid), uid)
        for value in (None, {}, "private-command", "A" * 64, uid + "secret"):
            self.assertIsNone(observed_uid(value))

    def observer(self):
        return InputObservation(hashlib.sha256(b"reviewed-helper").hexdigest())

    def test_every_wire_split_retains_only_operation_and_discards_private_bytes(self):
        encoded = frame(b"\0" + request())
        for index in range(len(encoded) + 1):
            observer = self.observer()
            results = [observer.feed(encoded[:index]), observer.feed(encoded[index:])]
            self.assertEqual([value for value in results if value], ["exec"])
            self.assertTrue(observer.done)
            self.assertFalse(observer.failed)
            self.assertEqual(observer.wire, b"")
            self.assertEqual(observer.stream, b"")

    def test_input_spanning_many_sdk_frames_and_large_upload_is_counted_once(self):
        source = request("upload") + b"private-file" * 10000
        observer = self.observer()
        results = []
        for offset in range(0, len(source), 100):
            results.append(observer.feed(frame(b"\0" + source[offset : offset + 100])))
        self.assertEqual([value for value in results if value], ["upload"])
        self.assertFalse(observer.failed)
        self.assertEqual(observer.stream, b"")

    def test_download_is_distinct_from_application_execution(self):
        observer = self.observer()
        self.assertEqual(observer.feed(frame(b"\0" + request("download"))), "download")

    def test_unknown_helper_protocol_channel_and_operation_are_unclassified(self):
        for payload in (
            b"\0" + request(helper=b"foreign"),
            b"\0" + request("private-operation"),
            b"\1" + request(),
            b"\0invalid-envelope",
        ):
            observer = self.observer()
            self.assertIsNone(observer.feed(frame(payload)))
            self.assertTrue(observer.failed)
            self.assertEqual(observer.stream, b"")

    def test_control_and_wire_bounds_reject_without_retaining_partial_payload(self):
        for payload in (
            b"\x82\xff" + (65537).to_bytes(8, "big"),
            b"x" * 131073,
            frame(b"\0SBP1" + (65537).to_bytes(4, "big")),
        ):
            observer = self.observer()
            self.assertIsNone(observer.feed(payload))
            self.assertTrue(observer.failed)
            self.assertEqual(observer.wire, b"")
            self.assertEqual(observer.stream, b"")


if __name__ == "__main__":
    unittest.main()
