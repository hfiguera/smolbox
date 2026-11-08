"""Private request/framing models; no SDK, runtime or VM starts."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'smolbox-port/tests'))
spec = importlib.util.spec_from_file_location('branch_proof', ROOT / 'smolbox-port/tests/branch_proof.py')
branch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(branch)


def shuffled(value):
    if isinstance(value, dict):
        return {k: shuffled(v) for k, v in reversed(list(value.items()))}
    if isinstance(value, list):
        return [shuffled(v) for v in value]
    return value


class BranchRunnerTests(unittest.TestCase):
    def test_settings_are_private_bounded_and_ordinary_only_before_any_helper_io(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'settings.json'
            value = dict(package='/approved/package', manifest_sha256='a' * 64,
                         domain_json='/approved/domain.json',
                         artifact=dict(path='/approved/bare.smolmachine', sha256='b' * 64,
                                       max_bytes=1 << 30, guest_platform='linux/amd64'),
                         branch_approval=dict(id='ordinary-branches', host_overhead_mb=128,
                                              resources=dict(slots=1, cpus=1, memory_mb=640, disk_gb=5)))
            path.write_text(json.dumps(value))
            path.chmod(0o600)
            with patch.object(branch.os, 'uname', return_value=Mock(sysname='Linux', machine='x86_64')):
                self.assertEqual(branch.settings(path), value)
                path.write_text(json.dumps({**value, 'crash_mode': True}))
                with self.assertRaises(AssertionError):
                    branch.settings(path)
                path.write_text(json.dumps(value))
                path.chmod(0o644)
                with self.assertRaises(AssertionError):
                    branch.settings(path)
                path.chmod(0o600)
                link = Path(temporary) / 'redirected.json'
                link.symlink_to(path)
                with self.assertRaises(AssertionError):
                    branch.settings(link)
                path.write_bytes(b'x' * 65537)
                with self.assertRaises(AssertionError):
                    branch.settings(path)

    def test_frozen_backing_and_continuation_hashes_ignore_wire_map_order(self):
        for fixture, build in [('branch-backing-release-v1.json', branch.backing_request),
                               ('released-branch-deletion-continuation-v1.json', branch.continuation_request)]:
            rows = json.loads((ROOT / 'smolbox-protocol/fixtures' / fixture).read_bytes())
            for row in rows:
                r = row['request']
                with self.subTest(fixture=fixture):
                    args = [r['completion'], r.get('source', r.get('release')), r['child'], r['operation_id']]
                    self.assertEqual(build(*args), r)
                    self.assertEqual(build(*(shuffled(v) for v in args)), r)

    def test_canonical_shape_rejects_unknown_missing_or_substituted_fields(self):
        rows = json.loads((ROOT / 'smolbox-protocol/fixtures/branch-backing-release-v1.json').read_bytes())
        receipt = rows[0]['request']['source']
        with self.assertRaisesRegex(AssertionError, 'unknown'):
            branch.ordered({**receipt, 'extra': True}, 'receipt')
        with self.assertRaisesRegex(AssertionError, 'missing'):
            branch.ordered({k: v for k, v in receipt.items() if k != 'material'}, 'receipt')
        with self.assertRaises(AssertionError):
            branch.ordered([], 'receipt')

    def test_unknown_dispatch_cannot_replay_or_enter_a_fresh_quiesced_control(self):
        with tempfile.TemporaryDirectory() as temporary:
            port = Mock()
            p = branch.BranchProof(port, Path(temporary), {})
            p.members[1].update(state='running', receipt={'name': 'original-child'})
            port.call.side_effect = RuntimeError('private model: reply unavailable')
            with self.assertRaises(RuntimeError):
                p.observe(1, 'stop', ['running'], 'stopped')
            self.assertEqual(p.members[1]['state'], 'unknown')
            self.assertTrue(p.wire_unresolved)
            for action in ['stop-first', 'delete-first', 'continue-delete-first']:
                with self.assertRaisesRegex(AssertionError, 'cursor'):
                    p.control(action)
            p.control('status')
            self.assertEqual(port.call.call_count, 1)
            port.close.assert_not_called()
            port.process.kill.assert_not_called()
            port.process.terminate.assert_not_called()

    def test_predispatch_stop_restores_state_and_explicit_shutdown_preserves_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            port = Mock()
            p = branch.BranchProof(port, Path(temporary), {})
            p.members[0].update(state='running', receipt={'name': 'original-source'})
            port.call.return_value = ({'result': 'error', 'code': 'state', 'dispatch': 'not_dispatched'}, [])
            with self.assertRaises(AssertionError):
                p.observe(0, 'stop', ['running'], 'stopped')
            self.assertEqual(p.members[0]['state'], 'running')
            p.wire_unresolved = True
            p.control('shutdown-retained')
            self.assertTrue(p.closed)
            self.assertEqual(p.members[0]['receipt'], {'name': 'original-source'})
            self.assertEqual(p.members[0]['state'], 'running')
            port.close.assert_called_once_with()
            port.process.kill.assert_not_called()

    def test_unentered_siblings_allow_source_cleanup_but_unknown_children_do_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            p = branch.BranchProof(Mock(), Path(temporary), {})
            p.members[0]['state'] = 'stopped'
            p.observe = Mock()
            p.delete(0)
            p.observe.assert_called_once_with(0, 'delete', ['stopped', 'held'], 'missing')
            p.members[1]['state'] = 'unknown'
            with self.assertRaises(AssertionError):
                p.delete(0)
            self.assertEqual(p.observe.call_count, 1)

    def test_readiness_recovery_cannot_revive_a_child_after_later_unknown_lifecycle(self):
        with tempfile.TemporaryDirectory() as temporary:
            port = Mock()
            p = branch.BranchProof(port, Path(temporary), {})
            p.members[1].update(state='unknown', request={'original': True}, completion={'held': False})
            with self.assertRaises(AssertionError):
                p.resolve_ready(1)
            port.call.assert_not_called()

    def test_preflight_and_bare_commands_preserve_wire_budget_and_user_restrictions(self):
        with tempfile.TemporaryDirectory() as temporary:
            port = Mock()
            p = branch.BranchProof(port, Path(temporary), {})
            p.members[0].update(state='running', receipt={'name': 'source'})
            port.call.return_value = ({'result': 'observed', 'observation': {'state': 'running'}}, [])
            p.observe(0, 'branch_preflight', ['running'], 'running')
            self.assertEqual(port.call.call_args.kwargs['budget'], 30000)
            port.call.return_value = ({'result': 'command', 'completion': 'exited', 'observed_exit': 0}, [])
            p.command(0, 'true', b'')
            command = port.call.call_args.args[0]['command']
            self.assertIsNone(command['user'])
            self.assertEqual(command['workdir'], '/')

    def test_runner_is_opt_in_and_has_no_fault_or_process_signal_fallback(self):
        source = (ROOT / 'smolbox-port/tests/branch_proof.py').read_text()
        self.assertIn("commands.add_parser('ordinary')", source)
        self.assertIn("original_helper_retained", source)
        self.assertIn("except OSError:", source)
        for forbidden in ['.kill(', '.terminate(', 'os.kill(', 'fault_proof', 'SIGTERM', 'SIGKILL']:
            self.assertNotIn(forbidden, source)
        self.assertNotIn("add_parser('crash')", source)

    def test_control_read_failure_keeps_the_original_owner_until_explicit_shutdown(self):
        with tempfile.TemporaryDirectory() as temporary:
            port = Mock()
            port.process.poll.return_value = None
            p = branch.BranchProof(port, Path(temporary), {})
            connection = Mock()
            connection.__enter__ = Mock(return_value=connection)
            connection.__exit__ = Mock(return_value=False)
            connection.recv.side_effect = [b'shutdown-retained', b'']
            listener = Mock()
            listener.accept.side_effect = [OSError('private listener model'), (connection, None)]
            with patch.object(branch.time, 'sleep') as wait:
                branch.retain(p, listener)
            wait.assert_called_once_with(0.1)
            self.assertTrue(p.closed)
            port.close.assert_called_once_with()
            port.process.kill.assert_not_called()
            self.assertEqual(listener.accept.call_count, 2)


if __name__ == '__main__':
    unittest.main()
