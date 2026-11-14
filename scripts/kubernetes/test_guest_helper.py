"""Manual, local helper checks; never contacts a Kubernetes cluster."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
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
            "import os,runpy; original=os.chdir; original_open=os.open; "
            "os.open=lambda path,flags,*a,**kw: original_open(os.environ['SMOLBOX_HELPER_TEST_DIR'] "
            "if path=='/workspace' else path,flags,*a,**kw); "
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
        writer = process.stdin
        def produce():
            try:
                if chunks:
                    for byte in payload:
                        writer.write(bytes([byte]))
                        writer.flush()
                else:
                    writer.write(payload)
                    writer.flush()
                if close:
                    writer.close()
            except OSError:
                pass
        producer = threading.Thread(target=produce)
        producer.start()
        process.stdin = None  # communicate drains output without closing producer
        try:
            stdout, stderr = process.communicate(timeout=5)
            producer.join(timeout=1)
            return process.returncode, stdout, stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            producer.join(timeout=1)
            if not writer.closed:
                writer.close()
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

    def file_header(self, operation, path="/workspace/nested/data", data=b"", max_bytes=1048576):
        value = {"version": 1, "operation": operation, "path": path,
                 "data_bytes": len(data) if operation == "upload" else 0, "timeout_ms": 1000}
        value.update({"sha256": hashlib.sha256(data).hexdigest()} if operation == "upload" else {"max_bytes": max_bytes})
        return value

    def reply(self, result):
        code, stdout, stderr = result
        self.assertEqual((code, stderr), (0, b""))
        self.assertTrue(stdout.startswith(ACK + b"SBF1"))
        size = struct.unpack("!I", stdout[12:16])[0]
        return json.loads(stdout[16:16+size]), stdout[16+size:]

    def test_binary_empty_and_one_mib_files_roundtrip_without_stdin_eof(self):
        for data in [b"", bytes(range(256)), bytes(range(256)) * 4096]:
            with self.subTest(size=len(data)):
                header = self.file_header("upload", data=data)
                metadata, body = self.reply(self.run_helper(frame(header) + data))
                self.assertEqual((metadata["size"], metadata["sha256"], body), (len(data), hashlib.sha256(data).hexdigest(), b""))
                self.assertEqual((Path(self.workspace.name)/"nested/data").read_bytes(), data)
                metadata, received = self.reply(self.run_helper(frame(self.file_header("download"))))
                self.assertEqual(received, data)
                self.assertEqual(metadata["sha256"], hashlib.sha256(received).hexdigest())

    def test_upload_atomic_replace_and_failed_digest_preserves_original(self):
        path = Path(self.workspace.name)/"data"
        path.write_bytes(b"original")
        header = self.file_header("upload", "/workspace/data", b"replacement")
        before = path.stat().st_ino
        self.reply(self.run_helper(frame(header) + b"replacement"))
        self.assertNotEqual(path.stat().st_ino, before)
        header["sha256"] = "0" * 64
        self.assertEqual(self.run_helper(frame(header) + b"replacement")[:2], (126, b""))
        self.assertEqual(path.read_bytes(), b"replacement")
        self.assertEqual(list(Path(self.workspace.name).rglob(".smolbox-upload-*")), [])

    def test_short_extra_and_timed_out_uploads_do_not_publish_or_leak_temp(self):
        header = self.file_header("upload", data=b"four")
        for payload, close in [(frame(header) + b"fo", True), (frame(header) + b"fourEXTRA", False)]:
            self.assertEqual(self.run_helper(payload, close=close)[:2], (126, b""))
        header["timeout_ms"] = 30
        self.assertEqual(self.run_helper(frame(header) + b"fo")[:2], (126, b""))
        self.assertFalse((Path(self.workspace.name)/"nested/data").exists())
        self.assertEqual(list(Path(self.workspace.name).rglob(".smolbox-upload-*")), [])

    def test_file_paths_cannot_escape_or_follow_symlinks_or_special_files(self):
        root = Path(self.workspace.name)
        (root/"real").mkdir()
        (root/"parent-link").symlink_to(root/"real", target_is_directory=True)
        (root/"target-link").symlink_to(root/"outside")
        (root/"directory").mkdir()
        os.mkfifo(root/"fifo")
        paths = ["/tmp/private", "/workspace/../tmp", "/workspace//data", "/workspace",
                 "/workspace/parent-link/data", "/workspace/target-link", "/workspace/directory", "/workspace/fifo"]
        for operation in ["upload", "download"]:
            for path in paths:
                with self.subTest(operation=operation, path=path):
                    header = self.file_header(operation, path, b"x")
                    self.assertEqual(self.run_helper(frame(header) + (b"x" if operation == "upload" else b""))[:2], (126, b""))
        self.assertFalse((root/"outside").exists())
        self.assertEqual(list((root/"real").iterdir()), [])

    def test_download_size_limit_hardlink_and_excess_input_fail_before_data(self):
        root = Path(self.workspace.name)
        (root/"file").write_bytes(b"abcdef")
        self.assertEqual(self.run_helper(frame(self.file_header("download", "/workspace/file", max_bytes=5)))[:2], (126, b""))
        self.assertEqual(self.run_helper(frame(self.file_header("download", "/workspace/file")) + b"extra")[:2], (126, b""))
        (root/"hardlink").hardlink_to(root/"file")
        self.assertEqual(self.run_helper(frame(self.file_header("download", "/workspace/hardlink")))[:2], (126, b""))

    def test_changing_download_is_rejected_instead_of_returning_a_mixed_snapshot(self):
        path = Path(self.workspace.name)/"changing"
        path.write_bytes(b"a" * 65536)
        injection = (
            "\noriginal_read=os.read\nchanged=False\n"
            "def changing_read(fd,count):\n"
            " global changed\n value=original_read(fd,count)\n"
            f" if fd>2 and not changed and os.fstat(fd).st_ino==os.stat({str(path)!r}).st_ino:\n"
            f"  changed=True\n  f=open({str(path)!r},'wb'); f.write(b'b'*65536); f.close()\n"
            " return value\nos.read=changing_read\n"
        )
        self.wrapper = self.wrapper.replace("runpy.run_path(os.environ['SMOLBOX_HELPER_TEST_SOURCE'])", injection + "runpy.run_path(os.environ['SMOLBOX_HELPER_TEST_SOURCE'])")
        self.assertEqual(self.run_helper(frame(self.file_header("download", "/workspace/changing")))[:2], (126, b""))

    def test_loader_rejects_changed_source_or_size_before_any_execution(self):
        source = HELPER.read_bytes()
        template = HELPER.with_name("guest_loader_v1.py").read_text()
        loader = template.replace("__HELPER_BYTES__", str(len(source))).replace("__HELPER_SHA256__", hashlib.sha256(source).hexdigest())
        self.wrapper = self.wrapper.replace("runpy.run_path(os.environ['SMOLBOX_HELPER_TEST_SOURCE'])", "\n" + loader)
        payload = b"SBP1" + struct.pack("!I", len(source)) + source
        for wrong in [b"BAD!" + payload[4:], b"SBP1" + struct.pack("!I", len(source)+1) + source,
                      payload[:-1] + bytes([payload[-1] ^ 1])]:
            self.assertEqual(self.run_helper(wrong), (126, b"", b"smolbox helper identity failed\n"))

    def test_loader_short_source_rejects_without_evaluating_control_data(self):
        source = HELPER.read_bytes()
        template = HELPER.with_name("guest_loader_v1.py").read_text()
        loader = template.replace("__HELPER_BYTES__", str(len(source))).replace("__HELPER_SHA256__", hashlib.sha256(source).hexdigest())
        self.wrapper = self.wrapper.replace("runpy.run_path(os.environ['SMOLBOX_HELPER_TEST_SOURCE'])", "\n" + loader)
        payload = b"SBP1" + struct.pack("!I", len(source)) + source[:20]
        self.assertEqual(self.run_helper(payload, close=True), (126, b"", b"smolbox helper identity failed\n"))


if __name__ == "__main__":
    unittest.main()
