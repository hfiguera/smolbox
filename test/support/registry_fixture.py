"""Loopback-only OCI fixture for real-worker prepared artifact qualification.

This serves one existing .smolmachine file; it cannot build or publish images.
Use an isolated worker cache and stop the process after qualification.
"""

import argparse
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    artifact = args.artifact.resolve(strict=True)
    content_digest = sha256_file(artifact)
    config = b"{}"
    config_digest = hashlib.sha256(config).hexdigest()
    manifest = json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "artifactType": "application/vnd.smolmachines.smolmachine.v1",
            "config": {
                "mediaType": "application/vnd.smolmachines.machine.config.v1+json",
                "digest": "sha256:" + config_digest,
                "size": len(config),
            },
            "layers": [{
                "mediaType": "application/vnd.smolmachines.smolmachine.v1",
                "digest": "sha256:" + content_digest,
                "size": artifact.stat().st_size,
            }],
        },
        separators=(",", ":"),
    ).encode()
    manifest_digest = hashlib.sha256(manifest).hexdigest()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.respond(head=False)

        def do_HEAD(self):
            self.respond(head=True)

        def respond(self, head):
            if self.path in ("/v2", "/v2/"):
                self.reply(b"{}", "application/json", head)
            elif self.path == "/v2/qualification/app/manifests/sha256:" + manifest_digest:
                self.reply(manifest, "application/vnd.oci.image.manifest.v1+json", head)
            elif self.path == "/v2/qualification/app/blobs/sha256:" + config_digest:
                self.reply(config, "application/octet-stream", head)
            elif self.path == "/v2/qualification/app/blobs/sha256:" + content_digest:
                self.blob(head)
            else:
                self.send_error(404)

        def reply(self, body, content_type, head):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Docker-Content-Digest", "sha256:" + hashlib.sha256(body).hexdigest())
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def blob(self, head):
            size = artifact.stat().st_size
            offset = 0
            requested_range = self.headers.get("Range")
            if requested_range:
                try:
                    if not requested_range.startswith("bytes=") or not requested_range.endswith("-"):
                        raise ValueError("only suffix-free ranges are supported")
                    offset = int(requested_range[6:-1])
                    if not 0 <= offset < size:
                        raise ValueError("range outside blob")
                except ValueError:
                    self.send_error(416)
                    return
            self.send_response(206 if requested_range else 200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size - offset))
            self.send_header("Docker-Content-Digest", "sha256:" + content_digest)
            if requested_range:
                self.send_header("Content-Range", f"bytes {offset}-{size - 1}/{size}")
            self.end_headers()
            if not head:
                with artifact.open("rb") as source:
                    source.seek(offset)
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        self.wfile.write(chunk)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    args.output.write_text(json.dumps({
        "pid": os.getpid(),
        "reference": f"127.0.0.1:{server.server_port}/qualification/app@sha256:{manifest_digest}",
        "manifest_sha256": manifest_digest,
        "content_sha256": content_digest,
        "size_bytes": artifact.stat().st_size,
    }) + "\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
