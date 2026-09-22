#!/usr/bin/env python3
"""Capture a guest command on the physical host before its VM can be reset.

Usage: python3 capture-terminal.py NEW_DIRECTORY COMMAND [ARG ...]
No retries. Output is private, bounded to 16 MiB and synced as it arrives.
The 15-minute capture deadline does not change the VM/worker deadlines.
"""

import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def capture(directory, command, limit=16 * 1024 * 1024, seconds=900):
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    started = time.monotonic()
    total = 0
    digest = hashlib.sha256()
    reason = "completed"
    process = None
    code = 1
    try:
        with (directory / "campaign.log").open("xb", buffering=0) as output:
            os.chmod(output.name, 0o600)
            process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    if time.monotonic() - started >= seconds:
                        reason = "capture_timeout"
                        break
                    if not selector.select(timeout=0.2):
                        continue
                    chunk = os.read(process.stdout.fileno(), 16384)
                    if not chunk:
                        break
                    remaining = limit - total
                    retained = chunk[:remaining]
                    output.write(retained)
                    os.fsync(output.fileno())
                    digest.update(retained)
                    total += len(retained)
                    if len(chunk) > remaining:
                        reason = "capture_output_limit"
                        break
            if reason == "completed":
                remaining = max(0.1, seconds - (time.monotonic() - started))
                try:
                    code = process.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    reason = "capture_timeout"
    finally:
        if process is not None:
            if reason != "completed" or process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait()
            process.stdout.close()
        receipt = {"exit_code": code, "reason": reason, "bytes": total,
                   "sha256": digest.hexdigest(), "elapsed_seconds": round(time.monotonic() - started, 3)}
        with (directory / "capture.json").open("x") as output:
            os.chmod(output.name, 0o600)
            json.dump(receipt, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    return code if reason == "completed" and code >= 0 else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("Expected a new evidence directory and command arguments")
    sys.exit(capture(sys.argv[1], sys.argv[2:]))
