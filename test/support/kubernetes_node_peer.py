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
assert magic in [b"SBH1", b"SBG1", b"SBA1"]
request = json.loads(exact(struct.unpack(">I", exact(4))[0]))
(root / "request.json").write_text(json.dumps({"argv": sys.argv[1:], "request": request}))
options = json.loads((root / "response.json").read_text())
mode = options["mode"]
if magic == b"SBA1" and not options.get("recorded", False):
    for field in ["version", "action", "nonce", "binding_generation", "authority_generation", "verifier_manifest_sha256"]:
        options["response"][field] = request[field]
    with (root / "requests.jsonl").open("a") as log:
        log.write(json.dumps(request) + "\n")
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
elif mode == "exit":
    sys.exit(options.get("exit_code", 255))
else:
    data = json.dumps(options["response"], separators=(",", ":")).encode()
    if mode == "duplicate":
        data = data.replace(b'"ok":true', b'"ok":true,"ok":true', 1)
    if mode == "nested_duplicate":
        data = data.replace(b'"watermark":2', b'"watermark":2,"watermark":2', 1)
    if mode == "padded":
        data += b" " * (65536 - len(data))
    if mode == "wrongmagic":
        magic = b"BAD!"
    frame = magic + struct.pack(">I", len(data)) + data
    if mode == "trailing":
        frame += b"extra"
    for part in [frame[:3], frame[3:8], frame[8:]]:
        os.write(1, part)
        time.sleep(0.001)
    if mode == "status":
        sys.exit(options["exit_code"])
