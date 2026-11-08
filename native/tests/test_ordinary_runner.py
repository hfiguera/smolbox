"""Modeled ordinary-runner failures never force a VM owner to exit."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location(
    'native_proof', Path(__file__).resolve().parents[1] / 'smolbox-port/tests/native_proof.py')
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
ordinary_spec = importlib.util.spec_from_file_location(
    'ordinary_proof', Path(__file__).resolve().parents[1] / 'smolbox-port/tests/ordinary_proof.py')
ordinary = importlib.util.module_from_spec(ordinary_spec)
with patch.dict(sys.modules, {'native_proof': proof}):
    ordinary_spec.loader.exec_module(ordinary)


class OrdinaryRunnerTests(unittest.TestCase):
    def test_snapshot_allows_only_absent_sdk_root_and_never_initializes_partial_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.dict(proof.os.environ, {'XDG_DATA_HOME': str(root)}), \
                    patch.object(proof.os, 'uname', return_value=Mock(sysname='Linux')):
                self.assertEqual(proof.snapshot(), [])
                self.assertFalse((root / 'smolvm').exists())
                (root / 'smolvm').mkdir()
                with self.assertRaises(proof.sqlite3.OperationalError):
                    proof.snapshot()
                self.assertFalse((root / 'smolvm/server').exists())
                (root / 'smolvm').rmdir()
                (root / 'smolvm').symlink_to(root / 'missing')
                with self.assertRaisesRegex(AssertionError, 'redirected'):
                    proof.snapshot()

    def test_future_volume_handshake_matches_shared_fixture_without_enabling_current_package(self):
        root = Path(__file__).resolve().parents[1]
        hello = json.loads((root / 'smolbox-protocol/fixtures/hello-v2-volumes.json').read_bytes())['hello']
        policy = json.loads((root / 'policy.json').read_bytes())
        current = {'schema': 3, 'identity': hello['package'], 'policy': policy}
        self.assertNotIn('volumes', proof.capabilities(current))
        self.assertNotIn('volumes', proof.limits(current))
        future = json.loads(json.dumps(current))
        future['policy']['sdk'] = hello['sdk']
        self.assertEqual(proof.capabilities(future), hello['capabilities'])
        self.assertEqual(proof.limits(future), hello['limits'])
        future['policy']['sdk']['feature_versions']['remote_sources'] = 1
        capabilities = proof.capabilities(future)
        self.assertIn('prepare_artifact', capabilities)
        self.assertLess(capabilities.index('prepare_artifact'), capabilities.index('volumes'))
        self.assertNotIn('prepare_artifact', proof.capabilities(current))

    def test_current_handshake_matches_shared_fixture_and_older_descriptors_stay_smaller(self):
        root = Path(__file__).resolve().parents[1]
        hello = json.loads((root / 'smolbox-protocol/fixtures/hello-v2-current.json').read_bytes())['hello']
        policy = json.loads((root / 'policy.json').read_bytes())
        manifest = {'schema': 3, 'identity': hello['package'], 'policy': policy}
        self.assertEqual(proof.capabilities(manifest), hello['capabilities'])
        self.assertEqual(proof.limits(manifest), hello['limits'])
        older = json.loads(json.dumps(manifest))
        older['policy']['sdk']['feature_versions'] = {'material_proofs': 2}
        self.assertNotIn('terminal_open', proof.capabilities(older))
        self.assertNotIn('terminals', proof.limits(older))
        self.assertNotIn('jobs', proof.limits(older))
        future = json.loads(json.dumps(manifest))
        future['policy']['sdk']['feature_versions']['disk_growth'] = 1
        self.assertEqual(proof.capabilities(future)[:3], ['expand_disks', 'inspect_growth', 'qualify_growth'])
        self.assertNotIn('expand_disks', proof.capabilities(manifest))
        future['policy']['sdk']['feature_versions']['images'] = 1
        self.assertEqual(proof.capabilities(future)[0], 'list_images')
        self.assertEqual(len(proof.capabilities(future)), 26)
        self.assertNotIn('list_images', proof.capabilities(manifest))

    def test_manifest_selection_binds_protocol_config_sdk_and_engine(self):
        revision = '9f446ae00219148ca4a703914f44a8e2fab11655'
        identity = {'engine_version': '0.1.0', 'smolvm_revision': revision,
                    'platform': 'macos', 'architecture': 'aarch64'}
        self.assertEqual(proof.protocol({'schema': 1, 'identity': identity}), (1, 3))
        self.assertEqual(proof.protocol({'schema': 2, 'identity': identity,
                         'policy': {'port_protocol_minor': 4}}), (1, 4))
        policy = json.loads((Path(__file__).resolve().parents[1] / 'policy.json').read_bytes())
        current = {'schema': 3, 'identity': dict(identity, engine_version='0.2.0'), 'policy': policy}
        self.assertEqual(proof.protocol(current), (2, 0))
        self.assertEqual(proof.config_schema(current), 2)
        ordinary.check_upgrade(current, dict(current))
        for change in [dict(current, schema=2), dict(current, identity=identity)]:
            with self.assertRaises(AssertionError):
                proof.protocol(change)
        with self.assertRaisesRegex(AssertionError, 'fresh enrollment'):
            ordinary.check_upgrade(current, dict(current, schema=2))
        wrong = json.loads(json.dumps(current))
        wrong['policy']['sdk']['source_revision'] = '0' * 40
        with self.assertRaises(AssertionError):
            proof.protocol(wrong)

    def test_clean_upgrade_cannot_adopt_legacy_receipts_or_change_policy(self):
        identity = {name: 'fixture' for name in ['platform', 'architecture', 'engine_version', 'smolvm_revision']}
        clean = {'schema': 2, 'policy': {'domain_ownership': 'exclusive'}, 'identity': identity}
        legacy = {'schema': 1, 'identity': identity}
        with self.assertRaisesRegex(AssertionError, 'fresh enrollment'):
            ordinary.check_upgrade(legacy, clean)
        with self.assertRaisesRegex(AssertionError, 'fresh enrollment'):
            ordinary.check_upgrade(clean, legacy)
        with self.assertRaisesRegex(AssertionError, 'native policy'):
            ordinary.check_upgrade(clean, dict(clean, policy={'domain_ownership': 'different'}))
        ordinary.check_upgrade(clean, dict(clean))

    def test_unresolved_graceful_exit_records_diagnostics_without_forcing_or_deleting(self):
        with tempfile.TemporaryDirectory() as temporary:
            port = proof.Port.__new__(proof.Port)
            port.error_path = Path(temporary) / 'helper.stderr'
            port.errors = Mock()
            port.process = Mock(pid=123)
            port.process.wait.side_effect = subprocess.TimeoutExpired('modeled-helper', 10)
            with self.assertRaisesRegex(RuntimeError, 'preserve authority'):
                port.graceful_exit()
            port.process.stdin.close.assert_called_once()
            port.process.kill.assert_not_called()
            port.process.terminate.assert_not_called()
            port.errors.close.assert_not_called()
            evidence = json.loads(Path(str(port.error_path) + '.retained.json').read_text())
            self.assertFalse(evidence['deletion_authority'])
            self.assertFalse(evidence['forced_termination'])
            self.assertFalse(evidence['crash_handling_qualified'])

    def test_startup_rejection_uses_eof_and_normal_collection(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = Mock()
            process.wait.return_value = 2  # Normal preflight rejection.
            with patch.dict(proof.os.environ, {'LD_PRELOAD': '/fixture/injected', 'DYLD_INSERT_LIBRARIES': '/fixture/injected'}), \
                    patch.object(proof.subprocess, 'Popen', return_value=process) as spawn, \
                    patch.object(proof.Port, 'receive', return_value={'type': 'invalid'}):
                with self.assertRaisesRegex(AssertionError, 'package not ready'):
                    proof.Port(Path(temporary), Path(temporary) / 'config',
                               Path(temporary) / 'helper.stderr')
            self.assertNotIn('LD_PRELOAD', spawn.call_args.kwargs['env'])
            self.assertNotIn('DYLD_INSERT_LIBRARIES', spawn.call_args.kwargs['env'])
            process.stdin.close.assert_called_once()
            process.wait.assert_called_once_with(timeout=10)
            process.kill.assert_not_called()
            process.terminate.assert_not_called()

    def test_broken_pipe_does_not_prevent_normal_collection(self):
        port = proof.Port.__new__(proof.Port)
        port.errors = Mock()
        port.process = Mock()
        port.process.stdin.close.side_effect = BrokenPipeError()
        port.process.wait.return_value = 0
        self.assertEqual(port.graceful_exit(), 0)
        port.errors.close.assert_called_once()
        port.process.kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
