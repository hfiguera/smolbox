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
            for name in ('LICENSE', 'THIRD-PARTY-NOTICES.md'):
                (upstream / name).write_text('upstream licenses')
            (builder / 'vendor/source.json').write_text(json.dumps({'revision': 'a' * 40}))
            (builder / 'policy.json').write_text('{}')
            (builder / 'policy-linux.json').write_text('{"linux_fixture":true}')
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
            self.assertEqual(json.loads((output / 'SMOLBOX-POLICY.json').read_bytes()), {'linux_fixture': True})
            self.assertEqual(json.loads((output / 'package.json').read_bytes())['policy'], {'linux_fixture': True})
            self.assertEqual(output.stat().st_mode & 0o777, 0o755)
            self.assertEqual((output / 'smolbox-port').stat().st_mode & 0o777, 0o755)
            self.assertEqual(executable.stat().st_mode & 0o777, 0o775)
            self.assertEqual((output / 'smolbox-port').read_bytes(), executable.read_bytes())
            self.assertEqual(result['identity']['build_sha256'], package.digest(executable))
            self.assertEqual(result['manifest_sha256'], package.digest(output / 'package.json'))

    def test_platform_policy_matches_exact_shared_descriptor_and_linux_storage_delta(self):
        common = json.loads((package.ROOT / 'policy.json').read_bytes())
        linux = json.loads((package.ROOT / 'policy-linux.json').read_bytes())
        hello = json.loads((package.ROOT / 'smolbox-protocol/fixtures/hello-v2-linux-branches-preflight.json').read_bytes())['hello']
        expected = json.loads(json.dumps(common))
        self.assertEqual(common['sdk']['feature_versions']['remote_sources'], 1)
        self.assertEqual(common['sdk']['feature_versions']['images'], 1)
        expected['sdk']['feature_versions']['volumes'] = 1
        expected['sdk']['feature_versions']['disk_growth'] = 1
        expected['sdk']['feature_versions']['checkpoints'] = 1
        expected['sdk']['feature_versions']['branches'] = 1
        expected['sdk']['feature_versions']['partial_collection_preflight'] = 1
        expected['sdk']['feature_versions']['branch_static_egress'] = 1
        expected['sdk']['feature_versions']['branch_https_credentials'] = 1
        expected['volume_limits'] = hello['limits']['volumes']
        self.assertEqual(linux, expected)
        hello['sdk']['feature_versions']['exports'] = 1
        hello['sdk']['feature_versions']['branch_release_env'] = 1
        hello['sdk']['feature_versions']['branch_static_egress'] = 1
        hello['sdk']['feature_versions']['branch_https_credentials'] = 1
        self.assertEqual(linux['sdk']['feature_versions'], hello['sdk']['feature_versions'])
        with (package.ROOT / 'Cargo.toml').open('rb') as manifest:
            version = package.tomllib.load(manifest)['workspace']['dependencies']['smolvm']['version']
        source = json.loads((package.ROOT / 'vendor/source.json').read_bytes())
        self.assertEqual(linux['sdk']['sdk_version'], version.removeprefix('='))
        self.assertEqual(linux['sdk']['source_revision'], source['revision'])
        for system, filename in [('Linux', 'policy-linux.json'), ('Darwin', 'policy.json')]:
            with self.subTest(system=system), mock.patch.object(package.platform, 'system', return_value=system):
                self.assertEqual(package.policy_path(), package.ROOT / filename)
        with mock.patch.object(package.platform, 'system', return_value='Windows'):
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                package.policy_path()

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
