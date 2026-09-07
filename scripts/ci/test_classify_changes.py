#!/usr/bin/env python3
"""Regression tests for CI selection, including rename and malformed-event cases."""

import contextlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

from classify_changes import changes, needs_runtime, revision
from check_required import LIVE, ORDINARY, SCOPE


class ClassificationTest(unittest.TestCase):
    def test_ordinary_runs_do_not_require_runtime_qualification(self):
        for event in ("push", "pull_request", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertFalse(needs_runtime(event, "false"))
        self.assertTrue(needs_runtime("workflow_dispatch", "true"))

    def test_invalid_runtime_selection_fails_closed(self):
        for event, requested in [
            ("push", "true"), ("pull_request", "true"), ("pull_request_target", "false"),
            ("workflow_dispatch", None), ("workflow_dispatch", ""),
            ("workflow_dispatch", True), ("workflow_dispatch", "TRUE"),
        ]:
            with self.subTest(event=event, requested=requested):
                with self.assertRaises(ValueError):
                    needs_runtime(event, requested)

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
                self.assertFalse(needs_runtime("pull_request", "false"))
                pathlib.Path(".tool-versions").write_text("fixture\n", encoding="utf-8")
                self.git("add", ".tool-versions")
                self.git("commit", "--quiet", "-m", "fixture root configuration")
                with contextlib.chdir("docs"):
                    _, initial = changes("push", {"before": "0" * 40})
                    self.assertCountEqual(initial, [".tool-versions", os.fspath(target)])
                    self.assertFalse(needs_runtime("push", "false"))
                _, manual = changes("workflow_dispatch", {})
                self.assertEqual(manual, [])
                self.assertTrue(needs_runtime("workflow_dispatch", "true"))
                with self.assertRaises(ValueError):
                    changes("pull_request_target", {})

    def test_selection_and_required_gate_commands(self):
        scripts = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix="smolbox-ci-selection-") as directory:
            with contextlib.chdir(directory):
                self.git("init", "--quiet")
                self.git("config", "user.name", "SmolBox CI fixture")
                self.git("config", "user.email", "fixture@example.invalid")
                pathlib.Path("mix.exs").write_text("fixture\n", encoding="utf-8")
                self.git("add", ".")
                self.git("commit", "--quiet", "-m", "fixture candidate")
                head = self.git("rev-parse", "HEAD").strip()
                for event, requested, expected_exit in [
                    ("push", "false", 0), ("pull_request", "false", 0),
                    ("workflow_dispatch", "false", 0), ("workflow_dispatch", "true", 1),
                ]:
                    with self.subTest(event=event, requested=requested):
                        payload = pathlib.Path("event.json")
                        payload.write_text(json.dumps({
                            "before": "0" * 40,
                            "pull_request": {"base": {"sha": head}},
                        }), encoding="utf-8")
                        output = pathlib.Path("github-output.txt")
                        output.write_text("", encoding="utf-8")
                        selected = subprocess.run([
                            sys.executable, os.fspath(scripts / "classify_changes.py"),
                            "--event", event, "--payload", os.fspath(payload),
                            "--qualify-runtime", requested,
                        ], env={**os.environ, "GITHUB_OUTPUT": os.fspath(output)},
                            text=True, capture_output=True, check=True, timeout=10)
                        report = json.loads(selected.stdout)
                        self.assertEqual(report["commit"], head)
                        self.assertEqual(report["runtime_required"], requested == "true")
                        if event == "push":
                            self.assertEqual(report["changed_path_count"], 1)
                        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                        results = {job: {"result": "success"} for job in ORDINARY | {SCOPE}}
                        results[SCOPE]["outputs"] = outputs
                        results.update({job: {"result": "skipped"} for job in LIVE})
                        gated = subprocess.run([
                            sys.executable, os.fspath(scripts / "check_required.py"),
                        ], env={**os.environ, "NEEDS_JSON": json.dumps(results)},
                            text=True, capture_output=True, timeout=10)
                        self.assertEqual(gated.returncode, expected_exit, gated.stdout + gated.stderr)
                        failed = json.loads(gated.stdout.splitlines()[0])["failed_dependencies"]
                        self.assertEqual(failed, {job: "skipped" for job in LIVE} if expected_exit else {})

    @staticmethod
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], text=True, stderr=subprocess.PIPE)


if __name__ == "__main__":
    unittest.main()
