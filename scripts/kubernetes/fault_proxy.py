#!/usr/bin/env python3
"""Manual loopback TLS fault proxy for the disposable K3s qualification lab.

Never logs headers, tokens, request bodies or application output. Run serially
with an explicitly trusted local certificate and upstream CA. This is a test
instrument, not a Kubernetes ingress or a production credential relay.
"""
import argparse
import http.client
import http.server
import json
from pathlib import Path
import socket
import ssl
import threading


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

        def pump(source, destination, downstream):
            window = b""
            try:
                while not closed.is_set():
                    chunk = source.recv(16_384)
                    if not chunk:
                        break
                    window = (window + chunk)[-512:]
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
    parser.add_argument("--mode", choices=("lost-create", "lost-status", "replacement"), required=True)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--upstream-ca", required=True)
    parser.add_argument("--trace", required=True)
    parser.add_argument("--port", type=int, default=17644)
    parser.add_argument("--upstream-port", type=int, default=17643)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Proxy)
    server.daemon_threads = True
    server.mode = args.mode
    server.upstream_port = args.upstream_port
    server.upstream_tls = ssl.create_default_context(cafile=args.upstream_ca)
    server.trace = Path(args.trace)
    server.trace_lock = threading.Lock()
    server.ready_reads = 0
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
