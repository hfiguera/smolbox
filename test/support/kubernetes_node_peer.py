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


magic = exact(4)
assert magic in [b"SBH1", b"SBG1"]
request = json.loads(exact(struct.unpack(">I", exact(4))[0]))
(root / "request.json").write_text(json.dumps({"argv": sys.argv[1:], "request": request}))
options = json.loads((root / "response.json").read_text())
mode = options["mode"]
if mode == "controller":
    state_path = root / "controller-state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text())
    else:
        state = {"known_owners": options.get("controller", {}).get("known_owners", []),
                 "enrolled": options.get("controller", {}).get("enrolled", False)}
    action, owner = request["action"], request["owner"]
    if action == "acquire" and owner not in state["known_owners"]:
        state["known_owners"].append(owner)
    allowed = state["known_owners"] and state["known_owners"][-1] == owner
    if allowed and action == "activate":
        state["enrolled"] = True
    if allowed and action in ["acquire", "activate"]:
        temporary = root / ("controller-state-" + str(os.getpid()) + ".part")
        temporary.write_text(json.dumps(state))
        temporary.replace(state_path)
    options["response"] = {"ok": bool(allowed), "grant": {
        "version": 1, "binding_generation": request["binding_generation"], "domain_id": "fixture-domain",
        "generation": len(state["known_owners"]), "owner": owner, "known_owners": state["known_owners"],
        "enrolled": state["enrolled"], "host_id": "fixture-host", "boot_id": "fixture-boot",
        "pid": request["pid"], "birth": "fixture-birth"}}
    mode = "normal"

if mode == "hold":
    while os.read(0, 1):
        pass
    (root / "closed").write_text("EOF")
elif mode == "oversized":
    os.write(1, magic + struct.pack(">I", 65537) + b"x" * 65537)
elif mode == "partial":
    os.write(1, magic + b"\x00\x00\x00\x10{}")
elif mode == "diagnostic":
    os.write(2, b"private-node-diagnostic")
else:
    data = json.dumps(options["response"]).encode()
    frame = magic + struct.pack(">I", len(data)) + data
    if mode == "trailing":
        frame += b"extra"
    for part in [frame[:3], frame[3:8], frame[8:]]:
        os.write(1, part)
        time.sleep(0.001)
