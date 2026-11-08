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
QUARANTINED = False
VM_PATH = ROOT / "vm.json"
VM = json.loads(VM_PATH.read_text()) if META.get("persistent_backend") and VM_PATH.exists() else None
FILES = {}


def save_vm():
    if META.get("persistent_backend"):
        VM_PATH.write_text(json.dumps(VM))


def observation():
    state = VM["state"] if VM else "missing"
    value = dict(state=state, resources=VM["resources"] if VM else None,
                 pid_identity=[4242, 123456] if state == "running" else None)
    features = VM.get("features") if VM else None
    if features and (features["network"]["enabled"] or features["ports"]):
        value["configuration"] = dict(network=features["network"], ports=features["ports"],
                                      backend="virtio-net")
    return value


def unpack_creation(operation):
    fields = operation.get("create", operation)
    if "features_payload" not in fields:
        return operation
    payload = fields["features_payload"]
    assert set(payload) == {"schema", "chunks"} and payload["schema"] == 1
    assert "features" not in fields and 0 < len(payload["chunks"]) <= 10
    parts = [base64.b64decode(chunk, validate=True) for chunk in payload["chunks"]]
    assert all(0 < len(part) <= 65536 for part in parts)
    assert all(len(part) == 65536 for part in parts[:-1])
    assert all(base64.b64encode(part).decode() == chunk for part, chunk in zip(parts, payload["chunks"]))
    raw = b"".join(parts)
    assert len(raw) <= 655360
    offset = 0

    def take(size):
        nonlocal offset
        assert offset + size <= len(raw)
        value = raw[offset:offset + size]
        offset += size
        return value

    def flag():
        value = take(1)[0]
        assert value in (0, 1)
        return value == 1

    def count(maximum):
        value = struct.unpack(">H", take(2))[0]
        assert value <= maximum
        return value

    def string(maximum):
        size = struct.unpack(">I", take(4))[0]
        assert size <= maximum
        return take(size).decode("utf-8")

    def strings(maximum, size):
        return [string(size) for _ in range(count(maximum))]

    assert take(5) == b"SBCF\x01"
    network = dict(enabled=flag(), hosts=strings(32, 253), cidrs=strings(32, 49))
    ports = [dict(host=struct.unpack(">H", take(2))[0], guest=struct.unpack(">H", take(2))[0])
             for _ in range(count(32))]
    workload = None
    if flag():
        entrypoint, cmd = strings(255, 16384), strings(255, 16384)
        env = {}
        for _ in range(count(64)):
            key, value = string(128), string(8192)
            assert key not in env
            env[key] = value
        workload = dict(entrypoint=entrypoint, cmd=cmd, env=env, workdir=string(4096) if flag() else None)
    assert offset == len(raw)
    fields = {key: value for key, value in fields.items() if key != "features_payload"}
    fields["features"] = dict(network=network, ports=ports, workload=workload)
    return dict(operation, create=fields) if "create" in operation else fields


def unpack_command(operation):
    if "command_payload" not in operation:
        return operation
    payload = operation["command_payload"]
    assert operation["operation"] in ("exec_buffered", "exec_background", "exec_stream") and "command" not in operation
    assert set(payload) == {"schema", "chunks"} and payload["schema"] == 1
    parts = [base64.b64decode(chunk, validate=True) for chunk in payload["chunks"]]
    assert 0 < len(parts) <= 11 and all(0 < len(part) <= 65536 for part in parts)
    assert all(len(part) == 65536 for part in parts[:-1])
    raw = b"".join(parts)
    assert len(raw) <= 720896
    offset = 0
    def take(n):
        nonlocal offset
        assert offset + n <= len(raw)
        value = raw[offset:offset+n]
        offset += n
        return value
    def count(maximum):
        n = struct.unpack(">H",take(2))[0]
        assert n <= maximum
        return n
    def string(maximum):
        n = struct.unpack(">I",take(4))[0]
        assert n <= maximum
        return take(n).decode("utf-8")
    def optional(maximum):
        tag = take(1)[0]
        assert tag in (0,1)
        return string(maximum) if tag else None
    assert take(5) == b"SBCM\x01"
    argv = [string(16384) for _ in range(count(256))]
    env = {}
    for _ in range(count(64)):
        key,value = string(128),string(8192)
        assert key not in env
        env[key] = value
    command = dict(argv=argv,env=env,workdir=optional(4096),user=optional(128),stdin=optional(65536),
                   max_output_bytes=struct.unpack(">Q",take(8))[0])
    assert offset == len(raw)
    result = {key:value for key,value in operation.items() if key != "command_payload"}
    result["command"] = command
    return result

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
    if entry["mode"] == "terminal":
        send(correlated("terminal", identifier, entry["sequence"] + 1, outcome=dict(
            result="terminal", completion=completion, dispatch="may_have_dispatched",
            observed_exit=code, worker_collected=True, output_bytes=entry["bytes"])))
        return
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
    if entry["mode"] == "terminal":
        if entry.get("finish"):
            terminal(identifier, *entry["finish"])
    elif entry["mode"] == "logs":
        PENDING.pop(identifier)
        send(correlated("terminal", identifier, entry["sequence"] + 1, outcome=dict(
            result="logs", completion="deadline" if entry["follow"] else "completed",
            lines=entry["lines"], bytes=entry["public_bytes"], wire_bytes=entry["bytes"])))
    elif entry["mode"] == "file":
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


hello = dict(major=META.get('protocol_major', 1), minor=META.get('protocol_minor', 3), epoch=EPOCH,
             domain=dict(target_id=CONFIG["target_id"], generation=CONFIG["generation"]),
             package=META["identity"], capabilities=META["capabilities"],
             limits=META["limits"], preflight=dict(status="ready"))
if hello["major"] == 2:
    assert CONFIG["schema"] == 2
    hello["sdk"] = META["sdk"]
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
                operation = unpack_command(unpack_creation(message["operation"]))
                send(correlated("accepted", identifier, 0))
                if operation["operation"] == "health":
                    send(correlated("terminal", identifier, 1, outcome=dict(result="health", snapshot=dict(
                        total=int(VM is not None), running=int(bool(VM and VM["state"] == "running")), uptime_seconds=1))))
                elif operation["operation"] == "readiness":
                    outcome = dict(result="error", code="state", dispatch="not_dispatched") if QUARANTINED else dict(result="ready")
                    send(correlated("terminal", identifier, 1, outcome=outcome))
                elif operation["operation"] == "capacity":
                    running = bool(VM and VM["state"] == "running")
                    send(correlated("terminal", identifier, 1, outcome=dict(result="capacity", snapshot=dict(
                        allocated_cpus=VM["resources"]["cpus"] if running else 0,
                        allocated_memory_mb=VM["resources"]["memory_mib"] if running else 0,
                        used_cpu_millis=125 if running else 0, used_memory_mb=64 if running else 0,
                        used_memory_pss_mb=None, used_memory_private_mb=None, used_memory_shared_mapped_mb=None,
                        host_memory_total_mb=None, host_memory_available_mb=None, used_disk_gb=2 if running else 0,
                        boot_id=EPOCH))))
                elif operation["operation"] == "metrics":
                    send(correlated("terminal", identifier, 1, outcome=dict(result="metrics",
                        text="# TYPE smolbox_native_machines gauge\nsmolbox_native_machines " + str(int(VM is not None)) + "\n")))
                elif operation["operation"] == "list":
                    machines = []
                    if VM:
                        resources = VM["resources"]
                        configured = observation().get("configuration", {})
                        network = configured.get("network", dict(enabled=False, hosts=[], cidrs=[]))
                        machines.append(dict(name=VM.get("name", "fixture-vm"), state=VM["state"], createdAt=1,
                            cpus=resources["cpus"], memoryMb=resources["memory_mib"], storageGb=resources["storage_gib"],
                            overlayGb=resources["overlay_gib"], network=network["enabled"], networkBackend=configured.get("backend"),
                            allowedHosts=network["hosts"], allowedCidrs=network["cidrs"], gpu=False, cuda=False,
                            mounts=[], ports=configured.get("ports", [])))
                    data = json.dumps(machines).encode()
                    send(correlated("event", identifier, 1, event=dict(stream="file", data_base64=base64.b64encode(data).decode())))
                    send(correlated("terminal", identifier, 2, outcome=dict(result="inventory", count=len(machines), bytes=len(data))))
                elif operation["operation"] == "measurements":
                    state = VM["state"] if VM else "missing"
                    running = state == "running"
                    send(correlated("terminal", identifier, 1, outcome=dict(result="measurements",
                        observation=observation(),
                        counters=dict(cpu_seconds=1 if running else None, cpu_millis=1500 if running else None,
                            rss_mb=64 if running else None, pss_mb=None, private_memory_mb=None,
                            shared_memory_mapped_mb=None, disk_used_mb=3 if VM else None, egress_bytes=None))))
                elif operation["operation"] == "qualify_creation":
                    if META.get("reject_qualification") or (META.get("vm_artifact") and
                            (operation["user"] is not None or operation.get("features", {}).get("workload") is not None)):
                        send(correlated("terminal", identifier, 1, outcome=dict(result="error", code="unsupported", dispatch="not_dispatched")))
                    else:
                        send(correlated("terminal", identifier, 1, outcome=dict(result="qualified")))
                elif META.get("backend") and operation["operation"] == "inspect_creation":
                    send(correlated("terminal", identifier, 1, outcome=dict(
                        result="creation_presence", presence="unverified" if VM else "absent")))
                elif META.get("backend") and operation["operation"] == "create":
                    create = operation["create"]
                    VM = dict(name=create["name"], resources=create["resources"], state="stopped", started=False,
                              features=create.get("features"))
                    save_vm()
                    receipt = dict(target_id=CONFIG["target_id"], domain_generation=CONFIG["generation"],
                                   name=create["name"], owner_token=create["owner_token"],
                                   incarnation=create["incarnation"], material_sha256="9" * 64)
                    if hello["major"] == 2:
                        receipt["material"] = dict(schema=2, revision=0, record_sha256="9" * 64,
                                                   chain_sha256="a" * 64, operation_id=None,
                                                   request_sha256=None)
                    send(correlated("terminal", identifier, 1, outcome=dict(result="created", receipt=receipt)))
                elif META.get("backend") and operation["operation"] in ("inspect", "start", "stop", "delete"):
                    action = operation["operation"]
                    if action == "delete":
                        # The native engine refuses deletion of running/unknown VMs.
                        assert not VM or VM["state"] == "stopped"
                        VM = None
                    elif VM and action in ("start", "stop"):
                        VM["state"] = "running" if action == "start" else "stopped"
                        if action == "start": VM["started"] = True
                    save_vm()
                    send(correlated("terminal", identifier, 1, outcome=dict(result="observed",
                        observation=observation())))
                elif META.get("backend") and operation["operation"] == "logs":
                    if not VM or not VM.get("started"):
                        send(correlated("terminal", identifier, 1, outcome=dict(
                            result="error", code="not_found", dispatch="not_dispatched")))
                        continue
                    lines = ["boot", "", "hé\x00line"]
                    lines = lines[-operation["tail"]:] if operation["tail"] else []
                    if operation["follow"]:
                        lines.extend(["follow", "next"])
                    public_bytes = sum(len(line.encode()) + 1 for line in lines)
                    if public_bytes > operation["max_bytes"]:
                        send(correlated("terminal", identifier, 1, outcome=dict(
                            result="logs", completion="output_limit", lines=0, bytes=0, wire_bytes=0)))
                        continue
                    framed = b"".join(struct.pack(">I", len(line.encode())) + line.encode() for line in lines)
                    chunks = [("log", framed[index:index + 5]) for index in range(0, len(framed), 5)]
                    PENDING[identifier] = dict(sequence=0, bytes=0, mode="logs", chunks=chunks,
                        follow=operation["follow"], lines=len(lines), public_bytes=public_bytes,
                        credit=message["initial_credit"], events=message["initial_event_credit"])
                    pump(identifier)
                elif META.get("backend") and operation["operation"] == "exec_background":
                    if operation["command"]["argv"][0] == "launch_unknown":
                        send(correlated("terminal", identifier, 1, outcome=dict(
                            result="error", code="native", dispatch="may_have_dispatched")))
                    else:
                        send(correlated("terminal", identifier, 1, outcome=dict(result="launched", pid=4242)))
                elif META.get("backend") and operation["operation"] == "terminal_open":
                    assert VM and VM["state"] == "running"
                    if META.get("vm_artifact"):
                        send(correlated("terminal", identifier, 1, outcome=dict(
                            result="error", code="unsupported", dispatch="not_dispatched")))
                        continue
                    PENDING[identifier] = dict(sequence=1, bytes=0, mode="terminal", chunks=[],
                        controls=0, input_bytes=0, attached=False, spec=operation["terminal"],
                        credit=message["initial_credit"], events=message["initial_event_credit"])
                    send(correlated("terminal_opened", identifier, 1))
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
                    if mode == "stdin_echo":
                        chunks = [("stdout", operation["command"]["stdin"].encode("utf-8")), ("stderr", b"err\x00\xfe")]
                        mode = "echo"
                    elif mode == "hold":
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
                        QUARANTINED = True
                        send(dict(type="unavailable", epoch=EPOCH))
                        terminal(identifier, "unknown", None)
                        continue
                    pump(identifier)
            elif kind == "terminal_control" and identifier in PENDING:
                entry = PENDING[identifier]
                assert entry["mode"] == "terminal"
                assert message["sequence"] == entry["controls"] + 1
                entry["controls"] += 1
                control = message["control"]
                action = control["action"]
                if action == "attach":
                    assert not entry["attached"]
                    entry["attached"] = True
                    entry["chunks"].append(("terminal", b"ready\r\n"))
                else:
                    assert entry["attached"]
                    if action == "input":
                        data = base64.b64decode(control["data_base64"], validate=True)
                        assert 0 < len(data) <= entry["spec"]["max_input_bytes"]
                        entry["input_bytes"] += len(data)
                        if data == b"exit":
                            entry["finish"] = ("exited", 7)
                        elif data == b"unknown":
                            entry["finish"] = ("unknown", None)
                        else:
                            entry["chunks"].append(("terminal", data))
                    elif action == "resize":
                        entry["input_bytes"] += 4
                        entry["chunks"].append(("terminal", json.dumps(
                            dict(cols=control["cols"], rows=control["rows"])).encode()))
                    elif action == "close":
                        entry["finish"] = ("cancelled", None)
                    else:
                        raise AssertionError("invalid terminal control")
                    assert entry["input_bytes"] <= entry["spec"]["total_input_bytes"]
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
