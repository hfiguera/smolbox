#!/usr/bin/env python3
"""Verify metadata tampering is rejected before engine construction; no VM boot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

from native_proof import save, snapshot


def prove(args):
    package = args.package.resolve()
    output = args.output.absolute()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    before = snapshot()
    manifest = json.loads((package / 'package.json').read_bytes())
    names = ['SMOLBOX-LICENSE', 'SMOLVM-LICENSE', 'SMOLVM-LICENSES.md', 'NATIVE-SOURCE.json']
    entries = {asset['path']: asset for asset in manifest['assets']}
    outcomes = {}
    for name in names:
        original = (package / name).read_bytes()
        assert entries[name]['sha256'] == hashlib.sha256(original).hexdigest()
        with tempfile.TemporaryDirectory(prefix='.metadata-proof-', dir=output) as root:
            copied = Path(root) / 'package'
            # Hard links keep large immutable templates sparse. Replace the one
            # owned copied directory entry before writing; never edit a shared inode.
            shutil.copytree(package, copied, copy_function=os.link, symlinks=True)
            target = copied / name
            target.unlink()
            target.write_bytes(bytes([original[0] ^ 1]) + original[1:])
            os.chmod(target, entries[name]['mode'])
            result = subprocess.run([str(copied / 'smolbox-port'), '--config',
                                     str(args.config.resolve())], stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=30)
            size, = struct.unpack('>I', result.stdout[:4])
            assert size <= 1024 * 1024 and len(result.stdout) == size + 4
            hello = json.loads(result.stdout[4:])
            assert hello['type'] == 'hello'
            assert hello['hello']['preflight'] == {'status': 'rejected', 'code': 'package'}
            assert hello['hello']['capabilities'] == [] and result.returncode != 0
            outcomes[name] = hello['hello']['preflight']
        assert (package / name).read_bytes() == original
    after = snapshot()
    assert after == before
    save(output / 'evidence.json', {'proof': 'passed', 'scope': 'native-metadata-integrity',
         'package_manifest_sha256': hashlib.sha256((package / 'package.json').read_bytes()).hexdigest(),
         'identity': manifest['identity'], 'metadata_rejections': outcomes,
         'original_assets_unchanged': True, 'inventory_before': before,
         'inventory_after': after, 'deliberate_process_interruption': False})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    prove(parser.parse_args())
