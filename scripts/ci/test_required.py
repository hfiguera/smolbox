#!/usr/bin/env python3
import unittest

from check_required import LIVE, ORDINARY, SCOPE, failures


class RequiredStatusTest(unittest.TestCase):
    def baseline(self, runtime="true"):
        results = {job: {"result": "success"} for job in ORDINARY | LIVE | {SCOPE}}
        results[SCOPE]["outputs"] = {"runtime_required": runtime}
        return results

    def test_complete_live_matrix_passes(self):
        self.assertEqual(failures(self.baseline()), {})

    def test_runtime_changes_cannot_pass_with_skipped_live_jobs(self):
        for job in LIVE:
            results = self.baseline()
            results[job]["result"] = "skipped"
            self.assertEqual(failures(results), {job: "skipped"})

    def test_only_explicit_documentation_policy_permits_live_skips(self):
        results = self.baseline("false")
        for job in LIVE:
            results[job]["result"] = "skipped"
        self.assertEqual(failures(results), {})
        results["smolbox-tests"]["result"] = "skipped"
        self.assertEqual(failures(results), {"smolbox-tests": "skipped"})

    def test_missing_failed_cancelled_or_invalid_scope_never_passes(self):
        for job in ORDINARY | LIVE | {SCOPE}:
            for status in [None, "failure", "cancelled"]:
                with self.subTest(job=job, status=status):
                    results = self.baseline()
                    results[job]["result"] = status
                    self.assertTrue(failures(results))
            results = self.baseline()
            del results[job]
            self.assertTrue(failures(results))
        for invalid in [None, "", True, "FALSE"]:
            self.assertTrue(failures(self.baseline(invalid)))
        self.assertTrue(failures({}))


if __name__ == "__main__":
    unittest.main()
