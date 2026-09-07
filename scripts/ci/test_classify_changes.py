#!/usr/bin/env python3
"""Regression tests for CI selection, including rename and malformed-event cases."""

import contextlib
import os
import pathlib
import subprocess
import tempfile
import unittest

from classify_changes import changes, needs_runtime, revision


class ClassificationTest(unittest.TestCase):
    def test_documentation_skip_is_narrow(self):
        paths = ["README.md", "CHANGELOG.md", "docs/telemetry.md"]
        self.assertFalse(needs_runtime(paths, "pull_request"))
        self.assertFalse(needs_runtime(paths, "push"))
        for path in [
            "lib/smolbox.ex", "test/fixtures/notes.md",
            "docs/evidence/candidate.json", "mix.exs",
            "external-references/smolvm/README.md",
            ".github/workflows/smolbox-ci.yml", "AGENTS.md", ".tool-versions",
            "unknown", "docs/../lib/unsafe.md", "/docs/unsafe.md",
            "ideas/001-initial-idea.txt", "packages/smolbox/docs/client.md",
        ]:
            with self.subTest(path=path):
                self.assertTrue(needs_runtime(paths + [path], "pull_request"))

    def test_dispatch_and_empty_diff_require_live_evidence(self):
        self.assertTrue(needs_runtime(["docs/client.md"], "workflow_dispatch"))
        self.assertTrue(needs_runtime([], "push"))

    def test_invalid_revisions_are_never_git_arguments(self):
        for value in [None, "HEAD", "--help", "a" * 39, "a" * 41, "a" * 40 + "\n"]:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    revision(value)

    def test_actual_git_diff_includes_both_sides_of_a_rename(self):
        with tempfile.TemporaryDirectory(prefix="smolbox-ci-scope-") as directory:
            with contextlib.chdir(directory):
                self.git("init", "--quiet")
                self.git("config", "user.name", "SmolBox CI fixture")
                self.git("config", "user.email", "fixture@example.invalid")
                source = pathlib.Path("lib/example.ex")
                source.parent.mkdir(parents=True)
                source.write_text("fixture\n", encoding="utf-8")
                self.git("add", ".")
                self.git("commit", "--quiet", "-m", "fixture base")
                base = self.git("rev-parse", "HEAD").strip()
                target = pathlib.Path("docs/example.md")
                target.parent.mkdir(parents=True)
                self.git("mv", os.fspath(source), os.fspath(target))
                self.git("commit", "--quiet", "-m", "fixture rename")
                head, paths = changes("pull_request", {"pull_request": {"base": {"sha": base}}})
                self.assertEqual(head, self.git("rev-parse", "HEAD").strip())
                self.assertCountEqual(paths, [os.fspath(source), os.fspath(target)])
                self.assertTrue(needs_runtime(paths, "pull_request"))
                pathlib.Path(".tool-versions").write_text("fixture\n", encoding="utf-8")
                self.git("add", ".tool-versions")
                self.git("commit", "--quiet", "-m", "fixture root configuration")
                with contextlib.chdir("docs"):
                    _, initial = changes("push", {"before": "0" * 40})
                    self.assertCountEqual(initial, [".tool-versions", os.fspath(target)])
                    self.assertTrue(needs_runtime(initial, "push"))
                _, manual = changes("workflow_dispatch", {})
                self.assertTrue(needs_runtime(manual, "workflow_dispatch"))
                with self.assertRaises(ValueError):
                    changes("pull_request_target", {})

    @staticmethod
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], text=True, stderr=subprocess.PIPE)


if __name__ == "__main__":
    unittest.main()
