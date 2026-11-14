#!/usr/bin/env python3
"""Owned local SSH stand-in for bounded evidence transport tests only."""
import json
import os
from pathlib import Path
import struct
import sys
import time


root = Path(__file__).parent


def exact(count):
    result = bytearray()
    while len(result) < count:
        chunk = os.read(0, count - len(result))
        if not chunk:
            sys.exit(2)
        result.extend(chunk)
    return bytes(result)


assert exact(4) == b"SBH1"
request = json.loads(exact(struct.unpack(">I", exact(4))[0]))
(root / "request.json").write_text(json.dumps({"argv": sys.argv[1:], "request": request}))
options = json.loads((root / "response.json").read_text())
mode = options["mode"]
if mode == "hold":
    while os.read(0, 1):
        pass
    (root / "closed").write_text("EOF")
elif mode == "oversized":
    os.write(1, b"SBH1" + struct.pack(">I", 65537) + b"x" * 65537)
elif mode == "partial":
    os.write(1, b"SBH1\x00\x00\x00\x10{}")
elif mode == "diagnostic":
    os.write(2, b"private-node-diagnostic")
else:
    data = json.dumps(options["response"]).encode()
    frame = b"SBH1" + struct.pack(">I", len(data)) + data
    if mode == "trailing":
        frame += b"extra"
    for part in [frame[:3], frame[3:8], frame[8:]]:
        os.write(1, part)
        time.sleep(0.001)
