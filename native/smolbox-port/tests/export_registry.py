"""Loopback-only immutable OCI peer for the explicit ordinary export witness."""
from contextlib import contextmanager
from hashlib import file_digest, sha256
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import re
import secrets
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

REPO = 'proof/export'
PREFIX = '/v2/' + REPO + '/'
TAG = 'ordinary-proof'
ARTIFACT_LIMIT = 128 << 20
CHUNK_LIMIT = 1 << 20
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
REFERENCE = re.compile(r'[a-z0-9][a-z0-9._-]{0,127}\Z')


def digest(body):
    return 'sha256:' + sha256(body).hexdigest()


@contextmanager
def registry(*, anonymous_pull=False):
    """Keep blobs on disk; never log headers or token bytes."""
    with tempfile.TemporaryDirectory(prefix='smolbox-export-registry-') as directory:
        root = Path(directory)
        token = secrets.token_hex(32)
        uploads, blobs, manifests = {}, {}, {}
        counts = dict.fromkeys(('heads', 'uploads', 'chunks', 'blobs', 'manifests', 'reads', 'rejected'), 0)

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def response(self, status, length=0, **headers):
                self.send_response(status)
                self.send_header('Content-Length', str(length))
                for name, value in headers.items():
                    self.send_header(name.replace('_', '-'), str(value))
                self.end_headers()

            def reject(self, status=400):
                counts['rejected'] += 1
                self.response(status)

            def route(self):
                headers = self.headers.get_all('Authorization', [])
                public_read = anonymous_pull and not headers and self.command in ('GET', 'HEAD')
                if not public_read and (len(headers) != 1 or not secrets.compare_digest(headers[0], 'Bearer ' + token)):
                    self.reject(401)
                    return None
                url = urlsplit(self.path)
                if url.scheme or url.netloc or url.fragment or not url.path.startswith(PREFIX):
                    self.reject(404)
                    return None
                self.connection.settimeout(5)
                return url.path[len(PREFIX):], parse_qs(url.query)

            def body(self, limit):
                lengths = self.headers.get_all('Content-Length', [])
                if len(lengths) != 1 or not lengths[0].isdigit() or self.headers.get('Transfer-Encoding'):
                    raise ValueError('missing fixture length')
                size = int(lengths[0])
                if not 0 <= size <= limit:
                    raise ValueError('fixture length exceeds bound')
                body = self.rfile.read(size)
                if len(body) != size:
                    raise ValueError('short fixture body')
                return body

            def fetch(self, head):
                route = self.route()
                if route is None:
                    return
                path, query = route
                kind, _, key = path.partition('/')
                if query or kind not in ('manifests', 'blobs'):
                    return self.reject(404)
                counts['heads' if head else 'reads'] += 1
                if kind == 'manifests' and key in manifests:
                    media, body = manifests[key]
                    self.response(200, len(body), Content_Type=media, Docker_Content_Digest=digest(body))
                    if not head:
                        self.wfile.write(body)
                elif kind == 'blobs' and key in blobs:
                    file = blobs[key]
                    self.response(200, file.stat().st_size, Content_Type='application/octet-stream',
                                  Docker_Content_Digest=key)
                    if not head:
                        with file.open('rb') as source:
                            while chunk := source.read(64 << 10):
                                self.wfile.write(chunk)
                else:
                    self.response(404)

            def do_HEAD(self):
                self.fetch(True)

            def do_GET(self):
                self.fetch(False)

            def do_POST(self):
                route = self.route()
                if route is None:
                    return
                try:
                    if route != ('blobs/uploads/', {}) or len(uploads) + len(blobs) >= 2 or self.body(0):
                        return self.reject()
                except ValueError:
                    return self.reject()
                name = f'blobs/uploads/{counts["uploads"] + 1}'
                file = root / str(counts['uploads'] + 1)
                with file.open('xb'):
                    pass
                uploads[name] = file
                counts['uploads'] += 1
                self.response(202, Location=PREFIX + name)

            def do_PATCH(self):
                route = self.route()
                if route is None:
                    return
                name, query = route
                if query or name not in uploads:
                    return self.reject()
                file = uploads[name]
                offset = file.stat().st_size
                try:
                    body = self.body(CHUNK_LIMIT)
                except ValueError:
                    return self.reject()
                end = offset + len(body) - 1
                if not body or end >= ARTIFACT_LIMIT or self.headers.get('Content-Range') != f'{offset}-{end}':
                    return self.reject()
                with file.open('ab') as target:
                    target.write(body)
                counts['chunks'] += 1
                self.response(202, Location=PREFIX + name, Range=f'0-{end}')

            def do_PUT(self):
                route = self.route()
                if route is None:
                    return
                name, query = route
                try:
                    if name in uploads:
                        key, = query.get('digest', [])
                        if set(query) != {'digest'} or not DIGEST.fullmatch(key) or key in blobs or self.body(0):
                            return self.reject()
                        file = uploads[name]
                        with file.open('rb') as source:
                            actual = 'sha256:' + file_digest(source, 'sha256').hexdigest()
                        if key != actual:
                            return self.reject()
                        blobs[key] = uploads.pop(name)
                        counts['blobs'] += 1
                    elif name.startswith('manifests/') and not query:
                        key = name.removeprefix('manifests/')
                        if key in manifests:
                            return self.reject(412)
                        body = self.body(CHUNK_LIMIT)
                        if DIGEST.fullmatch(key):
                            if key != digest(body):
                                return self.reject()
                        elif not REFERENCE.fullmatch(key) or self.headers.get('If-None-Match') != '*':
                            return self.reject()
                        media = self.headers.get('Content-Type')
                        if media not in ('application/vnd.oci.image.manifest.v1+json',
                                         'application/vnd.oci.image.index.v1+json'):
                            return self.reject()
                        manifests[key] = (media, body)
                        counts['manifests'] += 1
                        key = digest(body)
                    else:
                        return self.reject()
                except ValueError:
                    return self.reject()
                self.response(201, Docker_Content_Digest=key)

        with HTTPServer(('127.0.0.1', 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                yield f'127.0.0.1:{server.server_port}', token, counts
            finally:
                server.shutdown()
                thread.join()


def approval(address):
    key = ['smolbox-export-destination-v1', 'ordinary-loopback', address, REPO, True, True, None]
    return {
        'id': key[1], 'registry': address, 'repository': REPO, 'credential_ref': 'fixture-token',
        'immutable_tags': True, 'allow_insecure_loopback': True,
        'destination_sha256': sha256(json.dumps(key, separators=(',', ':')).encode()).hexdigest(),
        'max_artifact_bytes': ARTIFACT_LIMIT, 'max_staging_bytes': 64 << 30,
        'conversion_resources': {'slots': 1, 'cpus': 4, 'memory_mb': 1152, 'disk_gb': 64},
    }


def verify(address, token, identity):
    """Read back both immutable tags, both blobs and the digest-addressed manifest."""
    assert identity['registry'] == address and identity['repository'] == REPO and identity['tag'] == TAG

    host, port = address.split(':')
    assert host == '127.0.0.1' and 0 < int(port) <= 65535

    @contextmanager
    def fetch(route):
        connection = HTTPConnection(host, int(port), timeout=5)
        try:
            connection.request('GET', PREFIX + route, headers={'Authorization': 'Bearer ' + token})
            with connection.getresponse() as response:
                assert response.status == 200
                yield response
        finally:
            connection.close()

    def get(route, expected, limit=CHUNK_LIMIT):
        with fetch(route) as response:
            body = response.read(limit + 1)
        assert len(body) <= limit and digest(body) == 'sha256:' + expected
        return body

    manifest_sha = identity['manifest_sha256']
    index = json.loads(get('manifests/' + TAG, identity['index_sha256']))
    descriptor, = index['manifests']
    assert descriptor['digest'] == 'sha256:' + manifest_sha
    manifest = get('manifests/sha256:' + manifest_sha, manifest_sha)
    assert get('manifests/' + identity['platform_tag'], manifest_sha) == manifest
    parsed = json.loads(manifest)
    layer, = parsed['layers']
    assert layer['digest'] == 'sha256:' + identity['content_sha256']
    assert layer['size'] == identity['size_bytes']
    config = parsed['config']
    assert config['digest'] == 'sha256:' + identity['config_sha256']
    assert len(get('blobs/' + config['digest'], identity['config_sha256'])) == config['size']
    size, h = 0, sha256()
    with fetch('blobs/' + layer['digest']) as response:
        while data := response.read(64 << 10):
            size += len(data)
            assert size <= ARTIFACT_LIMIT
            h.update(data)
    assert size == layer['size'] and h.hexdigest() == identity['content_sha256']
