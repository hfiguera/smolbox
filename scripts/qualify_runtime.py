#!/usr/bin/env python3
"""Explicit Phase 0 smoke probe; this does not replace the Elixir runtime suite."""

import argparse
import base64
import hashlib
import json
import pathlib
import platform
import time
import urllib.request
import urllib.parse
import uuid


def request(base, route, method="GET", data=None):
    headers = {}
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    elif data is not None:
        headers["Content-Type"] = "application/octet-stream"
    req = urllib.request.Request(base + route, data, headers, method=method)
    with urllib.request.urlopen(req, timeout=45) as response:
        body = response.read(2 * 1024 * 1024 + 1)
        assert len(body) <= 2 * 1024 * 1024, "probe response exceeded cap"
        if response.headers.get_content_type() == "application/json":
            return json.loads(body)
        return body


def qualify(base, artifact, language):
    name = "sbxq-" + uuid.uuid4().hex[:12]
    route = "/api/v1/machines/" + name
    identity = None
    result = {"language": language, "machine": name, "checks": []}
    start = time.monotonic()
    try:
        identity = request(base, "/api/v1/machines", "POST", {
            "name": name, "from": str(artifact.resolve()),
            "cpus": 1, "memoryMb": 256, "storageGb": 1, "overlayGb": 1,
            "network": False, "mounts": [], "ports": [],
            "entrypoint": ["/bin/true"], "cmd": [],
            "restart": {"policy": "never"},
        })
        assert identity["name"] == name
        assert identity["state"] == "created"
        machine = request(base, route + "/start", "POST", {})
        assert machine["state"] == "running"
        assert machine["network"] is False
        assert machine["mounts"] == machine["ports"] == []
        assert machine["cpus"] == 1 and machine["memoryMb"] == 256
        result["checks"].append("offline_create_start_allocation")

        blob = b"\x00\xff\xfeSmolBox\n"
        uploaded = request(base, route + "/files/workspace/input.bin", "PUT", blob)
        assert uploaded["size"] == len(blob)
        assert request(base, route + "/files/workspace/input.bin") == blob
        result["checks"].append("binary_file_roundtrip")

        if language == "python":
            command = ["python3", "-c", "import sys; sys.stdout.buffer.write(bytes([0,255,254])); sys.stderr.write('err'); sys.exit(7)"]
            sleeper = ["python3", "-c", "import time; time.sleep(10)"]
            stream = ["python3", "-c", "print('stream-ok')"]
            network = ["python3", "-c", "import socket; socket.create_connection(('1.1.1.1', 443), timeout=1)"]
        else:
            command = ["node", "-e", "process.stdout.write(Buffer.from([0,255,254])); process.stderr.write('err'); process.exitCode=7"]
            sleeper = ["node", "-e", "setTimeout(()=>{},10000)"]
            stream = ["node", "-e", "console.log('stream-ok')"]
            network = ["node", "-e", "const s=require('net').connect(443,'1.1.1.1'); s.setTimeout(1000,()=>process.exit(1)); s.on('error',()=>process.exit(1)); s.on('connect',()=>process.exit(0))"]

        executed = request(base, route + "/exec", "POST", {"command": command, "timeoutSecs": 5})
        assert executed["exitCode"] == 7
        assert base64.b64decode(executed["stdoutB64"], validate=True) == b"\x00\xff\xfe"
        assert base64.b64decode(executed["stderrB64"], validate=True) == b"err"
        result["checks"].append("binary_exec_nonzero")
        timed = request(base, route + "/exec", "POST", {"command": sleeper, "timeoutSecs": 1})
        assert timed["exitCode"] == 124
        result["checks"].append("command_timeout_observed")
        streamed = request(base, route + "/exec/stream", "POST", {"command": stream, "timeoutSecs": 5})
        assert b"event: stdout" in streamed and b"data: stream-ok" in streamed
        assert b'"exitCode":0' in streamed
        result["checks"].append("text_sse_exit")
        denied = request(base, route + "/exec", "POST", {"command": network, "timeoutSecs": 5})
        assert denied["exitCode"] != 0
        result["checks"].append("public_tcp_egress_denied")
    finally:
        if identity is not None:
            current = request(base, route)
            assert current["createdAt"] == identity["createdAt"], "ownership changed"
            stopped = request(base, route + "/stop", "POST", {})
            assert stopped["state"] == "stopped"
            request(base, route, "DELETE")
            result["checks"].append("stop_delete")
    result["elapsed_seconds"] = round(time.monotonic() - start, 3)
    with artifact.open("rb") as artifact_file:
        result["artifact_sha256"] = hashlib.file_digest(artifact_file, "sha256").hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:19470")
    parser.add_argument("--python", type=pathlib.Path, required=True)
    parser.add_argument("--node", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    assert urllib.parse.urlparse(args.base).hostname in ("127.0.0.1", "localhost"), "probe requires loopback"
    health = request(args.base, "/health")
    assert health["version"] == "1.14.1"
    results = [qualify(args.base, args.python, "python"), qualify(args.base, args.node, "node")]
    report = {"kind": "phase0_smoke", "platform": platform.platform(), "runtime": health["version"], "results": results}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
