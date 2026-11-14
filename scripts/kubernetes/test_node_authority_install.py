"""Manual offline installer tests; node observations and root metadata are fixtures."""

from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "priv/kubernetes/node_authority/v1"
sys.path.insert(0, str(BUNDLE))
import authority_assets as assets
import authority_contract as contract
import authority_history as history
from authority_config import Configuration


def module(name, filename):
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "scripts/kubernetes/node-authority" / filename
    )
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


installer = module("authority_installer", "install.py")
builder = module("authority_bundle", "bundle.py")


class BundleTest(unittest.TestCase):
    def test_bundle_is_deterministic_complete_and_has_no_links_or_checkout_dependency(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            first, second = (
                Path(temporary) / "first.tar.gz",
                Path(temporary) / "second.tar.gz",
            )
            approval = builder.build(first)
            self.assertEqual(builder.build(second), approval)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first) as archive:
                records = archive.getmembers()
                self.assertTrue(
                    all(
                        item.isfile() and item.uid == item.gid == item.mtime == 0
                        for item in records
                    )
                )
                values = {
                    item.name.removeprefix(builder.PREFIX + "/"): archive.extractfile(
                        item
                    ).read()
                    for item in records
                }
            self.assertEqual(
                set(values),
                {"programs/" + name for name in (*assets.PROGRAMS, "manifest.json")}
                | {
                    "install.py",
                    "access-policy.txt",
                    "observer-rbac.yaml",
                    "README.md",
                    "configuration.schema.json",
                    "protocol.schema.json",
                    "package-manifest.json",
                },
            )
            manifest = contract.decode(values["programs/manifest.json"])
            self.assertEqual(
                contract.sha256(manifest), approval["verifier_manifest_sha256"]
            )
            for name, expected in manifest["files"].items():
                self.assertEqual(
                    hashlib.sha256(values["programs/" + name]).hexdigest(), expected
                )
            package = contract.decode(values["package-manifest.json"])
            for name, expected in package["files"].items():
                self.assertEqual(hashlib.sha256(values[name]).hexdigest(), expected)
            with self.assertRaises(FileExistsError):
                builder.build(first)


class InstallationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.programs = self.root / "installed/programs"
        self.configuration = self.root / "etc/enrollment.json"
        self.entries = {
            self.root / "libexec/authority": "entrypoint.sh",
            self.root / "libexec/ssh": "ssh-command.sh",
        }
        for name, value in (
            ("PROGRAM_DIRECTORY", self.programs),
            ("CONFIGURATION", self.configuration),
            ("ENTRYPOINTS", self.entries),
            ("INSTALL_LOCK", self.root / "install.lock"),
        ):
            self.stack.enter_context(patch.object(installer, name, value))
        source = self.root / "source"
        source.mkdir()
        hashes = {}
        for name in assets.PROGRAMS:
            shutil.copyfile(BUNDLE / name, source / name)
            hashes[name] = hashlib.sha256((source / name).read_bytes()).hexdigest()
        (source / "manifest.json").write_bytes(
            contract.canonical({"version": 1, "files": hashes})
        )
        data = json.loads(
            (
                ROOT / "test/fixtures/kubernetes/node-authority-v1/vectors.json"
            ).read_text()
        )["configuration"]
        data["paths"]["state_directory"] = str(self.root / "state")
        data["paths"]["database"] = str(self.root / "runtime.db")
        data["binding"]["runtime_identity"]["archive_sha256"] = installer.ARCHIVE_SHA256
        self.installation = installer.Installation(
            source, Configuration.from_dict(data)
        )
        self.engine = self.installation.engine
        # Positive custody is simulated here; the core suite separately tests
        # ownership/mode/symlink rejection. Real root/SSH verification is Phase 5.
        self.installation.owned_path = lambda path, *args, **kwargs: path
        self.installation.verify_filesystem = lambda *args, **kwargs: None
        self.identity = {
            key: data["binding"][key]
            for key in (
                "cluster_anchor_uid",
                "namespace_uid",
                "node_uid",
                "node_boot_id",
            )
        }
        self.stack.enter_context(
            patch.object(self.engine, "identity", return_value=self.identity)
        )
        self.stack.enter_context(patch.object(self.engine, "baseline"))
        self.stack.enter_context(patch.object(self.installation, "check_empty_guard"))
        self.stack.enter_context(
            patch.object(self.installation, "check_observer_permissions")
        )
        self.stack.enter_context(patch.object(self.engine, "check_runtime"))

        def kube(*args):
            if args[1] == "node":
                return {
                    "status": {
                        "nodeInfo": {
                            "kubeletVersion": contract.RUNTIME_VERSIONS["k3s_version"],
                            "containerRuntimeVersion": "containerd://"
                            + contract.RUNTIME_VERSIONS["containerd_version"],
                            "architecture": "amd64",
                            "operatingSystem": "linux",
                        }
                    }
                }
            return {
                "metadata": {"uid": data["binding"]["runtime_class_uid"]},
                "handler": "smolvm",
                "overhead": {"podFixed": {"cpu": "250m", "memory": "512Mi"}},
            }

        self.stack.enter_context(patch.object(self.engine, "kube", side_effect=kube))
        sha = self.engine.sha
        self.stack.enter_context(
            patch.object(
                self.engine,
                "sha",
                side_effect=lambda path: (
                    installer.K3S_SHA256
                    if path == self.installation.config.paths["k3s_executable"]
                    else sha(path)
                ),
            )
        )
        self.stack.enter_context(
            patch.object(
                self.engine.lifecycle,
                "current",
                return_value={"mount": {"id": 33}, "daemons": []},
            )
        )
        self.stack.enter_context(
            patch.object(
                assets,
                "runtime_identity",
                return_value={
                    "template_sizes": {
                        "storage-template.ext4": 21474836480,
                        "overlay-template.ext4": 10737418240,
                    },
                    "sha256": {},
                    "agent_rootfs": {},
                },
            )
        )
        self.write(
            "CREATE TABLE vms(name TEXT PRIMARY KEY NOT NULL,data BLOB NOT NULL)"
        )
        self.write(
            "CREATE TABLE vm_create_reservations(name TEXT PRIMARY KEY NOT NULL)"
        )

    def write(self, sql, arguments=()):
        connection = sqlite3.connect(self.engine.DATABASE)
        try:
            with connection:
                connection.execute(sql, arguments)
        finally:
            connection.close()

    def files(self):
        return {
            str(path.relative_to(self.root)): (
                path.lstat().st_mode,
                path.lstat().st_mtime_ns,
                os.readlink(path) if path.is_symlink() else path.read_bytes(),
            )
            for path in self.root.rglob("*")
            if path.is_file() or path.is_symlink()
        }

    def test_empty_enrollment_publishes_active_last_and_identical_repeat_is_read_only(
        self,
    ):
        result = self.installation.install()
        self.assertEqual(result, self.engine.read_state(self.installation.approval))
        enrollment = self.engine.read_state(self.engine.ENROLLMENT)
        self.assertNotEqual(enrollment["epoch"], result["authority_generation"])
        self.assertEqual(
            self.engine.verify_enrollment(enrollment), result["authority_generation"]
        )
        self.assertFalse(self.installation.marker.exists())
        self.assertEqual(self.engine.read_state(self.engine.LEDGER)["watermark"], 0)
        for path, name in self.entries.items():
            self.assertTrue(path.is_symlink())
            self.assertEqual(path.resolve(), self.programs / name)
            self.assertEqual((self.programs / name).stat().st_mode & 0o777, 0o755)
        prior = self.files()
        self.assertEqual(self.installation.install(), result)
        self.assertEqual(self.installation.verify(), result)
        self.assertEqual(self.files(), prior)
        # The original audit epoch/trigger set is not recreated on repeat.
        with history.connect(self.engine.DATABASE) as connection:
            self.assertEqual(
                connection.execute(f"SELECT value FROM {history.EPOCH}").fetchall(),
                [(enrollment["epoch"],)],
            )

    def test_explicit_candidate_pin_must_match_binding_and_is_preserved(self):
        candidate = "a" * 64
        self.installation.runtime_archive_sha256 = candidate
        prior = self.files()
        with self.assertRaisesRegex(RuntimeError, "unqualified runtime archive"):
            self.installation.install()
        self.assertEqual(
            {
                key: value
                for key, value in self.files().items()
                if key != "install.lock"
            },
            prior,
        )
        self.assertFalse(self.engine.STATE.exists())
        data = self.installation.config.as_dict()
        data["binding"]["runtime_identity"]["archive_sha256"] = candidate
        self.installation.config = Configuration.from_dict(data)
        self.engine.config = self.installation.config
        self.engine.binding = self.installation.config.binding
        approval = self.installation.install()
        self.assertEqual(
            self.engine.read_state(self.engine.ENROLLMENT)["archive_sha256"], candidate
        )
        self.assertEqual(assets.runtime_identity.call_args.args[2], candidate)
        prior = self.files()
        self.assertEqual(self.installation.verify(), approval)
        self.assertEqual(self.files(), prior)
        self.installation.runtime_archive_sha256 = installer.ARCHIVE_SHA256
        with self.assertRaisesRegex(RuntimeError, "unqualified runtime archive"):
            self.installation.verify()
        self.assertEqual(self.files(), prior)

    def test_invalid_explicit_archive_approval_is_rejected(self):
        for value in (None, "", "A" * 64, "a" * 63, "a" * 65, "a" * 64 + "\n"):
            with self.subTest(value=value), self.assertRaisesRegex(
                RuntimeError, "digest required"
            ):
                installer.Installation(
                    self.installation.source,
                    self.installation.config,
                    runtime_archive_sha256=value,
                )

    def test_preexisting_history_rows_or_creation_reservations_never_get_reenrolled(
        self,
    ):
        history.enroll(self.engine.DATABASE, self.identity, lambda: None)
        prior = self.engine.DATABASE.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "history already enrolled"):
            self.installation.install()
        self.assertEqual(self.engine.DATABASE.read_bytes(), prior)
        self.assertFalse(self.engine.STATE.exists())

    def test_nonempty_runtime_is_rejected_before_installation_state_is_created(self):
        self.write("INSERT INTO vm_create_reservations VALUES(?)", ("a" * 64,))
        with self.assertRaisesRegex(RuntimeError, "runtime is not empty"):
            self.installation.install()
        self.assertFalse(self.programs.exists())
        self.assertFalse(self.engine.STATE.exists())

    def test_verification_of_missing_installation_does_not_create_lock_or_state(self):
        with self.assertRaises(FileNotFoundError):
            self.installation.verify()
        self.assertFalse(installer.INSTALL_LOCK.exists())
        self.assertFalse(self.engine.STATE.exists())
        self.assertFalse(self.programs.exists())

    def test_unknown_controller_state_and_partial_files_are_preserved(self):
        self.engine.STATE.mkdir(mode=0o700)
        controller = self.engine.STATE / "old-controller.json"
        controller.write_bytes(b"unresolved authority")
        with self.assertRaisesRegex(RuntimeError, "preexisting authority state"):
            self.installation.install()
        self.assertEqual(controller.read_bytes(), b"unresolved authority")
        self.assertFalse(self.configuration.exists())
        self.assertFalse(self.programs.exists())

    def test_unavailable_api_cri_or_guard_cannot_publish_active_authority(self):
        self.engine.baseline.side_effect = RuntimeError("API/CRI unavailable")
        with self.assertRaisesRegex(RuntimeError, "API/CRI unavailable"):
            self.installation.install()
        self.assertFalse(self.engine.STATE.exists())
        self.engine.baseline.side_effect = None
        self.installation.check_empty_guard.side_effect = RuntimeError(
            "guard unavailable"
        )
        with self.assertRaisesRegex(RuntimeError, "guard unavailable"):
            self.installation.install()
        self.assertFalse(self.engine.STATE.exists())

    def test_nonempty_rows_cannot_be_accepted_even_with_empty_physical_fixture(self):
        self.write("INSERT INTO vms VALUES(?,?)", ("a" * 64, b"unexplained row"))
        with self.assertRaisesRegex(RuntimeError, "runtime is not empty"):
            self.installation.install()
        self.assertFalse(self.engine.ENROLLMENT.exists())

    def test_observer_permissions_require_reads_and_explicit_mutation_secret_denials(
        self,
    ):
        from unittest.mock import Mock

        runner = Mock()
        runner.remaining.return_value = 10

        def answer(argv, **kwargs):
            self.assertEqual(kwargs, {"allowed_exit_codes": (0, 1)})
            index = argv.index("can-i")
            verb, resource = argv[index + 1 : index + 3]
            forbidden = (
                verb in {"create", "delete", "patch"}
                or resource == "secrets"
                or (verb == "list" and resource in {"namespaces", "nodes"})
            )
            return b"no\n" if forbidden else b"yes\n"

        runner.side_effect = answer
        self.installation.runner = runner
        installer.Installation.check_observer_permissions(self.installation)
        self.assertEqual(runner.call_count, 15)
        for result in (b"yes\n", b"no\n", b"", b"private diagnostic"):
            runner.side_effect = None
            runner.return_value = result
            with self.assertRaisesRegex(
                RuntimeError, "observer credential permissions"
            ):
                installer.Installation.check_observer_permissions(self.installation)

    def test_partial_installation_and_changed_files_cannot_grant_another_epoch(self):
        self.installation.install()
        before = self.engine.ENROLLMENT.read_bytes()
        (self.programs / "authority_contract.py").write_bytes(b"changed code")
        with self.assertRaisesRegex(RuntimeError, "manifest changed"):
            self.installation.install()
        self.assertEqual(self.engine.ENROLLMENT.read_bytes(), before)

    def test_missing_ledger_or_changed_configuration_refuses_identical_repeat(self):
        self.installation.install()
        self.engine.LEDGER.unlink()
        before = self.files()
        with self.assertRaises(FileNotFoundError):
            self.installation.install()
        self.assertEqual(self.files(), before)
        self.configuration.write_bytes(b"{}")
        with self.assertRaisesRegex(RuntimeError, "configuration differs"):
            self.installation.install()

    def test_interrupted_enrollment_preserves_history_and_refuses_automatic_repair(
        self,
    ):
        atomic = history.atomic_json

        def interrupt(path, *args):
            if path == self.engine.LEDGER:
                raise RuntimeError("interrupted enrollment")
            atomic(path, *args)

        with patch.object(history, "atomic_json", side_effect=interrupt):
            with self.assertRaisesRegex(RuntimeError, "interrupted enrollment"):
                self.installation.install()
        self.assertTrue(self.installation.marker.exists())
        self.assertFalse(self.engine.ENROLLMENT.exists())
        with history.connect(self.engine.DATABASE) as connection:
            original = connection.execute(
                f"SELECT value FROM {history.EPOCH}"
            ).fetchall()
        with self.assertRaisesRegex(RuntimeError, "partial/different installation"):
            self.installation.install()
        with history.connect(self.engine.DATABASE) as connection:
            self.assertEqual(
                connection.execute(f"SELECT value FROM {history.EPOCH}").fetchall(),
                original,
            )

    def test_concurrent_installation_creates_exactly_one_generation(self):
        results, errors = [], []

        def install():
            try:
                results.append(self.installation.install())
            except Exception as error:
                errors.append(error)

        threads = [threading.Thread(target=install) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])


if __name__ == "__main__":
    unittest.main()
