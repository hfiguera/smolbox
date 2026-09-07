#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import unittest

from run_bounded import execute, exunit_summary


class BoundedRunnerTest(unittest.TestCase):
    def test_success_and_failure_have_payload_free_reports(self):
        data, report = execute([sys.executable, "-c", "print('private-payload'); raise SystemExit(7)"], 3, 1024)
        self.assertIn(b"private-payload", data)
        self.assertEqual(report["exit_code"], 7)
        self.assertNotIn("private-payload", str(report))

    def test_output_limit_stops_its_own_child(self):
        data, report = execute([sys.executable, "-c", "import os; os.write(1, b'x' * 1000000)"], 3, 1024)
        self.assertEqual(len(data), 1025)
        self.assertEqual(report["failure"], "output_limit")

    def test_deadline_reaps_owned_process_group(self):
        data, report = execute([sys.executable, "-u", "-c", "import os,time; print(os.getpid()); time.sleep(30)"], 1, 1024)
        pid = int(data.strip())
        self.assertEqual(report["failure"], "deadline")
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_evidence_rejects_zero_skipped_partial_and_wrong_suites(self):
        valid = b"Running ExUnit with seed: 123, max_cases: 16\nResult: 9 passed\n"
        self.assertEqual(exunit_summary(valid, 9), {"passed": 9, "seed": 123})
        with self.assertRaises(ValueError):
            exunit_summary(valid.replace(b"9 passed", b"0 passed"), 0)
        for invalid in [valid.replace(b"9 passed", b"0 passed"),
                        valid.replace(b"9 passed", b"8/9 passed"),
                        valid.replace(b"9 passed", b"9 passed, 1 excluded"),
                        valid + b"1 skipped\n", valid + valid, b"", b"command succeeded\n"]:
            with self.subTest(output=invalid):
                with self.assertRaises(ValueError):
                    exunit_summary(invalid, 9)

    def test_exited_leader_does_not_leave_a_child_holding_the_output_pipe(self):
        code = """
import os, signal, time
pid = os.fork()
if pid:
    print(pid, flush=True)
    os._exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(30)
"""
        data, report = execute([sys.executable, "-u", "-c", code], 1, 1024)
        pid = int(data.strip())
        self.assertEqual(report["failure"], "deadline")
        for _attempt in range(100):
            observed = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                      text=True, capture_output=True)
            if observed.returncode != 0 or observed.stdout.strip().startswith("Z"):
                break
            time.sleep(0.01)
        else:
            self.fail("owned child still running after its parent exited")


if __name__ == "__main__":
    unittest.main()
