"""Bounded stdlib WebSocket v5 probe for the manual lab, never a backend client."""

import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import tempfile
import time
import urllib.parse

from smoke import require, run


class Connection:
    def __init__(self, namespace, pod, command, timeout=20):
        self.deadline = time.monotonic() + timeout
        self.socket = None
        self.pending = b""
        self.temporary = tempfile.TemporaryDirectory(prefix="smolbox-ws-")
        try:
            config = json.loads(run(["/usr/local/bin/kubectl", "config", "view", "--raw", "-o", "json"]).stdout)
            selected = next(c["context"] for c in config["contexts"] if c["name"] == config["current-context"])
            cluster = next(c["cluster"] for c in config["clusters"] if c["name"] == selected["cluster"])
            user = next(c["user"] for c in config["users"] if c["name"] == selected["user"])
            server = urllib.parse.urlparse(cluster["server"])
            require(server.scheme == "https" and server.hostname == "127.0.0.1", "lab loopback API required")
            context = ssl.create_default_context(cadata=base64.b64decode(cluster["certificate-authority-data"]).decode())
            for name, field in [("cert", "client-certificate-data"), ("key", "client-key-data")]:
                path = Path(self.temporary.name) / name
                path.write_bytes(base64.b64decode(user[field]))
                path.chmod(0o600)
            context.load_cert_chain(str(Path(self.temporary.name) / "cert"), str(Path(self.temporary.name) / "key"))
            raw = socket.create_connection((server.hostname, server.port or 443), timeout=self.remaining())
            raw.settimeout(self.remaining())
            self.socket = context.wrap_socket(raw, server_hostname=server.hostname)
            query = urllib.parse.urlencode([("container", "workload"), ("stdin", "false"),
                                            ("stdout", "true"), ("stderr", "true"), ("tty", "false")]
                                           + [("command", arg) for arg in command])
            path = f"/api/v1/namespaces/{namespace}/pods/{pod}/exec?{query}"
            key = base64.b64encode(os.urandom(16)).decode()
            self.socket.settimeout(self.remaining())
            self.socket.sendall((f"GET {path} HTTP/1.1\r\nHost: {server.netloc}\r\n"
                                 "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
                                 f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Protocol: v5.channel.k8s.io\r\n\r\n").encode())
            while b"\r\n\r\n" not in self.pending:
                require(len(self.pending) < 16384, "oversized upgrade headers")
                self.socket.settimeout(self.remaining())
                chunk = self.socket.recv(4096)
                require(chunk, "upgrade connection lost")
                self.pending += chunk
            headers, self.pending = self.pending.split(b"\r\n\r\n", 1)
            require(len(headers) <= 16384, "oversized upgrade headers")
            lines = headers.decode("ascii").split("\r\n")
            require(lines[0].split()[1] == "101", "WebSocket upgrade rejected")
            fields = dict((k.lower(), v.strip()) for k, v in (line.split(":", 1) for line in lines[1:]))
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            require(fields.get("sec-websocket-accept") == expected, "invalid WebSocket accept")
            require(fields.get("sec-websocket-protocol") == "v5.channel.k8s.io", "v5 negotiation required")
        except BaseException:
            self.close()
            raise

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "WebSocket probe deadline expired")
        return remaining

    def read(self, size):
        while len(self.pending) < size:
            self.socket.settimeout(self.remaining())
            chunk = self.socket.recv(min(65536, size - len(self.pending)))
            require(chunk, "WebSocket connection lost")
            self.pending += chunk
        value, self.pending = self.pending[:size], self.pending[size:]
        return value

    def send(self, opcode, payload):
        require(len(payload) <= 125, "probe sends control frames only")
        mask = os.urandom(4)
        self.socket.settimeout(self.remaining())
        self.socket.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask +
                            bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload)))

    def collect(self):
        streams = {1: bytearray(), 2: bytearray(), 3: bytearray()}
        message = bytearray()
        active = False
        while True:
            first, second = self.read(2)
            require(not first & 0x70 and not second & 0x80, "invalid server frame flags")
            final, opcode, size = bool(first & 0x80), first & 15, second & 127
            if size == 126:
                size = struct.unpack("!H", self.read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.read(8))[0]
            require(size <= 1048576, "probe frame limit exceeded")
            payload = self.read(size)
            if opcode >= 8:
                require(final and size <= 125, "invalid control frame")
                if opcode == 8:
                    break
                require(opcode in (9, 10), "unknown control opcode")
                if opcode == 9:
                    self.send(10, payload)
                continue
            require(opcode in (0, 2) and ((opcode == 0) == active), "invalid fragmented message")
            active = not final
            message.extend(payload)
            require(len(message) <= 1048576, "probe message limit exceeded")
            if not final:
                continue
            require(message, "missing channel byte")
            channel, data = message[0], message[1:]
            message.clear()
            if channel == 255:
                require(len(data) == 1 and data[0] in (1, 2, 3), "invalid channel closure")
                continue
            require(channel in streams, "unexpected remotecommand channel")
            streams[channel].extend(data)
            require(sum(len(s) for s in streams.values()) <= 1048576, "probe output limit exceeded")
            require(len(streams[3]) <= 8192, "probe status limit exceeded")
        require(not active and streams[3], "complete exec status required")
        status = json.loads(streams[3])
        if status.get("status") == "Success":
            code = 0
        else:
            require(status.get("reason") == "NonZeroExitCode", "workload exit status required")
            causes = [c["message"] for c in status.get("details", {}).get("causes", []) if c.get("reason") == "ExitCode"]
            require(len(causes) == 1, "one exit code required")
            code = int(causes[0])
            require(0 < code < 256, "invalid exit code")
        return {"protocol": "v5.channel.k8s.io", "exit_code": code,
                "stdout": bytes(streams[1]), "stderr": bytes(streams[2]), "status": status}

    def close(self):
        if self.socket is not None:
            self.socket.close()
        self.temporary.cleanup()


def execute(namespace, pod, command):
    connection = Connection(namespace, pod, command)
    try:
        return connection.collect()
    finally:
        connection.close()
