"""Manual, local helper checks; never contacts a Kubernetes cluster."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / "priv/kubernetes/guest_helper_v1.py"
ACK = b"SBK1\x00\x00\x00\x00"


def frame(header):
    raw = json.dumps(header, ensure_ascii=False).encode()
    return b"SBK1" + struct.pack("!I", len(raw)) + raw


class GuestHelperTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="smolbox-helper-")
        self.addCleanup(self.workspace.cleanup)
        # Only the test process maps the qualified /workspace root to a local
        # temp directory. The shipped helper is run unchanged in its child.
        self.wrapper = (
            "import os,runpy; original=os.chdir; "
            "os.chdir=lambda value: original(os.environ['SMOLBOX_HELPER_TEST_DIR']) "
            "if value=='/workspace' else original(value); runpy.run_path(os.environ['SMOLBOX_HELPER_TEST_SOURCE'])"
        )

    def header(self, argv=None):
        return {"version": 1, "operation": "exec", "data_bytes": 0,
                "argv": argv or [sys.executable, "-c", "pass"], "env": [], "workdir": "/workspace"}

    def run_helper(self, payload, close=False, chunks=False):
        env = dict(os.environ, SMOLBOX_HELPER_TEST_DIR=self.workspace.name,
                   SMOLBOX_HELPER_TEST_SOURCE=str(HELPER))
        process = subprocess.Popen([sys.executable, "-I", "-S", "-u", "-c", self.wrapper],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            if chunks:
                for byte in payload:
                    process.stdin.write(bytes([byte]))
                    process.stdin.flush()
            else:
                process.stdin.write(payload)
                process.stdin.flush()
            if close:
                process.stdin.close()
            # Keep the producer open through exit, independently of the
            # application's /dev/null stdin. communicate() would close it.
            process.wait(timeout=5)
            return process.returncode, process.stdout.read(), process.stderr.read()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if not process.stdin.closed:
                process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def test_exact_argv_environment_binary_output_nonzero_and_application_eof(self):
        argument = "quotes ' \" ; $() ☃"
        value = "single ' double \" $()"
        program = ("import os,sys; assert sys.stdin.buffer.read()==b''; "
                   f"assert sys.argv[1]=={argument!r}; assert os.environ['VALUE']=={value!r}; "
                   "os.write(1,bytes([0,255,254])); os.write(2,bytes([128,0])); sys.exit(7)")
        header = self.header([sys.executable, "-c", program, argument])
        header["env"] = [["VALUE", value]]
        code, stdout, stderr = self.run_helper(frame(header), chunks=True)
        self.assertEqual((code, stdout, stderr), (7, ACK + bytes([0, 255, 254]), bytes([128, 0])))

    def test_silent_zero(self):
        self.assertEqual(self.run_helper(frame(self.header())), (0, ACK, b""))

    def test_missing_program_is_a_qualified_dispatch_attempt(self):
        code, stdout, stderr = self.run_helper(frame(self.header(["/missing/smolbox-program"])))
        self.assertEqual((code, stdout), (127, ACK))
        self.assertEqual(stderr, b"smolbox command could not execute\n")

    def test_bad_schema_and_values_fail_without_ack_or_echo(self):
        for changes in [{"version": 2}, {"data_bytes": 1}, {"extra": "private-value"},
                        {"argv": ["private\x00value"]}, {"workdir": "/workspace/../tmp"},
                        {"env": [["VALUE", "private-value"], ["VALUE", "duplicate"]]}]:
            with self.subTest(changes=changes):
                code, stdout, stderr = self.run_helper(frame(dict(self.header(), **changes)))
                self.assertEqual((code, stdout, stderr), (126, b"", b"smolbox helper request failed\n"))

    def test_short_header_wrong_magic_oversize_and_extra_data(self):
        valid = frame(self.header())
        for payload in [b"BAD!" + valid[4:], b"SBK1" + struct.pack("!I", 1048577), valid + b"excess"]:
            with self.subTest(payload=payload[:8]):
                code, stdout, _ = self.run_helper(payload)
                self.assertEqual((code, stdout), (126, b""))
        code, stdout, _ = self.run_helper(valid[:-3], close=True)
        self.assertEqual((code, stdout), (126, b""))


if __name__ == "__main__":
    unittest.main()
