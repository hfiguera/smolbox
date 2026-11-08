"""Pure fixture/auth models. Never invokes the fixture entry point or a VM."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / 'smolbox-engine/examples/proof_support/registry_fixture.py'
SPEC = importlib.util.spec_from_file_location('registry_fixture_models', PATH)
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)


class RegistryFixtureTests(unittest.TestCase):
    def test_growth_has_one_preparation_and_cold_warm_default_stays_exact(self):
        for mode, authenticated in [('anonymous', False), ('account-bearer', True)]:
            cold = FIXTURE.expected_counts(mode, 1)
            warm = FIXTURE.expected_counts(mode)
            self.assertEqual(cold['manifest'], 1)
            self.assertEqual(warm['manifest'], 2)
            self.assertEqual(cold['blob'], warm['blob'])
            self.assertEqual(cold['blob'], 1)
            self.assertEqual(cold['authorized'], 2 if authenticated else 0)
            self.assertEqual(warm['authorized'], 3 if authenticated else 0)
            self.assertEqual(cold['unauthorized'], warm['unauthorized'])
            self.assertEqual(cold['operator_rotations'], 1 if authenticated else 0)
        for count in (0, 3, -1, None, True, '1'):
            with self.assertRaises(ValueError):
                FIXTURE.expected_counts('anonymous', count)

    def test_exact_authorization_and_rotated_token_cannot_be_interchanged(self):
        self.assertTrue(FIXTURE.authorized('anonymous', 'ignored', None))
        self.assertFalse(FIXTURE.authorized('anonymous', 'ignored', 'Bearer private'))
        self.assertTrue(FIXTURE.authorized('account-bearer', 'second', 'Bearer second'))
        for header in (None, 'Bearer first', 'Basic second', 'bearer second'):
            self.assertFalse(FIXTURE.authorized('account-bearer', 'second', header))
        counts = FIXTURE.expected_counts('account-bearer')
        self.assertEqual(counts['authorization_present'], 3)
        self.assertEqual(counts['operator_rotations'], 1)
        self.assertEqual(counts['unauthorized'], 0)

    def test_private_config_has_original_key_and_loopback_mirror_without_alt_domain(self):
        body = FIXTURE.account_config(12345, 'private_token')
        self.assertIn(b'[machines.registries."registry.fixture.invalid"]', body)
        self.assertIn(b'mirror = "127.0.0.1:12345"', body)
        self.assertNotIn(b'HOME', body)
        self.assertNotIn(b'images', body)
        for port, token in [(0, 'private'), (65536, 'private'), (1, 'bad"config')]:
            with self.assertRaises(ValueError):
                FIXTURE.account_config(port, token)

    def test_config_writer_rotates_only_its_original_private_file_without_clobber(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / '.config/smolvm/config.toml'
            before = FIXTURE.write_account(path, b'first')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                FIXTURE.write_account(path, b'cannot-clobber')
            self.assertEqual(path.read_bytes(), b'first')
            # A failed no-clobber attempt retains its temporary for inspection.
            path.with_name('registry-fixture-next.toml').unlink()
            after = FIXTURE.write_account(path, b'second', before)
            self.assertNotEqual(before, after)
            self.assertEqual(path.read_bytes(), b'second')
            with self.assertRaises(RuntimeError):
                FIXTURE.write_account(path, b'cannot-replace', before)


if __name__ == '__main__':
    unittest.main()
