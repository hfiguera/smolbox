#!/usr/bin/env python3
"""Assemble a candidate release archive from an existing native package and demo image."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def build(tag, package, demo, output, notices=None):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*)?', tag):
        raise ValueError('expected an explicit release tag')
    package, demo, output = package.resolve(strict=True), demo.resolve(strict=True), output.absolute()
    if package.name != 'package' or not package.is_dir():
        raise ValueError('stage the native directory under the name package')
    if output.exists() or output.is_symlink() or output.is_relative_to(package):
        raise ValueError('output must be a new path outside the native package')
    manifest = package / 'package.json'
    identity = json.loads(manifest.read_bytes())['identity']
    target = (identity['platform'], identity['architecture'])
    if target not in [('macos', 'aarch64'), ('linux', 'x86_64'), ('linux', 'aarch64')]:
        raise ValueError('unsupported native package platform')
    asset = f'smolbox-embedded-{target[0]}-{target[1]}.tar.gz'
    if output.name != asset:
        raise ValueError(f'output must be named {asset}')

    with tempfile.TemporaryDirectory(prefix='.smolbox-release-', dir=output.parent) as temporary:
        staging = Path(temporary)
        shutil.copyfile(demo, staging / 'demo.smolmachine')
        metadata = dict(schema=1, tag=tag, manifest_sha256=sha256(manifest),
                        demo_sha256=sha256(staging / 'demo.smolmachine'))
        companion_files = ['release.json', 'demo.smolmachine']
        if notices is not None:
            name = 'third-party-notices.tar.gz'
            shutil.copyfile(notices, staging / name)
            metadata['notices_sha256'] = sha256(staging / name)
            companion_files.append(name)
        (staging / 'release.json').write_text(json.dumps(metadata, sort_keys=True) + '\n')
        archive = staging / output.name
        flags = ['--sparse'] if platform.system() == 'Linux' else []
        subprocess.run(['tar', *flags, '-czf', str(archive), '-C', str(package.parent), 'package',
                        '-C', str(staging), *companion_files], check=True)
        os.link(archive, output)
    return dict(asset=output.name, sha256=sha256(output), **metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--package', required=True, type=Path)
    parser.add_argument('--demo', required=True, type=Path)
    parser.add_argument('--notices', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    options = parser.parse_args()
    print(json.dumps(build(options.tag, options.package, options.demo, options.output, options.notices), sort_keys=True))


if __name__ == '__main__':
    main()
