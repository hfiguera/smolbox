#!/usr/bin/env python3
import json
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock

from runtime_preflight import private_file, validate


class RuntimePreflightTest(unittest.TestCase):
    def manifest(self):
        return {
            "schema": 1, "platform": "linux", "ephemeral_runner": True,
            "expires_at_unix": int(time.time()) + 3600, "lifecycle_id": "fixture-worker-123",
            "worker_pid": os.getpid(), "worker_url": "http://127.0.0.1:19470",
            "python_sha256": "a" * 64, "javascript_sha256": "b" * 64,
            "python_artifact": "/private/python.smolmachine",
            "javascript_artifact": "/private/node.smolmachine",
            "database_socket_dir": "/private/socket", "database_port": 25432,
            "database_user": "smolbox", "database_name": "smolbox_contract",
        }

    def test_missing_lifecycle_cannot_qualify_ci_and_development_is_explicit(self):
        with mock.patch.dict(os.environ, {"DATABASE_URL": "", "GITHUB_ACTIONS": "false"}):
            manifest = self.manifest()
            self.assertEqual(validate(manifest, "linux", False).port, 19470)
            manifest["ephemeral_runner"] = False
            with self.assertRaises(ValueError):
                validate(manifest, "linux", False)
            self.assertEqual(validate(manifest, "linux", True).port, 19470)
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
                with self.assertRaises(ValueError):
                    validate(manifest, "linux", True)

    def test_bad_routes_expired_lifecycles_and_database_override_fail_closed(self):
        with mock.patch.dict(os.environ, {"DATABASE_URL": "", "GITHUB_ACTIONS": "false"}):
            for key, value in [
                ("worker_url", "http://example.invalid:19470"),
                ("worker_url", "http://127.0.0.1:19470/path"),
                ("worker_url", "http://127.0.0.1:\n19470"),
                ("worker_url", "http://user:password@127.0.0.1:19470"),
                ("python_artifact", "/private/file\nINJECTED=1"),
                ("expires_at_unix", int(time.time()) - 1),
                ("expires_at_unix", int(time.time()) + 100000),
                ("worker_pid", True), ("database_port", 0),
            ]:
                with self.subTest(field=key, value=value):
                    manifest = self.manifest()
                    manifest[key] = value
                    with self.assertRaises(ValueError):
                        validate(manifest, "linux", False)
            with mock.patch.dict(os.environ, {"DATABASE_URL": "ecto://unexpected.invalid/database"}):
                with self.assertRaises(ValueError):
                    validate(self.manifest(), "linux", False)

    def test_manifest_file_must_be_private_regular_and_bounded(self):
        with tempfile.TemporaryDirectory(prefix="smolbox-preflight-") as directory:
            path = pathlib.Path(directory, "manifest.json")
            manifest = self.manifest()
            path.write_text(json.dumps(manifest), encoding="utf-8")
            path.chmod(0o600)
            self.assertEqual(json.loads(private_file(path, 16384)), manifest)
            with self.assertRaises(ValueError):
                private_file(path, 1)
            link = pathlib.Path(directory, "link.json")
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                private_file(link, 16384)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                private_file(path, 16384)


if __name__ == "__main__":
    unittest.main()
