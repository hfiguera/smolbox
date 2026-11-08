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

    def test_runtime_selection_does_not_implicitly_include_deferred_native_campaigns(self):
        helper = (ROOT / 'test/test_helper.exs').read_text()
        self.assertRegex(helper, r'ExUnit\.start\(exclude: \[:runtime, :deferred_crash\]\)')


if __name__ == '__main__':
    unittest.main()
