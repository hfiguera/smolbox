#!/usr/bin/env python3
"""Manual loopback TLS fault proxy for the disposable K3s qualification lab.

Never logs headers, tokens, request bodies or application output. Run serially
with an explicitly trusted local certificate and upstream CA. This is a test
instrument, not a Kubernetes ingress or a production credential relay.
"""
import argparse
import hashlib
import http.client
import http.server
import json
from pathlib import Path
import re
import socket
import ssl
import threading


def observed_uid(value):
    return value if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value) else None


class InputObservation:
    """Bounded, passive classification of reviewed SDK requests, never payload logging."""

    def __init__(self, helper_sha256):
        self.expected = helper_sha256
        self.wire = bytearray()
        self.stream = bytearray()
        self.done = False
        self.failed = False

    def feed(self, data):
        if self.done:
            return None
        self.wire.extend(data)
        try:
            if len(self.wire) > 131072:
                raise ValueError("wire bound")
            while len(self.wire) >= 2:
                first, second = self.wire[:2]
                if first not in (0x82, 0x88, 0x89, 0x8A) or not second & 0x80:
                    raise ValueError("unsupported client frame")
                size, offset = second & 0x7F, 2
                if size in (126, 127):
                    width = 2 if size == 126 else 8
                    if len(self.wire) < offset + width:
                        return None
                    size = int.from_bytes(self.wire[offset:offset + width], "big")
                    offset += width
                if size > 65536:
                    raise ValueError("client frame bound")
                if len(self.wire) < offset + 4 + size:
                    return None
                mask = self.wire[offset:offset + 4]
                start = offset + 4
                payload = bytes(value ^ mask[index % 4]
                                for index, value in enumerate(self.wire[start:start + size]))
                del self.wire[:start + size]
                if first != 0x82:
                    continue
                if not payload or payload[0] != 0:
                    raise ValueError("unsupported input channel")
                self.stream.extend(payload[1:])
                result = self.header()
                if result:
                    self.done = True
                    self.wire.clear()
                    self.stream.clear()
                    return result
        except (ValueError, KeyError, TypeError, UnicodeError):
            self.failed = self.done = True
            self.wire.clear()
            self.stream.clear()
        return None

    def header(self):
        if len(self.stream) > 1114128:
            raise ValueError("helper/control bound")
        if len(self.stream) < 8:
            return None
        if self.stream[:4] != b"SBP1":
            raise ValueError("helper envelope")
        size = int.from_bytes(self.stream[4:8], "big")
        if size > 65536:
            raise ValueError("helper size")
        if len(self.stream) < 16 + size:
            return None
        if hashlib.sha256(self.stream[8:8 + size]).hexdigest() != self.expected:
            raise ValueError("unreviewed helper")
        if self.stream[8 + size:12 + size] != b"SBK1":
            raise ValueError("control envelope")
        count = int.from_bytes(self.stream[12 + size:16 + size], "big")
        if count > 1048576:
            raise ValueError("control bound")
        if len(self.stream) < 16 + size + count:
            return None
        header = json.loads(self.stream[16 + size:16 + size + count])
        operation = header["operation"]
        if header["version"] != 1 or operation not in ("exec", "upload", "download"):
            raise ValueError("control operation")
        return operation


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def event(self, **fields):
        with self.server.trace_lock:
            with self.server.trace.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(fields, sort_keys=True) + "\n")

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def do_DELETE(self):
        self.forward()

    def forward(self):
        upstream = None
        try:
            if not self.path.startswith("/") or self.path.startswith("//"):
                raise ValueError("invalid origin path")
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 <= size <= 2_097_152 or self.headers.get("Transfer-Encoding"):
                raise ValueError("invalid request size")
            self.connection.settimeout(30)
            body = self.rfile.read(size)
            if len(body) != size:
                raise ValueError("short request")
            upstream = http.client.HTTPSConnection(
                "localhost", self.server.upstream_port, timeout=30,
                context=self.server.upstream_tls)
            upstream.request(self.command, self.path, body=body,
                             headers=dict(self.headers.items()))
            response = upstream.getresponse()
            exec_request = self.path.split("?", 1)[0].endswith("/exec")
            create = self.command == "POST" and self.path.endswith("/pods")
            self.event(method=self.command, exec=exec_request, create=create,
                       upstream_status=response.status)
            if self.command == "DELETE" and getattr(self.server, "helper_sha256", None):
                uid = observed_uid(json.loads(body).get("preconditions", {}).get("uid"))
                self.event(delete_precondition_uid=uid)
            if response.status == 101 and exec_request:
                self.send_response_only(101)
                for key, value in response.getheaders():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.flush()
                self.relay(upstream.sock)
                return
            data = response.read(2_097_153)
            if len(data) > 2_097_152:
                raise ValueError("oversized upstream response")
            if create and response.status == 201 and getattr(self.server, "helper_sha256", None):
                self.event(created_pod_uid=observed_uid(json.loads(data).get("metadata", {}).get("uid")))
            mode = self.server.mode
            if mode == "lost-create" and create and response.status == 201:
                self.event(fault="lost-create-response", pod_uid=json.loads(data)["metadata"]["uid"])
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            if mode == "replacement" and self.command == "GET" and response.status == 200:
                data = self.replace_container(data)
            self.send_response_only(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ("content-length", "transfer-encoding", "connection"):
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True
        except (OSError, ValueError, KeyError, http.client.HTTPException):
            self.close_connection = True
            self.event(transport_closed=True)
        finally:
            if upstream:
                upstream.close()

    def replace_container(self, data):
        obj = json.loads(data)
        statuses = obj.get("status", {}).get("containerStatuses", [])
        if obj.get("kind") == "Pod" and statuses and statuses[0].get("ready"):
            with self.server.trace_lock:
                self.server.ready_reads += 1
                replace = self.server.ready_reads >= 2
            if replace:
                statuses[0]["containerID"] = "containerd://" + "f" * 64
                data = json.dumps(obj).encode()
                self.event(fault="replacement-container-observation", pod_uid=obj["metadata"]["uid"])
        return data

    def relay(self, upstream):
        closed = threading.Event()
        expected = getattr(self.server, "helper_sha256", None)
        observation = InputObservation(expected) if expected else None

        def pump(source, destination, downstream):
            window = b""
            started = False
            try:
                while not closed.is_set():
                    chunk = source.recv(16_384)
                    if not chunk:
                        break
                    if not downstream and observation and not observation.done:
                        operation = observation.feed(chunk)
                        if operation:
                            self.event(exec_operation=operation)
                        elif observation.failed:
                            self.event(exec_operation_unavailable=True)
                    window = (window + chunk)[-512:]
                    if downstream and not started and b"started" in window:
                        self.event(application_marker_observed=True)
                        started = True
                    if downstream and self.server.mode == "lost-status" and b"fault-started" in window:
                        self.event(fault="lost-exec-status-after-application-marker")
                        break
                    destination.sendall(chunk)
            except OSError:
                pass
            finally:
                closed.set()
                for connection in (source, destination):
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        thread = threading.Thread(target=pump, args=(self.connection, upstream, False), daemon=True)
        thread.start()
        pump(upstream, self.connection, True)
        thread.join(timeout=1)
        self.close_connection = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("observe", "lost-create", "lost-status", "replacement"), required=True)
    parser.add_argument("--helper-sha256", help="reviewed guest helper digest; enables payload-free operation counts")
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--upstream-ca", required=True)
    parser.add_argument("--trace", required=True)
    parser.add_argument("--port", type=int, default=17644)
    parser.add_argument("--upstream-port", type=int, default=17643)
    args = parser.parse_args()
    if args.helper_sha256 and (len(args.helper_sha256) != 64 or any(char not in "0123456789abcdef" for char in args.helper_sha256)):
        parser.error("expected lowercase helper SHA-256")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Proxy)
    server.daemon_threads = True
    server.mode = args.mode
    server.upstream_port = args.upstream_port
    server.upstream_tls = ssl.create_default_context(cafile=args.upstream_ca)
    server.trace = Path(args.trace)
    server.trace_lock = threading.Lock()
    server.ready_reads = 0
    server.helper_sha256 = args.helper_sha256
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args.certificate, args.key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    print("Loopback TLS fault proxy ready", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
