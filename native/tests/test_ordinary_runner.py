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
    def test_request_observation_uses_one_budget_for_acceptance_and_terminal(self):
        port = proof.Port.__new__(proof.Port)
        port.next_id = 0
        port.hello = {'epoch': 'a' * 32}
        port.send = Mock()
        port.receive = Mock(side_effect=[
            {'type': 'accepted', 'epoch': 'a' * 32, 'id': 1, 'sequence': 0},
            {'type': 'terminal', 'epoch': 'a' * 32, 'id': 1, 'sequence': 1,
             'outcome': {'result': 'qualified'}}])
        with patch.object(proof.time, 'monotonic', side_effect=[100, 100.25, 140]):
            self.assertEqual(port.call({'operation': 'model'}, budget=120000),
                             ({'result': 'qualified'}, []))
        self.assertEqual([c.args[0] for c in port.receive.call_args_list], [124.75, 85])

    def test_request_and_frame_readers_never_refresh_an_expired_deadline(self):
        port = proof.Port.__new__(proof.Port)
        port.next_id = 0
        port.hello = {'epoch': 'a' * 32}
        port.send = Mock()
        port.receive = Mock()
        with patch.object(proof.time, 'monotonic', side_effect=[100, 106]):
            with self.assertRaisesRegex(AssertionError, 'observation deadline'):
                port.call({'operation': 'model'}, budget=1000)
        port.receive.assert_not_called()
        del port.receive
        port.exact = Mock(return_value=b'\x00\x00\x00\x02')
        with patch.object(proof.time, 'monotonic', side_effect=[100, 102]):
            with self.assertRaisesRegex(AssertionError, 'frame deadline'):
                port.receive(timeout=1)
        port.exact.assert_called_once_with(4, 1)

    def test_terminal_preflight_requires_exact_nonstreaming_unmutated_evidence(self):
        receipt = {'name': 'owned-model'}
        port = Mock()
        with patch.object(ordinary.os, 'uname', return_value=Mock(sysname='Linux')), \
                patch.object(ordinary, 'children', return_value={23}), \
                patch.object(ordinary, 'snapshot', return_value=['original']), \
                patch.object(ordinary, 'observed') as inspect_state:
            port.call.return_value = ({'result': 'ready'}, [])
            evidence = ordinary.terminal_preflight(port, receipt, 'stopped')
            self.assertTrue(evidence['owned_children_unchanged'])
            port.call.assert_called_once_with(
                {'operation': 'terminal_preflight', 'receipt': receipt}, budget=2000)
            inspect_state.assert_called_once_with(port, 'inspect', receipt, 'stopped')
            port.call.return_value = ({'result': 'ready'}, [('stdout', b'unexpected')])
            with self.assertRaisesRegex(AssertionError, 'events'):
                ordinary.terminal_preflight(port, receipt, 'stopped')
            port.call.return_value = ({'result': 'ready'}, [])
            with patch.object(ordinary, 'snapshot', side_effect=[['original'], ['changed']]):
                with self.assertRaisesRegex(AssertionError, 'records'):
                    ordinary.terminal_preflight(port, receipt, 'stopped')
            with patch.object(ordinary, 'children', side_effect=[{23}, {23, 24}]):
                with self.assertRaisesRegex(AssertionError, 'children'):
                    ordinary.terminal_preflight(port, receipt, 'stopped')
            port.call.return_value = ({'result': 'error', 'code': 'not_found',
                                      'dispatch': 'not_dispatched'}, [])
            ordinary.terminal_preflight(port, receipt, 'missing')
            port.call.return_value = ({'result': 'ready'}, [])
            with self.assertRaises(AssertionError):
                ordinary.terminal_preflight(port, receipt, 'missing')
        port.process.kill.assert_not_called()
        port.process.terminate.assert_not_called()

    def test_observability_qualification_rejects_a_successful_but_inconsistent_inventory(self):
        port = Mock()
        port.call.side_effect = [
            ({'result': 'health', 'snapshot': {'total': 1, 'running': 0}}, []),
            ({'result': 'capacity', 'snapshot': {'allocated_cpus': 0, 'allocated_memory_mb': 0}}, []),
            ({'result': 'metrics', 'text': 'smolbox_native_machines 1\n'
              'smolbox_native_running_machines 0\nsmolbox_native_allocated_cpus 0\n'
              'smolbox_native_allocated_memory_mb 0\n'}, []),
            ({'result': 'ready'}, []),
            ({'result': 'inventory', 'count': 1, 'bytes': 2}, [('file', b'[]')])]
        with self.assertRaises(AssertionError):
            ordinary.observe_native(port, 'stopped', {'cpus': 1, 'memory_mib': 512},
                                    {'name': 'owned-model'})
        # A successful terminal alone cannot turn contradictory inventory into
        # lifecycle evidence, and observer failure never signals its owner.
        port.process.kill.assert_not_called()
        port.process.terminate.assert_not_called()

    def test_export_sdk_qualification_is_opt_in_and_never_redirects_a_database_fixture(self):
        root = Path(__file__).resolve().parents[1]
        main = (root / 'smolbox-port/src/main.rs').read_text()
        source = (root / 'smolbox-port/src/ordinary_export.rs').read_text()
        self.assertIn('#[cfg(test)]\nmod ordinary_export;', main)
        self.assertRegex(source, r'#\[ignore\s*=\s*"explicit ordinary SDK/package/default-domain export fixture; may start one owned helper VM"\]\s*fn ordinary_owned_container_conversion')
        self.assertRegex(source, r'assert!\(\s*!config\.allow_initialize')
        self.assertIn('engine::DomainBinding::default_paths', source)
        self.assertIn('engine::Engine::open_with_host(binding, false, host)', source)
        self.assertNotIn('test_engine(', source)
        self.assertNotIn('std::env::set_var', source)
        self.assertNotIn('std::env::remove_var', source)
        self.assertIn('retry-cleanup', source)
        self.assertIn('file.take(6)', source)
        self.assertNotIn('.kill(', source)
        self.assertNotIn('.terminate(', source)

    def test_template_growth_qualification_is_explicit_and_never_opens_a_domain(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'smolbox-engine/src/machine.rs').read_text()
        annotation = '#[ignore = "explicit approved account-template disk qualification; no manager, domain owner or VM"]'
        self.assertIn(annotation, source)
        fixture = source.split('fn ordinary_approved_template_format_and_growth_without_vm()', 1)[1].split('    #[test]', 1)[0]
        self.assertIn('SMOLBOX_TEMPLATE_GROWTH_APPROVAL', fixture)
        self.assertIn('SMOLBOX_TEMPLATE_GROWTH_OUTPUT', fixture)
        self.assertIn('find_existing_template', fixture)
        self.assertNotIn('AgentManager::', fixture)
        self.assertNotIn('Engine::', fixture)
        self.assertNotIn('std::env::set_var', fixture)
        self.assertNotIn('std::env::remove_var', fixture)

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
        self.assertIn('prepare_artifact', proof.capabilities(current))

    def test_linux_package_policy_advertises_exact_saved_state_handshake(self):
        root = Path(__file__).resolve().parents[1]
        hello = json.loads((root / 'smolbox-protocol/fixtures/hello-v2-linux-branches-preflight.json').read_bytes())['hello']
        policy = json.loads((root / 'policy-linux.json').read_bytes())
        manifest = {'schema': 3, 'identity': hello['package'], 'policy': policy}
        self.assertEqual(proof.capabilities(manifest), hello['capabilities'])
        self.assertEqual(proof.limits(manifest), hello['limits'])
        self.assertEqual(policy['volume_limits'], hello['limits']['volumes'])
        self.assertEqual(proof.capabilities(manifest)[:5],
                         ['list_images', 'pull_image', 'expand_disks', 'inspect_growth', 'qualify_growth'])
        self.assertEqual(policy['sdk']['feature_versions']['branches'], 1)
        self.assertEqual(policy['sdk']['feature_versions']['checkpoints'], 1)
        self.assertNotIn('partial_cleanup_resolution', policy['sdk']['feature_versions'])

    def test_current_handshake_matches_shared_fixture_and_older_descriptors_stay_smaller(self):
        root = Path(__file__).resolve().parents[1]
        hello = json.loads((root / 'smolbox-protocol/fixtures/hello-v2-macos-branches.json').read_bytes())['hello']
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
        self.assertEqual(proof.capabilities(future)[:5],
                         ['list_images', 'pull_image', 'expand_disks', 'inspect_growth', 'qualify_growth'])
        self.assertNotIn('expand_disks', proof.capabilities(manifest))
        self.assertIn('list_images', proof.capabilities(manifest))
        self.assertIn('pull_image', proof.capabilities(manifest))
        self.assertIn('prepare_artifact', proof.capabilities(manifest))
        legacy = json.loads(json.dumps(manifest))
        legacy['policy']['sdk'] = json.loads((root / 'smolbox-protocol/fixtures/hello-v2-terminal-preflight.json').read_bytes())['hello']['sdk']
        for operation in ['list_images', 'pull_image', 'prepare_artifact']:
            self.assertNotIn(operation, proof.capabilities(legacy))

    def test_preflight_does_not_reinterpret_older_terminal_descriptors(self):
        root = Path(__file__).resolve().parents[1]
        for name in ['hello-v2-current.json', 'hello-v2-linux-current.json']:
            hello = json.loads((root / 'smolbox-protocol/fixtures' / name).read_bytes())['hello']
            manifest = {'schema': 3, 'identity': hello['package'],
                        'policy': {'schema': 2, 'port_protocol_major': 2,
                                   'port_protocol_minor': 0, 'sdk': hello['sdk']}}
            self.assertEqual(proof.capabilities(manifest), hello['capabilities'])
            self.assertNotIn('terminal_preflight', proof.capabilities(manifest))
            self.assertIn('terminal_open', proof.capabilities(manifest))

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
                    patch.object(proof.Port, 'receive', return_value={'type': 'invalid'}) as receive:
                with self.assertRaisesRegex(AssertionError, 'package not ready'):
                    proof.Port(Path(temporary), Path(temporary) / 'config',
                               Path(temporary) / 'helper.stderr')
            self.assertNotIn('LD_PRELOAD', spawn.call_args.kwargs['env'])
            self.assertNotIn('DYLD_INSERT_LIBRARIES', spawn.call_args.kwargs['env'])
            receive.assert_called_once_with(120)
            process.stdin.close.assert_called_once()
            process.wait.assert_called_once_with(timeout=10)
            process.kill.assert_not_called()
            process.terminate.assert_not_called()

    def test_unresolved_collection_preserves_the_startup_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = Mock()
            process.pid = 123
            process.wait.side_effect = subprocess.TimeoutExpired('helper', 10)
            with patch.object(proof.subprocess, 'Popen', return_value=process), \
                    patch.object(proof.Port, 'receive', side_effect=AssertionError('frame deadline')):
                with self.assertRaisesRegex(AssertionError, 'frame deadline') as failure:
                    proof.Port(Path(temporary), Path(temporary) / 'config',
                               Path(temporary) / 'helper.stderr')
            self.assertIsInstance(failure.exception.__cause__, RuntimeError)
            self.assertIn('preserve authority', str(failure.exception.__cause__))
            process.stdin.close.assert_called_once()
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
