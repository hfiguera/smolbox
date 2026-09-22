#!/usr/bin/env python3
"""Fault checks for evidence retained outside the disposable guest."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("capture_terminal", Path(__file__).with_name("capture-terminal.py"))
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class CaptureTest(unittest.TestCase):
    def run_capture(self, code, **options):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "receipt"
            status = CAPTURE.capture(destination, [sys.executable, "-c", code], **options)
            return status, (destination / "campaign.log").read_bytes(), json.loads((destination / "capture.json").read_text())

    def test_success_and_failure_keep_output_and_status(self):
        for exit_code in [0, 7]:
            status, output, receipt = self.run_capture(f"import os; os.write(1, b'phase evidence\\n'); os._exit({exit_code})")
            self.assertEqual(status, exit_code)
            self.assertEqual(output, b"phase evidence\n")
            self.assertEqual(receipt["exit_code"], exit_code)
            self.assertEqual(receipt["reason"], "completed")

    def test_output_limit_retains_prefix_and_fails(self):
        status, output, receipt = self.run_capture("import os; os.write(1, b'x' * 4096)", limit=1024)
        self.assertEqual(status, 1)
        self.assertEqual(output, b"x" * 1024)
        self.assertEqual(receipt["reason"], "capture_output_limit")

    def test_hung_capture_retains_output_and_fails(self):
        status, output, receipt = self.run_capture("import os,time; os.write(1,b'before hang'); time.sleep(60)", seconds=0.5)
        self.assertEqual(status, 1)
        self.assertEqual(output, b"before hang")
        self.assertEqual(receipt["reason"], "capture_timeout")


if __name__ == "__main__":
    unittest.main()
