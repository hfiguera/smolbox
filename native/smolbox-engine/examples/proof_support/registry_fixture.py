#!/usr/bin/env python3
"""Explicit immutable OCI registry test fixture plus ordinary engine witness.

This fixture serves approved artifact bytes only. It has no SDK/control-plane
handlers, mutation routes, process signals or timeout teardown. The optional
account-bearer mode exercises private operator config/mirror/token rotation.
Default checks never invoke this live entry point.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import pwd
import secrets
import stat
import subprocess
import threading
from datetime import datetime, timezone


REGISTRY = 'registry.fixture.invalid'


def account_config(port, token):
    if not 0 < port < 65536 or not token or any(
            char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-'
            for char in token):
        raise ValueError('invalid private fixture config')
    return (f'[machines.registries."{REGISTRY}"]\n'
            f'mirror = "127.0.0.1:{port}"\n'
            'username = "token"\n'
            f'password = "{token}"\n').encode()


def write_account(path, body, previous=None):
    # The fixture receives only a fresh real account, never another SDK domain or
    # an alternate HOME. The operator config is independent of SDK persistence.
    for parent in (path.parent.parent, path.parent):
        parent.mkdir(mode=0o700, exist_ok=True)
        info = parent.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) & 0o022):
            raise RuntimeError('unsafe operator config directory')
    if previous is not None and signature(path.lstat()) != previous:
        raise RuntimeError('operator config changed outside fixture')
    temporary = path.with_name('registry-fixture-next.toml')
    with temporary.open('xb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    if previous is None:
        # Atomic no-clobber publication for the first private operator config.
        os.link(temporary, path, follow_symlinks=False)
        temporary.unlink()
    else:
        os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return signature(path.lstat())


def authorized(mode, expected, header):
    return header is None if mode == 'anonymous' else header == 'Bearer ' + expected


def expected_counts(mode, preparations=2):
    if type(preparations) is not int or preparations not in (1, 2):
        raise ValueError('expected one or two explicit source preparations')
    protected = mode == 'account-bearer'
    return {'manifest': preparations, 'blob': 1, 'other': 0,
            'authorization_present': preparations + 1 if protected else 0,
            'authorized': preparations + 1 if protected else 0, 'unauthorized': 0,
            'operator_rotations': 1 if protected else 0, 'stream_errors': 0}


def save(path, value):
    with path.open('x') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def signature(value):
    return (value.st_dev, value.st_ino, value.st_size, value.st_mode,
            value.st_uid, value.st_nlink, value.st_mtime_ns, value.st_ctime_ns)


def digest(descriptor, size):
    result = hashlib.sha256()
    for offset in range(0, size, 65536):
        chunk = os.pread(descriptor, min(65536, size - offset), offset)
        if not chunk:
            raise RuntimeError('approved fixture became short')
        result.update(chunk)
    return result.hexdigest()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('witness', 'package', 'domain-json', 'artifact', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--artifact-sha256', required=True)
    parser.add_argument('--mode', choices=('anonymous', 'account-bearer'), default='anonymous')
    parser.add_argument('--preparations', type=int, choices=(1, 2), default=2,
                        help='exact source preparations: growth uses one; cold/warm images use two')
    args = parser.parse_args()
    if os.geteuid() == 0 or Path.home() != Path(pwd.getpwuid(os.geteuid()).pw_dir):
        raise RuntimeError('genuine non-root account/default home required')
    if 'SMOLVM_CONFIG' in os.environ or os.environ.get('XDG_DATA_HOME'):
        raise RuntimeError('alternate operator config is not a fixture account')
    for path in (args.witness, args.package, args.domain_json, args.artifact):
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise RuntimeError('canonical approved inputs required')
    if (not args.output.is_absolute() or args.output.resolve() != args.output
            or len(str(args.output / 'ordinary')) > 88):
        raise RuntimeError('normalized bounded original output required')
    args.output.mkdir(mode=0o700)
    artifact = os.open(args.artifact, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    before = os.fstat(artifact)
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
            or stat.S_IMODE(before.st_mode) & 0o222 or before.st_nlink != 1
            or not 0 < before.st_size <= 128 * 1024 * 1024
            or digest(artifact, before.st_size) != args.artifact_sha256):
        raise RuntimeError('immutable approved fixture identity differs')
    manifest = json.dumps({
        'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'artifactType': 'application/vnd.smolmachines.smolmachine.v1',
        'config': {
            'mediaType': 'application/vnd.smolmachines.machine.config.v1+json',
            'digest': 'sha256:' + hashlib.sha256(b'{}').hexdigest(), 'size': 2,
        },
        'layers': [{
            'mediaType': 'application/vnd.smolmachines.smolmachine.v1',
            'digest': 'sha256:' + args.artifact_sha256, 'size': before.st_size,
        }],
    }, separators=(',', ':')).encode()
    manifest_sha = hashlib.sha256(manifest).hexdigest()
    paths = {
        '/v2/team/ordinary/manifests/sha256:' + manifest_sha: 'manifest',
        '/v2/team/ordinary/blobs/sha256:' + args.artifact_sha256: 'blob',
    }
    counts = dict.fromkeys(expected_counts(args.mode, args.preparations), 0)
    tokens = [secrets.token_urlsafe(32), secrets.token_urlsafe(32)]
    generation = 0
    config = Path.home() / '.config/smolvm/config.toml'
    config_version = None

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # Never persist raw headers/URLs/credentials.

        def do_GET(self):
            nonlocal generation, config_version
            kind = paths.get(self.path)
            headers = self.headers.get_all('Authorization', [])
            if headers:
                counts['authorization_present'] += 1
            if (len(headers) > 1 or not authorized(args.mode, tokens[generation],
                                                  headers[0] if headers else None)):
                counts['unauthorized'] += 1
                kind = None
            elif args.mode == 'account-bearer':
                counts['authorized'] += 1
            if kind is None:
                counts['other'] += 1
                self.send_error(404)
                return
            counts[kind] += 1
            if signature(os.fstat(artifact)) != signature(before):
                self.send_error(500)
                return
            if kind == 'blob' and args.mode == 'account-bearer':
                # Blob dispatch proves the first operation has finished reading
                # its account snapshot. Rotate before releasing the blob body,
                # so the warm operation cannot race config publication.
                if generation != 0:
                    raise RuntimeError('unexpected repeated artifact download')
                config_version = write_account(config, account_config(server.server_port, tokens[1]), config_version)
                generation = 1
                counts['operator_rotations'] += 1
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.oci.image.manifest.v1+json'
                             if kind == 'manifest' else 'application/octet-stream')
            self.send_header('Content-Length', str(len(manifest) if kind == 'manifest'
                                                   else before.st_size))
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                if kind == 'manifest':
                    self.wfile.write(manifest)
                else:
                    for offset in range(0, before.st_size, 65536):
                        self.wfile.write(os.pread(artifact, min(65536, before.st_size - offset), offset))
            except (OSError, TimeoutError):
                counts['stream_errors'] += 1

    class Server(HTTPServer):
        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(5)
            return connection, address

    server = Server(('127.0.0.1', 0), Handler)
    registry = f'127.0.0.1:{server.server_port}' if args.mode == 'anonymous' else REGISTRY
    if args.mode == 'account-bearer':
        if config.exists() or config.is_symlink() or config.with_name('registries.toml').exists():
            raise RuntimeError('fresh account operator configuration required')
        body = account_config(server.server_port, tokens[0])
        config_version = write_account(config, body)
        with (args.output / 'operator-config-initial.toml').open('xb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
    reference = (f'{registry}/team/ordinary'
                 f'@sha256:{manifest_sha}')
    settings = {
        'package': str(args.package), 'manifest_sha256': args.manifest_sha256,
        'domain_json': str(args.domain_json),
        'source': {'reference': reference, 'platform': 'linux/amd64',
                   'content_sha256': args.artifact_sha256},
        'max_bytes': before.st_size,
        'cache_policy': {'max_bytes': 2 * before.st_size, 'max_files': 2},
    }
    save(args.output / 'settings.json', settings)
    save(args.output / 'fixture-intent.json', {
        'source': settings['source'], 'artifact_bytes': before.st_size,
        'mode': args.mode, 'expected_requests': expected_counts(args.mode, args.preparations),
        'source_preparations': args.preparations,
        'operator_mirror': args.mode == 'account-bearer',
        'credential_material_recorded_in_headers_or_argv': False,
    })
    thread = threading.Thread(target=server.serve_forever,
                              kwargs={'poll_interval': 0.1})
    thread.start()
    try:
        with (args.output / 'ordinary.log').open('x') as log:
            process = subprocess.Popen([
                str(args.witness), 'run-registry', str(args.output / 'settings.json'),
                str(args.output / 'ordinary')], stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT)
            birth = (Path('/proc') / str(process.pid) / 'stat').read_text().rsplit(')', 1)[1].split()[19]
            save(args.output / 'witness-handle.json', {'pid': process.pid, 'birth': birth})
            # A failed witness retains its original engine/control socket. Keep
            # this fixture reachable until explicit normal cleanup closes it.
            code = process.wait()
    finally:
        server.shutdown()
        thread.join()
        server.server_close()
    immutable = (signature(os.fstat(artifact)) == signature(before)
                 and digest(artifact, before.st_size) == args.artifact_sha256)
    os.close(artifact)
    expected = expected_counts(args.mode, args.preparations)
    passed = code == 0 and immutable and counts == expected
    save(args.output / 'fixture-result.json', {
        'status': 'passed' if passed else 'failed', 'witness_exit_status': code,
        'counts': counts, 'fixture_unchanged': immutable,
        'mode': args.mode,
        'source_preparations': args.preparations,
        'operator_bearer_mirror_qualified': passed and args.mode == 'account-bearer',
        'operator_bearer_mirror_rotation_qualified': (passed and args.mode == 'account-bearer'
                                                      and args.preparations == 2),
        'all_credential_modes_qualified': False,
        'normal_fixture_shutdown': True, 'forced_termination': False,
        'crash_validation_performed': False,
        'finished_utc': datetime.now(timezone.utc).isoformat(),
    })
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
