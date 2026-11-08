#!/usr/bin/env python3
"""Build a local, separately pinned native package; never publish or download."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import tempfile
import tomllib

import importlib.util

_ROOTFS_SPEC = importlib.util.spec_from_file_location('smolbox_rootfs_archive', Path(__file__).with_name('rootfs_archive.py'))
rootfs_archive = importlib.util.module_from_spec(_ROOTFS_SPEC)
_ROOTFS_SPEC.loader.exec_module(rootfs_archive)

ROOT = Path(__file__).resolve().parent
METADATA = ['SMOLBOX-LICENSE', 'SMOLVM-LICENSE', 'SMOLVM-LICENSES.md', 'NATIVE-SOURCE.json', 'SMOLBOX-POLICY.json']
MAX_FILES = 16384
MAX_METADATA = 4 * 1024 * 1024
TEMPLATE_BYTES = 1024 ** 3
ENGINE_VERSION = tomllib.loads((ROOT / 'Cargo.toml').read_text())['workspace']['package']['version']


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def policy_path():
    # Match the target-specific policy compiled into smolbox-port. There is no
    # operator switch that can enable a feature on an unsupported platform.
    system = platform.system()
    if system not in ('Linux', 'Darwin'):
        raise ValueError('unsupported native package platform')
    return ROOT / ('policy-linux.json' if system == 'Linux' else 'policy.json')


def resize_tool():
    prefixes = ['/opt/homebrew/opt/e2fsprogs/sbin', '/usr/local/opt/e2fsprogs/sbin', '/opt/homebrew/sbin', '/usr/local/sbin', '/sbin', '/usr/sbin']
    prefixes += os.environ.get('PATH', '').split(os.pathsep)
    for prefix in prefixes:
        path = Path(prefix) / 'resize2fs'
        if path.is_absolute() and path.is_file() and os.access(path, os.X_OK):
            return path
    raise ValueError('resize2fs is required to prepare the disk templates')


def clone_file(source, target):
    # Preserve sparse allocation and never modify input runtime assets.
    command = ['cp', '-c', str(source), str(target)] if platform.system() == 'Darwin' else ['cp', '--reflink=auto', '--sparse=always', str(source), str(target)]
    subprocess.run(command, check=True, capture_output=True, timeout=120)


def compress_template(source, target):
    tool = shutil.which('zstd')
    if tool is None:
        raise ValueError('zstd is required to package matching compressed templates')
    subprocess.run([tool, '--quiet', '--threads=1', '-o', str(target), str(source)],
                   check=True, capture_output=True, timeout=120)


def template_at_baseline(path):
    if path.stat().st_size != TEMPLATE_BYTES:
        return False
    with path.open('rb') as stream:
        stream.seek(1024)
        superblock = stream.read(1024)
    if len(superblock) != 1024 or struct.unpack_from('<H', superblock, 56)[0] != 0xef53:
        return False
    low, = struct.unpack_from('<I', superblock, 4)
    log, = struct.unpack_from('<I', superblock, 24)
    incompat, = struct.unpack_from('<I', superblock, 96)
    high = struct.unpack_from('<I', superblock, 336)[0] if incompat & 0x80 else 0
    return log <= 6 and (low | (high << 32)) * (1024 << log) == TEMPLATE_BYTES


def prepare_owned_template(path, tool):
    # resize2fs -f can rewrite metadata even when the size is unchanged. Preserve
    # already approved baseline bytes across compatible package rebuilds.
    if template_at_baseline(path):
        return
    subprocess.run([str(tool), '-f', str(path), '1048576K'],
                   check=True, capture_output=True, timeout=120)
    with path.open('r+b') as file:
        file.truncate(TEMPLATE_BYTES)
    if not template_at_baseline(path):
        raise ValueError('resized template geometry does not match the package baseline')


def prepare_export_libraries(directory):
    # The SDK pack format uses the versioned firmware name. Existing Linux
    # runtime bundles may contain only the loader's unversioned copy. Materialize
    # an independent, byte-identical alias inside this owned package; no input or
    # library load path is rewritten. Both copies enter manifest approval.
    if platform.system() != 'Darwin' and not (directory / 'libkrunfw.so.5').exists():
        shutil.copy2(directory / 'libkrunfw.so', directory / 'libkrunfw.so.5')


def inventory(root):
    entries = []
    for directory in [root / 'lib', root / 'agent-rootfs']:
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                entries.append({'kind': 'symlink', 'path': path.relative_to(root).as_posix(), 'target': os.readlink(path)})
            elif path.is_file() and not path.name.startswith('.smolvm-ready.'):
                entries.append({'kind': 'file', 'path': path.relative_to(root).as_posix(), 'sha256': digest(path), 'bytes': path.stat().st_size, 'mode': path.stat().st_mode & 0o777})
    optional = ['agent-rootfs.tar'] if (root / 'agent-rootfs.tar').exists() else []
    for name in ['storage-template.ext4', 'overlay-template.ext4', 'storage-template.ext4.zst', 'overlay-template.ext4.zst', *METADATA, *optional]:
        path = root / name
        entries.append({'kind': 'file', 'path': name, 'sha256': digest(path), 'bytes': path.stat().st_size, 'mode': path.stat().st_mode & 0o777})
    entries.sort(key=lambda entry: entry['path'])
    if len(entries) > MAX_FILES:
        raise ValueError('too many package assets')
    return entries


def build(executable, assets, output, signing_identity=None):
    executable, assets, output = executable.resolve(), assets.resolve(), output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('package destination already exists')
    output.parent.mkdir(parents=True, exist_ok=True)
    tool = resize_tool()
    if signing_identity is not None and (platform.system() != 'Darwin' or not signing_identity.strip() or signing_identity == '-'):
        raise ValueError('an explicit distribution identity requires macOS')
    with tempfile.TemporaryDirectory(prefix='.smolbox-package-', dir=output.parent) as temporary:
        staging = Path(temporary) / 'package'
        staging.mkdir(mode=0o755)
        shutil.copy2(executable, staging / 'smolbox-port')
        # Cached Cargo outputs can be group-writable. Package permissions must
        # satisfy native executable ownership checks independently of that cache.
        (staging / 'smolbox-port').chmod(0o755)
        # Libraries are dereferenced so no rewrite/load can escape to the source.
        shutil.copytree(assets / 'lib', staging / 'lib', symlinks=False)
        prepare_export_libraries(staging / 'lib')
        shutil.copytree(assets / 'agent-rootfs', staging / 'agent-rootfs', symlinks=True,
                        ignore=shutil.ignore_patterns('.smolvm-ready.*'))
        rootfs_archive.create(staging / 'agent-rootfs', staging / 'agent-rootfs.tar')
        for name in ['storage-template.ext4', 'overlay-template.ext4']:
            clone_file(assets / name, staging / name)
            # First-release package templates are an empty 1 GiB baseline. The
            # runtime extends them for larger admitted disks. Shrink only these
            # owned clones; never the caller's templates or any VM disk.
            prepare_owned_template(staging / name, tool)
            # Compressed fallback must expand to the exact approved plain bytes,
            # including the resized geometry, rather than the input's old size.
            compress_template(staging / name, staging / (name + '.zst'))
        if platform.system() == 'Darwin':
            entitlement = staging / '.hypervisor.plist'
            entitlement.write_text('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>')
            identity = signing_identity or '-'
            if signing_identity:
                for library in sorted((staging / 'lib').glob('*.dylib')):
                    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp', str(library)], check=True, capture_output=True, timeout=60)
            signing = ['/usr/bin/codesign', '--force', '--sign', identity, '--entitlements', str(entitlement)]
            if signing_identity:
                signing += ['--options', 'runtime', '--timestamp']
            subprocess.run(signing + [str(staging / 'smolbox-port')], check=True, capture_output=True, timeout=60)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staging / 'smolbox-port')], check=True, capture_output=True, timeout=30)
            entitlement.unlink()
        source = json.loads((ROOT / 'vendor/source.json').read_text())
        shutil.copy2(ROOT.parent / 'LICENSE', staging / 'SMOLBOX-LICENSE')
        shutil.copy2(ROOT / 'target/upstream/smolvm/LICENSE', staging / 'SMOLVM-LICENSE')
        shutil.copy2(ROOT / 'target/upstream/smolvm/Licenses.md', staging / 'SMOLVM-LICENSES.md')
        shutil.copy2(ROOT / 'vendor/source.json', staging / 'NATIVE-SOURCE.json')
        shutil.copy2(policy_path(), staging / 'SMOLBOX-POLICY.json')
        entries = inventory(staging)
        identity = {'engine_version': ENGINE_VERSION, 'smolvm_revision': source['revision'], 'source_sha256': digest(ROOT / 'vendor/source.json'),
                    'build_sha256': digest(staging / 'smolbox-port'), 'assets_sha256': hashlib.sha256(compact(entries)).hexdigest(),
                    'platform': 'macos' if platform.system() == 'Darwin' else 'linux',
                    'architecture': {'arm64': 'aarch64', 'x86_64': 'x86_64'}[platform.machine()]}
        manifest = {'schema': 3, 'policy': json.loads(policy_path().read_bytes()),
                    'identity': identity, 'assets': entries, 'host_tools': [{'path': str(tool), 'sha256': digest(tool)}]}
        body = compact(manifest)
        if len(body) > MAX_METADATA:
            raise ValueError('package manifest exceeds limit')
        (staging / 'package.json').write_bytes(body)
        # All copied license/source metadata is covered by the approved manifest.
        # Firmware/kernel source correspondence and license delivery remain separate.
        os.rename(staging, output)
        return {'package': str(output), 'manifest_sha256': digest(output / 'package.json'), 'identity': identity}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--signing-identity', help='explicit macOS signing identity; default is development ad-hoc signing')
    args = parser.parse_args()
    print(json.dumps(build(args.executable, args.assets, args.output, args.signing_identity)))


if __name__ == '__main__':
    main()
