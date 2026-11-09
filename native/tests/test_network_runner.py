"""Qualification setup must reject ambiguous network and owner observations."""
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1] / 'smolbox-port/tests'


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


with patch.dict(sys.modules):
    for name in ['native_proof', 'ordinary_proof', 'network_fixture']:
        sys.modules[name] = load(name)
    fixture = sys.modules['network_fixture']
    network = load('network_proof')


class NetworkRunnerTests(unittest.TestCase):
    def test_default_network_namespace_rejects_before_any_network_configuration(self):
        with patch.object(fixture.os, 'uname', return_value=SimpleNamespace(
                sysname='Linux', nodename='smolbox-nested')), \
                patch.object(fixture.os, 'geteuid', return_value=0), \
                patch.object(fixture.Path, 'readlink', return_value=Path('same-netns')), \
                patch.object(fixture.subprocess, 'check_output') as inspect:
            with self.assertRaisesRegex(AssertionError, 'unshare'):
                fixture.require_namespace()
            inspect.assert_not_called()

    def test_unprivileged_proof_requires_the_verified_namespace_handoff(self):
        with patch.object(fixture.os, 'uname', return_value=SimpleNamespace(
                sysname='Linux', nodename='smolbox-nested')), \
                patch.object(fixture.os, 'geteuid', return_value=1000), \
                patch.object(fixture.Path, 'readlink', return_value=Path('owned-netns')), \
                patch.object(fixture.subprocess, 'check_output') as inspect:
            for identity in [None, 'different-netns']:
                with self.assertRaisesRegex(AssertionError, 'verified namespace identity'):
                    fixture.require_namespace(identity)
            inspect.assert_not_called()

    def test_short_responder_reply_cannot_be_a_positive_control_for_denial(self):
        peer = Mock()
        peer.__enter__ = Mock(return_value=peer)
        peer.__exit__ = Mock(return_value=False)
        peer.recv.side_effect = [fixture.RESPONSE[:5], b'']
        with patch.object(fixture.socket, 'create_connection', return_value=peer):
            with self.assertRaisesRegex(AssertionError, 'complete witness'):
                fixture.positive_controls()

    def test_privileged_fixture_cannot_launch_the_sdk_as_root(self):
        with patch.object(network, 'require_namespace'), \
                patch.object(network.os, 'geteuid', return_value=0), \
                patch.object(network, 'Port') as owner:
            with self.assertRaisesRegex(AssertionError, 'approved lab account'):
                network.prove(SimpleNamespace())
            owner.assert_not_called()

    def test_wrong_child_identity_rejects_before_loopback_configuration(self):
        with patch.object(fixture, 'require_namespace'), \
                patch.object(fixture.os, 'geteuid', return_value=0), \
                patch.object(fixture.subprocess, 'run') as configure:
            with self.assertRaises(AssertionError):
                fixture.run(['/usr/bin/python3', 'wrong-root-proof'])
            configure.assert_not_called()

    def test_native_timeout_is_not_an_observed_guest_policy_denial(self):
        port = Mock()
        port.call.return_value = ({'result': 'command', 'completion': 'timed_out'}, [])
        with self.assertRaises(AssertionError):
            network.command(port, {'name': 'private-model'}, ['ordinary-model'])
        port.process.kill.assert_not_called()
        port.process.terminate.assert_not_called()

    def test_ordinary_network_tools_have_no_forced_exit_or_fault_runner(self):
        for name in ['network_fixture.py', 'network_proof.py']:
            source = (ROOT / name).read_text()
            for forbidden in ['.kill(', '.terminate(', 'os.kill(', 'fault_proof', 'kill_after',
                              'start_new_session=True', '--ignored']:
                self.assertNotIn(forbidden, source)
        self.assertIn("'--isolated-lab-network'", (ROOT / 'network_proof.py').read_text())

    def test_fixture_preparation_uses_the_public_packer_without_a_runtime_or_source_patch(self):
        source = (ROOT.parents[1] / 'smolbox-engine/examples/prepare_network_fixture.rs').read_text()
        for required in ['Packer::new', 'collector.collect_libraries', 'collector.collect_agent_rootfs',
                         'collector.add_layer_from_file', 'verify_sidecar_checksum_file']:
            self.assertIn(required, source)
        for forbidden in ['Engine::', 'AgentManager::', 'Command::', 'set_var(', 'remove_var(']:
            self.assertNotIn(forbidden, source)


if __name__ == '__main__':
    unittest.main()
