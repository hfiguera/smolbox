#!/usr/bin/env python3
"""Controller-owned qualification stand-in: real exec SSH or a typed rejection.

The unavailable mode is synthetic, produces no positive evidence and must be
labeled separately from real node failures. Normal mode execs the actual SSH
binary without reading the frame, preserving its channel and cancellation.
"""
import json
import os
from pathlib import Path
import struct
import sys

mode = json.loads((Path(__file__).parent / "evidence-fault.json").read_text())["mode"]
if mode == "real":
    os.execv("/usr/bin/ssh", ["/usr/bin/ssh", *sys.argv[1:]])
if mode != "unavailable":
    sys.exit(2)


def exact(count):
    value = bytearray()
    while len(value) < count:
        part = os.read(0, count - len(value))
        if not part:
            raise ValueError("closed input")
        value.extend(part)
    return bytes(value)


if exact(4) != b"SBA1":
    sys.exit(2)
size = struct.unpack(">I", exact(4))[0]
if not 0 < size <= 65536:
    sys.exit(2)
request = json.loads(exact(size))
response = {
    key: request[key]
    for key in (
        "version",
        "action",
        "nonce",
        "binding_generation",
        "authority_generation",
        "verifier_manifest_sha256",
    )
}
response.update(ok=False, error="unavailable", value=None, journal=None)
body = json.dumps(response, separators=(",", ":")).encode()
if len(body) + 8 > request["max_response_bytes"]:
    sys.exit(2)
os.write(1, b"SBA1" + struct.pack(">I", len(body)) + body)
sys.exit(1)
