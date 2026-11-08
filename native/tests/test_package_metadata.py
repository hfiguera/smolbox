"""Builder policy is included in the approved asset inventory."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('smolbox_package', Path(__file__).resolve().parents[1] / 'package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageMetadataTests(unittest.TestCase):
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
