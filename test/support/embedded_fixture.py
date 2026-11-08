"""Deterministic OS-Port peer; deliberately never opens an SDK or a VM."""
import base64
import json
import os
import secrets
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).parent
META = json.loads((ROOT / "fixture.json").read_text())
CONFIG = json.loads(Path(sys.argv[2]).read_text())
EPOCH = secrets.token_hex(16)
PENDING = {}
VM_PATH = ROOT / "vm.json"
VM = json.loads(VM_PATH.read_text()) if META.get("persistent_backend") and VM_PATH.exists() else None
FILES = {}


def save_vm():
    if META.get("persistent_backend"):
        VM_PATH.write_text(json.dumps(VM))


def log(message):
    with (ROOT / "received.jsonl").open("a") as file:
        file.write(json.dumps(message) + "\n")


def send(message):
    body = json.dumps(message, separators=(",", ":")).encode()
    frame = struct.pack(">I", len(body)) + body
    while frame:
        count = os.write(1, frame)
        frame = frame[count:]


def read_exact(size):
    data = b""
    while len(data) < size:
        chunk = os.read(0, size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def correlated(kind, identifier, sequence, **fields):
    return dict(type=kind, epoch=EPOCH, id=identifier, sequence=sequence, **fields)


def terminal(identifier, completion="exited", code=7):
    entry = PENDING.pop(identifier)
    send(correlated("terminal", identifier, entry["sequence"] + 1, outcome=dict(
        result="command", completion=completion, dispatch="may_have_dispatched",
        observed_exit=code, running_observed=True, output_bytes=entry["bytes"])))


def pump(identifier):
    entry = PENDING[identifier]
    while entry["chunks"]:
        stream, data = entry["chunks"][0]
        if entry["credit"] < len(data) or not entry["events"]:
            return
        entry["chunks"].pop(0)
        entry["credit"] -= len(data)
        entry["events"] -= 1
        entry["sequence"] += 1
        entry["bytes"] += len(data)
        send(correlated("event", identifier, entry["sequence"], event=dict(
            stream=stream, data_base64=base64.b64encode(data).decode())))
    if entry["mode"] == "file":
        PENDING.pop(identifier)
        send(correlated("terminal", identifier, entry["sequence"] + 1, outcome=dict(
            result="file", completion="completed", dispatch="may_have_dispatched",
            observed_bytes=entry["bytes"], native_acknowledged=True)))
    elif entry["mode"] == "echo":
        terminal(identifier)
    elif entry["mode"] == "exit_error":
        terminal(identifier, "native_error", 7)
    elif entry["mode"] == "crash":
        sys.exit(23)


hello = dict(major=1, minor=META.get('protocol_minor', 3), epoch=EPOCH,
             domain=dict(target_id=CONFIG["target_id"], generation=CONFIG["generation"]),
             package=META["identity"], capabilities=META["capabilities"],
             limits=META["limits"], preflight=dict(status="ready"))
if META.get("wrong_hello"):
    hello["domain"]["generation"] = "0" * 32
log(dict(launch=True, config_mode=Path(sys.argv[2]).stat().st_mode & 0o777))
send(dict(type="hello", hello=hello))
approved = False
try:
    while True:
        size = struct.unpack(">I", read_exact(4))[0]
        message = json.loads(read_exact(size))
        log(message)
        kind = message["type"]
        if kind == "approve":
            assert message["hello"] == hello
            approved = True
        elif kind == "shutdown":
            if not META.get("ignore_shutdown"):
                sys.exit(0)
        else:
            assert approved and message["epoch"] == EPOCH
            identifier = message["id"]
            if kind == "request":
                operation = message["operation"]
                send(correlated("accepted", identifier, 0))
                if operation["operation"] == "qualify_creation":
                    if META.get("reject_qualification") or (META.get("vm_artifact") and operation["user"] is not None):
                        send(correlated("terminal", identifier, 1, outcome=dict(result="error", code="unsupported", dispatch="not_dispatched")))
                    else:
                        send(correlated("terminal", identifier, 1, outcome=dict(result="qualified")))
                elif META.get("backend") and operation["operation"] == "inspect_creation":
                    send(correlated("terminal", identifier, 1, outcome=dict(
                        result="creation_presence", presence="unverified" if VM else "absent")))
                elif META.get("backend") and operation["operation"] == "create":
                    create = operation["create"]
                    VM = dict(resources=create["resources"], state="stopped")
                    save_vm()
                    receipt = dict(target_id=CONFIG["target_id"], domain_generation=CONFIG["generation"],
                                   name=create["name"], owner_token=create["owner_token"],
                                   incarnation=create["incarnation"], material_sha256="9" * 64)
                    send(correlated("terminal", identifier, 1, outcome=dict(result="created", receipt=receipt)))
                elif META.get("backend") and operation["operation"] in ("inspect", "start", "stop", "delete"):
                    action = operation["operation"]
                    if action == "delete":
                        # The native engine refuses deletion of running/unknown VMs.
                        assert not VM or VM["state"] == "stopped"
                        VM = None
                    elif VM and action in ("start", "stop"):
                        VM["state"] = "running" if action == "start" else "stopped"
                    save_vm()
                    state = VM["state"] if VM else "missing"
                    send(correlated("terminal", identifier, 1, outcome=dict(result="observed",
                        observation=dict(state=state, resources=VM["resources"] if VM else None,
                            pid_identity=[4242, 123456] if state == "running" else None))))
                elif operation["operation"] == "inspect":
                    send(correlated("terminal", identifier, 1, outcome=dict(
                        result="observed", observation=dict(state="stopped", resources=None,
                                                            pid_identity=None))))
                elif operation["operation"] == "write_file":
                    PENDING[identifier] = dict(total=operation["total_bytes"], upload=b"",
                                              path=operation["options"]["guest_path"])
                    if not operation["total_bytes"]:
                        FILES[operation["options"]["guest_path"]] = b""
                        PENDING.pop(identifier)
                        send(correlated("terminal", identifier, 1, outcome=dict(
                            result="file", completion="completed", dispatch="may_have_dispatched",
                            observed_bytes=0, native_acknowledged=True)))
                elif META.get("backend") and operation["operation"] == "read_file":
                    data = FILES.get(operation["options"]["guest_path"], b"")
                    chunks = [("file", data[offset:offset + 65536]) for offset in range(0, len(data), 65536)]
                    PENDING[identifier] = dict(sequence=0, bytes=0, mode="file", chunks=chunks,
                                               credit=message["initial_credit"], events=message["initial_event_credit"])
                    pump(identifier)
                else:
                    mode = operation["command"]["argv"][0]
                    chunks = [("stdout", b"out\x00\xff"), ("stderr", b"err\x00\xfe")]
                    if mode == "hold":
                        chunks = []
                    elif mode == "flood":
                        chunks = [("stdout", b"x")] * 70
                        mode = "echo"
                    elif mode == "bad_sequence":
                        send(correlated("event", identifier, 2, event=dict(
                            stream="stdout", data_base64="eA==")))
                        continue
                    elif mode == "huge_header":
                        os.write(1, struct.pack(">I", 1048577))
                        continue
                    elif mode == "partial":
                        os.write(1, struct.pack(">I", 100) + b"{")
                        sys.exit(24)
                    PENDING[identifier] = dict(sequence=0, bytes=0, mode=mode, chunks=chunks,
                                               credit=message["initial_credit"],
                                               events=message["initial_event_credit"])
                    if mode == "unavailable":
                        send(dict(type="unavailable", epoch=EPOCH))
                        terminal(identifier, "unknown", None)
                        continue
                    pump(identifier)
            elif kind == "credit" and identifier in PENDING:
                entry = PENDING[identifier]
                entry["credit"] += message["decoded_bytes"]
                entry["events"] += message["events"]
                pump(identifier)
            elif kind == "cancel" and identifier in PENDING:
                entry = PENDING[identifier]
                if "total" in entry:
                    PENDING.pop(identifier)
                    send(correlated("terminal", identifier, 1, outcome=dict(
                        result="file", completion="cancelled", dispatch="not_dispatched",
                        observed_bytes=0, native_acknowledged=False)))
                else:
                    terminal(identifier, "cancelled", None)
            elif kind == "upload":
                entry = PENDING[identifier]
                assert message["offset"] == len(entry["upload"])
                entry["upload"] += base64.b64decode(message["data_base64"], validate=True)
                if len(entry["upload"]) == entry["total"]:
                    FILES[entry["path"]] = entry["upload"]
                    log(dict(upload_complete=identifier, total=entry["total"]))
                    PENDING.pop(identifier)
                    send(correlated("terminal", identifier, 1, outcome=dict(
                        result="file", completion="completed", dispatch="may_have_dispatched",
                        observed_bytes=entry["total"], native_acknowledged=True)))
except EOFError:
    pass
finally:
    if VM:
        VM["state"] = "stopped"
        save_vm()
