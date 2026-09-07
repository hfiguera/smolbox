#!/usr/bin/env python3
"""Qualify a dedicated loopback worker restart using the actual durable host."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


class Child:
    """Own/reap one child and continuously drain bounded diagnostic output."""

    def __init__(self, arguments, cwd=None, env=None):
        self.process = subprocess.Popen(arguments, cwd=cwd, env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT)
        self.lines = queue.Queue(maxsize=128)
        self.overflow = threading.Event()
        self.tail = bytearray()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        pending = bytearray()
        while data := self.process.stdout.read1(4096):
            self.tail.extend(data)
            del self.tail[:-65536]
            pending.extend(data)
            if len(pending) > 65536:
                self.overflow.set()
                pending.clear()
            while b"\n" in pending:
                line, _, remaining = pending.partition(b"\n")
                pending = bytearray(remaining)
                if line.startswith(b"phase:"):
                    try:
                        self.lines.put_nowait(line.decode("utf-8", errors="strict"))
                    except (queue.Full, UnicodeError):
                        self.overflow.set()

    def phase(self, expected, snapshots, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.overflow.is_set():
                raise RuntimeError("child diagnostic output exceeded its bound")
            try:
                line = self.lines.get(timeout=0.1)
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError("controller exited: " + self.tail.decode("utf-8", "replace"))
                continue
            if line.startswith("phase:assigned:"):
                snapshots.append(json.loads(line.removeprefix("phase:assigned:")))
            if line == expected or line.startswith(expected + ":"):
                return line
        raise RuntimeError("controller phase deadline elapsed: " + expected)

    def send(self, line):
        self.process.stdin.write((line + "\n").encode())
        self.process.stdin.flush()

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=10)
        self.reader.join(timeout=2)


def request(url, method="GET", body=None, binary=False):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"} if body is not None else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=3) as response:
        data = response.read(2097153)
        if len(data) > 2097152:
            raise RuntimeError("worker response exceeded its bound")
        return data if binary else json.loads(data)


def ready(url):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            status = request(url + "/health")
            assert status["version"] == "1.14.1"
            return
        except (urllib.error.URLError, TimeoutError, OSError):
            time.sleep(0.05)
    raise RuntimeError("owned worker did not become ready")


def same_machine(observed, created):
    expected = {"name": created["name"], "createdAt": created["created_at"],
                "cpus": created["cpus"], "memoryMb": created["memory_mb"],
                "storageGb": created["storage_gb"], "overlayGb": created["overlay_gb"],
                "network": False, "mounts": [], "ports": [], "gpu": False, "cuda": False}
    return all(observed.get(key) == value for key, value in expected.items())


def digest(file):
    result = hashlib.sha256()
    with Path(file).open("rb") as source:
        for block in iter(lambda: source.read(65536), b""):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smolvm", required=True)
    parser.add_argument("--url", default="http://127.0.0.1:19470")
    parser.add_argument("--python", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    address = urllib.parse.urlsplit(args.url)
    assert address.scheme == "http" and address.hostname == "127.0.0.1"
    assert address.port and not address.path and not address.query and not address.fragment
    assert not address.username and not address.password
    assert subprocess.check_output([args.smolvm, "--version"], timeout=5) == b"smolvm 1.14.1\n"
    with socket.socket() as probe:
        probe.settimeout(1)
        if probe.connect_ex((address.hostname, address.port)) == 0:
            raise RuntimeError("listen port is occupied; this script never stops an existing server")

    workspace = Path(tempfile.mkdtemp(prefix="sbx-worker-restart-"))
    (workspace / "objects").mkdir(mode=0o700)
    for name in ["fingerprint.key", "encryption.key"]:
        file = workspace / name
        file.write_bytes(os.urandom(32))
        file.chmod(0o600)
    identity = "restart-" + os.urandom(8).hex()
    settings = {"url": args.url, "artifact_path": str(Path(args.python).resolve()),
                "artifact_sha256": digest(args.python), "artifact_root": str(workspace / "objects"),
                "fingerprint_key_file": str(workspace / "fingerprint.key"),
                "encryption_key_file": str(workspace / "encryption.key"),
                "partition": identity, "id": identity, "wait": True,
                "ledger": str(workspace / "dispatch-attempts")}
    settings_file = workspace / "settings.json"
    settings_file.write_text(json.dumps(settings))
    settings_file.chmod(0o600)
    package = Path(__file__).resolve().parent.parent
    worker_args = [args.smolvm, "serve", "start", "-l", f"127.0.0.1:{address.port}"]
    worker_env = dict(os.environ, SMOLVM_FILE_TRANSFER_MAX_BYTES="1048576")
    if os.uname().sysname == "Linux" and not worker_env.get("SMOLVM_DATA_DIR"):
        raise RuntimeError("Linux qualification requires a dedicated SMOLVM_DATA_DIR")
    worker = Child(worker_args, env=worker_env)
    controller = None
    snapshots = []
    started = time.monotonic()
    report = {"status": "failed", "retained_workspace": str(workspace), "partition": identity}
    try:
        ready(args.url)
        assert request(args.url + "/api/v1/machines") == {"machines": []}
        controller = Child(["mix", "run", "scripts/worker_restart.exs", str(settings_file)],
                           cwd=package / "examples/durable_host")
        controller.phase("phase:running", snapshots)
        assert len(snapshots) == 1
        worker.kill()
        controller.send("worker_down")
        controller.phase("phase:paused", snapshots)
        worker = Child(worker_args, env=worker_env)
        ready(args.url)
        machine_url = args.url + "/api/v1/machines/" + urllib.parse.quote(snapshots[0]["name"], safe="")
        observed = request(machine_url)
        assert same_machine(observed, snapshots[0]) and observed["state"] == "running"
        assert request(machine_url + "/files/workspace/count", binary=True) == b"x"
        controller.send("resume")
        completed = controller.phase("phase:complete", snapshots, timeout=120)
        result = json.loads(completed.removeprefix("phase:complete:"))
        assert controller.process.wait(timeout=10) == 0
        assert Path(settings["ledger"]).read_bytes() == b"exec\n"
        assert request(args.url + "/api/v1/machines") == {"machines": []}
        report.update(status="passed", seconds=round(time.monotonic() - started, 3),
                      result=result, dispatch_attempts=1, guest_marker="single byte before recovery",
                      guest_survived_api_server=True, artifact_sha256=settings["artifact_sha256"],
                      runtime_version="1.14.1", platform=os.uname().sysname)
    except BaseException as error:
        report.update(status="failed", failure=type(error).__name__)
        raise
    finally:
        cleanup_errors = []
        if controller:
            try:
                controller.kill()
            except BaseException as error:
                cleanup_errors.append(type(error).__name__)
        try:
            if snapshots:
                if worker.process.poll() is not None:
                    worker = Child(worker_args, env=worker_env)
                    ready(args.url)
                for created in snapshots:
                    url = args.url + "/api/v1/machines/" + urllib.parse.quote(created["name"], safe="")
                    try:
                        current = request(url)
                        if not same_machine(current, created):
                            raise RuntimeError("cleanup identity conflict; resource retained")
                        request(url + "/stop", "POST", {})
                        stopped = request(url)
                        assert same_machine(stopped, created) and stopped["state"] != "running"
                        request(url, "DELETE")
                    except urllib.error.HTTPError as error:
                        if error.code != 404:
                            raise
        except BaseException as error:
            cleanup_errors.append(type(error).__name__)
        finally:
            try:
                worker.kill()
            except BaseException as error:
                cleanup_errors.append(type(error).__name__)
            if cleanup_errors:
                report.update(status="failed", cleanup_errors=cleanup_errors)
            target = Path(args.report)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(report, indent=2) + "\n")
        if cleanup_errors:
            raise RuntimeError("owned-resource cleanup failed; inspect the retained report")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
