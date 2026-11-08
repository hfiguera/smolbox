"""Builder policy is included in the approved asset inventory."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('smolbox_package', Path(__file__).resolve().parents[1] / 'package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageMetadataTests(unittest.TestCase):
    def test_build_normalizes_cached_executable_without_changing_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            builder = root / 'native'
            (builder / 'vendor').mkdir(parents=True)
            upstream = builder / 'target/upstream/smolvm'
            upstream.mkdir(parents=True)
            (root / 'LICENSE').write_text('application license')
            for name in ('LICENSE', 'Licenses.md'):
                (upstream / name).write_text('upstream licenses')
            (builder / 'vendor/source.json').write_text(json.dumps({'revision': 'a' * 40}))
            (builder / 'policy.json').write_text('{}')
            assets = root / 'assets'
            (assets / 'lib').mkdir(parents=True)
            (assets / 'lib/libkrunfw.so').write_bytes(b'firmware')
            (assets / 'agent-rootfs').mkdir()
            for name in ('storage-template.ext4', 'overlay-template.ext4'):
                (assets / name).write_bytes(b'template')
            executable = root / 'cached-helper'
            executable.write_bytes(b'approved helper bytes')
            executable.chmod(0o775)
            tool = root / 'resize2fs'
            tool.write_bytes(b'approved resize tool')
            output = root / 'package'
            def compress(source, target):
                target.write_bytes(b'compressed template')
            with mock.patch.object(package, 'ROOT', builder), \
                 mock.patch.object(package.platform, 'system', return_value='Linux'), \
                 mock.patch.object(package.platform, 'machine', return_value='x86_64'), \
                 mock.patch.object(package, 'resize_tool', return_value=tool), \
                 mock.patch.object(package, 'clone_file', side_effect=package.shutil.copy2), \
                 mock.patch.object(package, 'prepare_owned_template'), \
                 mock.patch.object(package, 'compress_template', side_effect=compress):
                original_umask = os.umask(0o002)
                try:
                    result = package.build(executable, assets, output)
                finally:
                    os.umask(original_umask)
            self.assertEqual(output.stat().st_mode & 0o777, 0o755)
            self.assertEqual((output / 'smolbox-port').stat().st_mode & 0o777, 0o755)
            self.assertEqual(executable.stat().st_mode & 0o777, 0o775)
            self.assertEqual((output / 'smolbox-port').read_bytes(), executable.read_bytes())
            self.assertEqual(result['identity']['build_sha256'], package.digest(executable))
            self.assertEqual(result['manifest_sha256'], package.digest(output / 'package.json'))

    def test_policy_and_source_are_independently_hash_bound_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'lib').mkdir()
            (root / 'agent-rootfs').mkdir()
            for name in ['storage-template.ext4', 'overlay-template.ext4',
                         'storage-template.ext4.zst', 'overlay-template.ext4.zst', *package.METADATA]:
                contents = (package.ROOT / 'policy.json').read_bytes() if name == 'SMOLBOX-POLICY.json' else name.encode()
                (root / name).write_bytes(contents)
            entries = {entry['path']: entry for entry in package.inventory(root)}
            policy = entries['SMOLBOX-POLICY.json']
            self.assertEqual(policy['sha256'], hashlib.sha256((package.ROOT / 'policy.json').read_bytes()).hexdigest())
            self.assertIn('NATIVE-SOURCE.json', entries)
            self.assertFalse(json.loads((root / 'SMOLBOX-POLICY.json').read_bytes())['rustler_enabled'])
            (root / 'SMOLBOX-POLICY.json').write_bytes(b'altered policy')
            changed = {entry['path']: entry for entry in package.inventory(root)}
            self.assertNotEqual(policy['sha256'], changed['SMOLBOX-POLICY.json']['sha256'])


if __name__ == '__main__':
    unittest.main()
