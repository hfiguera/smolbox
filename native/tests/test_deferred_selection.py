"""Guard ordinary Elixir selection without starting any fixture owner or VM."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DeferredSelectionTests(unittest.TestCase):
    def test_native_forced_loss_and_persistence_boundaries_have_an_independent_tag(self):
        campaign = re.compile(
            r'Process\.exit\([^)]*,\s*:kill\)|'
            r'Package\.command\([^)]*,\s*"crash"\)|'
            r'assert_receive\s+\{:boundary', re.S)
        checked = 0
        for name in ('embedded_backend', 'embedded_execution', 'embedded_port', 'native_recovery'):
            source = (ROOT / 'test/unit' / f'{name}_test.exs').read_text()
            tests = list(re.finditer(r'(?m)^\s{2,4}test "', source))
            for index, test in enumerate(tests):
                end = tests[index + 1].start() if index + 1 < len(tests) else len(source)
                if campaign.search(source[test.start():end]):
                    prefix = source[:test.start()].rstrip().splitlines()[-1].strip()
                    self.assertEqual(prefix, '@tag :deferred_crash',
                                     f'{name}: forced loss/interruption lacks deferred selection')
                    checked += 1
        # The owner/helper macro generates two cases from one tagged declaration.
        self.assertEqual(checked, 12)

    def test_native_check_uses_only_reviewed_exact_ordinary_fixtures(self):
        source = (ROOT / 'native/check.sh').read_text()
        declaration = re.search(r'native_ordinary_fixtures=\((.*?)\)', source, re.S)
        self.assertIsNotNone(declaration)
        actual = re.findall(r'"([a-zA-Z0-9_:]+)"', declaration.group(1))
        expected = {
            'transfer_supervisor::tests::ordinary_worker_process_connects_without_initializing_runtime_ownership',
            'transfer_supervisor::tests::ordinary_worker_binary_transfers_use_public_agent_api',
            'terminal_supervisor::tests::ordinary_terminal_supervisor_holds_leases_until_exact_normal_collection',
            'terminal_supervisor::tests::ordinary_terminal_natural_exit_preserves_final_output_and_collected_exit',
            'terminal_supervisor::tests::ordinary_terminal_eof_and_ambiguous_exit_do_not_confirm_completion',
            'checkpoint_source::tests::ordinary_worker_checkpoint_installation_commits_only_fresh_owned_material',
            'checkpoint_source::tests::ordinary_worker_checkpoint_materializes_sdk_files_and_collects_without_vm_dispatch',
            'transfer_supervisor::tests::ordinary_conversion_worker_collects_and_rehashes_both_spools_with_original_leases',
            'transfer_supervisor::tests::ordinary_imported_conversion_worker_preserves_source_gate_and_spools',
            'transfer_supervisor::tests::ordinary_growth_worker_collects_raw_and_qcow_sdk_geometry_with_owned_leases',
            'transfer_supervisor::tests::ordinary_branch_worker_rejects_unentered_fixture_and_collects_original_leases',
            'epoch::tests::ordinary_boot_guard_enrolls_before_sdk_and_collects_normal_exit',
        }
        self.assertEqual(len(actual), len(expected))
        self.assertEqual(set(actual), expected)
        self.assertIn('--lib "$native_ordinary_fixture" --locked -- --exact --ignored', source)
        ignored = [line for line in source.splitlines() if '--ignored' in line]
        self.assertEqual(len(ignored), 1)
        self.assertIn('--exact --ignored', ignored[0])
        self.assertIn('--workspace --lib --bins --test contract --locked', source)
        self.assertIn('--test child_reaping --locked', source)
        self.assertNotIn('cargo run', source)
        self.assertNotIn('run-registry', source)
        self.assertNotIn('registry_fixture.py', source)
        commands = {line.strip() for line in source.splitlines() if line.strip().startswith('cargo test ')}
        self.assertEqual(commands, {
            'cargo test --manifest-path "$native_manifest" --workspace --lib --bins --test contract --locked',
            'cargo test --manifest-path "$native_manifest" -p smolbox-engine --example volume-guest-proof --locked',
            'cargo test --manifest-path "$native_manifest" -p smolbox-engine --example oci-guest-proof --locked',
            'cargo test --manifest-path "$native_manifest" -p smolbox-engine --example branch-guest-proof --locked',
            'cargo test --manifest-path "$native_manifest" -p smolbox-engine --test child_reaping --locked',
            'cargo test --manifest-path "$native_manifest" -p smolbox-engine --lib "$native_ordinary_fixture" --locked -- --exact --ignored',
            'cargo test --manifest-path "$native_clean_fixture/Cargo.toml" --lib parity::tests --offline',
        })

    def test_runtime_selection_does_not_implicitly_include_deferred_native_campaigns(self):
        helper = (ROOT / 'test/test_helper.exs').read_text()
        self.assertRegex(helper, r'ExUnit\.start\(exclude: \[:runtime, :deferred_crash\]\)')


if __name__ == '__main__':
    unittest.main()
