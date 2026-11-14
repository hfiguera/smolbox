"""Manual extraction checks. Every filesystem/process/API view is a fixture."""

import ast
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "priv/kubernetes/node_authority/v1"
sys.path.insert(0, str(BUNDLE))
import authority_assets as assets
import authority_contract as contract
import authority_history as history
from authority_config import Configuration, owned_path, verify_filesystem
from authority_guard import Guard
from authority_lifecycle import Lifecycle
from authority_runner import Runner
from authority_verifier import Verifier

VECTORS = ROOT / "test/fixtures/kubernetes/node-authority-v1/vectors.json"


def config():
    return Configuration.from_dict(json.loads(VECTORS.read_text())["configuration"])


def write_manifest(directory):
    values = {
        name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
        for name in assets.PROGRAMS
    }
    (directory / "manifest.json").write_bytes(
        contract.canonical({"version": 1, "files": values})
    )


class ConfigurationTest(unittest.TestCase):
    def test_configuration_is_exact_canonical_immutable_and_has_no_input_alias(self):
        value = json.loads(VECTORS.read_text())["configuration"]
        approved = Configuration.from_dict(value)
        self.assertEqual(
            approved.sha256,
            json.loads(VECTORS.read_text())["identity_fields"]["configuration_sha256"],
        )
        value["paths"]["database"] = "/changed"
        obtained = approved.as_dict()
        obtained["binding"]["node_name"] = "changed"
        self.assertNotEqual(approved.paths["database"], Path("/changed"))
        self.assertEqual(approved.binding["node_name"], "smolbox-k3s")
        with self.assertRaises(AttributeError):
            approved.encoded = b"{}"

    def test_configuration_rejects_unsafe_paths_aliases_unknowns_and_versions(self):
        for path in (
            "relative",
            "/",
            "/tmp/../secret",
            "/tmp/./secret",
            "/tmp//secret",
            "/tmp/secret/",
            "/tmp/\nsecret",
        ):
            value = config().as_dict()
            value["paths"]["database"] = path
            with self.assertRaises(ValueError):
                Configuration.from_dict(value)
        for mutate in (
            lambda v: v.update(extra=True),
            lambda v: v.update(version=True),
            lambda v: v["binding"]["runtime_identity"].update(smolvm_version="unknown"),
            lambda v: v["paths"].update(share_root=v["paths"]["vm_root"]),
            lambda v: v["guard"].update(bridge="../../bridge"),
        ):
            value = config().as_dict()
            mutate(value)
            with self.assertRaises(ValueError):
                Configuration.from_dict(value)

    def test_privileged_paths_reject_symlinks_and_writable_ancestors(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / "secret"
            path.write_bytes(b"private")
            path.chmod(0o600)
            # Test without requiring the unit-test runner to be root.
            with patch("authority_config.Path.lstat", autospec=True) as view:
                original_lstat = os.lstat

                def metadata(item):
                    info = original_lstat(item)
                    values = list(info)
                    values[4] = 0
                    # The temporary fixture's /tmp ancestor is normally writable;
                    # present a root-controlled tree, then inject each fault.
                    values[0] &= ~0o022
                    return os.stat_result(values)

                view.side_effect = metadata
                self.assertEqual(owned_path(path, "file", private=True), path)

                def writable(item):
                    info = metadata(item)
                    values = list(info)
                    if item == path.parent:
                        values[0] |= 0o020
                    return os.stat_result(values)

                view.side_effect = writable
                with self.assertRaisesRegex(ValueError, "writable"):
                    owned_path(path, "file")
                link = path.with_name("link")
                link.symlink_to(path)
                view.side_effect = metadata
                with self.assertRaisesRegex(ValueError, "symlinked"):
                    owned_path(link, "file")

                # Installation links are allowed only with custody over each
                # original and redirected ancestor, not just the final binary.
                self.assertEqual(
                    owned_path(link, "file", installation_symlinks=True), path
                )
                view.side_effect = writable
                with self.assertRaisesRegex(ValueError, "writable"):
                    owned_path(link, "file", installation_symlinks=True)

    def test_missing_optional_health_assets_do_not_prevent_cleanup_observation(self):
        with patch("authority_config.owned_path") as verify:
            verify_filesystem(config(), "cleanup")
            calls = {call.args[0]: call.kwargs for call in verify.call_args_list}
            for key in (
                "runtime_root",
                "runtime_archive",
                "guard_program",
                "guard_state",
                "vm_root",
                "share_root",
            ):
                self.assertTrue(calls[config().paths[key]]["allow_missing"])
            for key in (
                "state_directory",
                "database",
                "kubeconfig",
                "cri_socket",
                "daemon_executable",
            ):
                self.assertFalse(calls[config().paths[key]]["allow_missing"])
            verify.reset_mock()
            verify_filesystem(config(), "capture")
            calls = {call.args[0]: call.kwargs for call in verify.call_args_list}
            self.assertFalse(calls[config().paths["runtime_root"]]["allow_missing"])
            self.assertFalse(calls[config().paths["guard_state"]]["allow_missing"])


class RunnerTest(unittest.TestCase):
    def test_lock_wait_keeps_deadline_and_owner_loss_is_observed(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock"
            first, second = Runner(), Runner(timeout_ms=30)
            with first.locked(path):
                with self.assertRaisesRegex(ValueError, "deadline"):
                    with second.locked(path):
                        self.fail("unexpected second owner")
            read, write = os.pipe()
            try:
                os.close(write)
                with self.assertRaisesRegex(ValueError, "owner/input lost"):
                    Runner(input_fd=read).tick()
            finally:
                os.close(read)

    def test_observation_child_dies_on_owner_loss_including_closed_output(self):
        for program in (
            "import time; time.sleep(30)",
            "import os,time; os.close(1); os.close(2); time.sleep(30)",
        ):
            read, write = os.pipe()
            runner = Runner(timeout_ms=3000, input_fd=read)
            timer = threading.Timer(0.05, lambda: os.close(write))
            timer.start()
            started = time.monotonic()
            try:
                with self.assertRaisesRegex(ValueError, "owner/input lost"):
                    runner([sys.executable, "-c", program])
                self.assertLess(time.monotonic() - started, 1)
            finally:
                timer.join()
                os.close(read)

    def test_child_bytes_deadline_and_environment_are_bounded(self):
        runner = Runner(timeout_ms=3000)
        with self.assertRaisesRegex(ValueError, "byte bound"):
            runner([sys.executable, "-c", "import os; os.write(1,b'x'*2097153)"])
        with self.assertRaisesRegex(ValueError, "deadline"):
            Runner(timeout_ms=30)([sys.executable, "-c", "import time; time.sleep(30)"])
        with patch.dict(
            os.environ,
            {
                "KUBECONFIG": "/private",
                "SSH_AUTH_SOCK": "/private-agent",
                "PYTHONPATH": "/private",
            },
        ):
            result = Runner()(
                [
                    sys.executable,
                    "-c",
                    "import os,json; print(json.dumps(dict(os.environ)))",
                ]
            )
        actual = json.loads(result)
        self.assertNotIn("KUBECONFIG", actual)
        self.assertNotIn("SSH_AUTH_SOCK", actual)
        self.assertNotIn("PYTHONPATH", actual)
        with self.assertRaisesRegex(ValueError, "argument vector"):
            Runner()(["relative", "command"])
        with self.assertRaisesRegex(ValueError, "command unavailable"):
            Runner()([sys.executable, "-c", "print('no');raise SystemExit(1)"])
        self.assertEqual(
            Runner()(
                [sys.executable, "-c", "print('no');raise SystemExit(1)"],
                allowed_exit_codes=(0, 1),
            ),
            b"no\n",
        )


class EngineTest(unittest.TestCase):
    def setUp(self):
        self.engine = Verifier(config())
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_target_and_action_cannot_override_root_configuration(self):
        for request in (
            {"version": 1, "action": "install", "binding": self.engine.binding},
            {"version": 1, "action": "check", "binding": {}},
            {"version": True, "action": "check", "binding": self.engine.binding},
        ):
            with patch.object(self.engine, "read_state") as read:
                with self.assertRaises((ValueError, RuntimeError)):
                    self.engine.inspect(request)
                read.assert_not_called()

    def test_explicit_read_only_commands_use_configured_paths_and_endpoint(self):
        with patch.object(self.engine, "runner") as runner:
            runner.return_value = b'{"items":[]}'
            self.assertEqual(self.engine.cri(), [])
            argv = runner.call_args.args[0]
            self.assertEqual(
                argv,
                [
                    str(self.engine.paths["k3s_executable"]),
                    "crictl",
                    "--runtime-endpoint=unix://" + str(self.engine.paths["cri_socket"]),
                    "pods",
                    "-o",
                    "json",
                ],
            )
        with patch.object(
            self.engine, "kube", return_value={"items": []}
        ), patch.object(self.engine, "physical", return_value=[]), patch.object(
            self.engine, "entries", return_value=[]
        ), patch.object(
            self.engine,
            "cri",
            return_value=[
                {"metadata": {"namespace": self.engine.binding["namespace"]}}
            ],
        ):
            with self.assertRaisesRegex(RuntimeError, "CRI is not empty"):
                self.engine.baseline()

    def test_state_reads_reject_symlinks_oversize_and_nonprivate_modes(self):
        path = self.root / "state"
        path.write_bytes(b"{}")
        path.chmod(0o600)
        self.assertEqual(self.engine.read_state(path), {})
        path.chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, "ownership/size"):
            self.engine.read_state(path)
        path.chmod(0o600)
        path.write_bytes(b"x" * (history.MAX_RECORD + 1))
        with self.assertRaisesRegex(RuntimeError, "ownership/size"):
            self.engine.read_state(path)
        link = path.with_name("link")
        link.symlink_to(path)
        with self.assertRaises(OSError):
            self.engine.read_state(link)

    def test_program_inventory_includes_source_basis_and_rejects_unapproved_files(self):
        for name in assets.PROGRAMS:
            (self.root / name).write_bytes((BUNDLE / name).read_bytes())
        write_manifest(self.root)
        values = assets.programs(self.root, lambda: None)
        manifest = contract.sha256({"version": 1, "files": values})
        enrollment = {
            "active": True,
            "configuration_sha256": self.engine.config.sha256,
            "programs": values,
            "verifier_manifest_sha256": manifest,
            "epoch": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "enrollment_nonce": "1" * 64,
        }
        fields = {
            "version": 1,
            "binding_generation": self.engine.binding["generation"],
            "history_epoch": enrollment["epoch"],
            "enrollment_nonce": enrollment["enrollment_nonce"],
            "verifier_manifest_sha256": manifest,
            "configuration_sha256": self.engine.config.sha256,
        }
        enrollment["authority_generation"] = contract.generation(fields)
        self.engine.bundle = self.root
        self.assertEqual(
            self.engine.verify_enrollment(enrollment),
            enrollment["authority_generation"],
        )
        for field in (
            "configuration_sha256",
            "authority_generation",
            "epoch",
            "verifier_manifest_sha256",
        ):
            changed = copy.deepcopy(enrollment)
            changed[field] = "f" * 64
            with self.assertRaises((ValueError, RuntimeError)):
                self.engine.verify_enrollment(changed)
        (self.root / "unapproved.so").write_bytes(b"extra")
        with self.assertRaisesRegex(RuntimeError, "unexpected verifier"):
            self.engine.verify_enrollment(enrollment)

    def test_configured_guard_rules_match_lab_without_importing_mutation(self):
        import offline_guard

        self.assertEqual(self.engine.guard.TEMPLATE, offline_guard.TEMPLATE)
        for name in ("install_table", "reconcile", "main"):
            self.assertFalse(hasattr(self.engine.guard, name))
        self.assertFalse(hasattr(self.engine, "install"))
        # All production imports stay inside the private bundle or stdlib.
        for path in BUNDLE.glob("*.py"):
            tree = ast.parse(path.read_text())
            for node in ast.walk(tree):
                if isinstance(node, ast.ImportFrom):
                    self.assertNotIn(
                        node.module,
                        (
                            "smoke",
                            "qualify",
                            "offline_guard",
                            "node_history",
                            "node_inspector",
                        ),
                    )
                if isinstance(node, ast.Import):
                    self.assertTrue(
                        all(
                            item.name
                            not in ("smoke", "qualify", "offline_guard", "node_history")
                            for item in node.names
                        )
                    )

    def test_critical_proof_predicates_preserve_qualified_source_ast(self):
        old = ast.parse((ROOT / "scripts/kubernetes/node_inspector.py").read_text())
        new = ast.parse((BUNDLE / "authority_verifier.py").read_text())
        originals = {
            node.name: node for node in old.body if isinstance(node, ast.FunctionDef)
        }
        current = {
            node.name: node
            for node in next(n for n in new.body if isinstance(n, ast.ClassDef)).body
            if isinstance(node, ast.FunctionDef)
        }

        class Normalize(ast.NodeTransformer):
            def visit_Subscript(self, node):
                if (
                    isinstance(node.value, ast.Attribute)
                    and isinstance(node.value.value, ast.Name)
                    and node.value.value.id == "self"
                    and node.value.attr == "binding"
                    and isinstance(node.slice, ast.Constant)
                    and node.slice.value == "namespace"
                ):
                    return ast.Constant("smolbox-preview")
                if (
                    isinstance(node.value, ast.Name)
                    and node.value.id == "enrollment"
                    and isinstance(node.slice, ast.Constant)
                    and node.slice.value == "authority_generation"
                ):
                    node.slice = ast.Constant("epoch")
                return self.generic_visit(node)

            def visit_Attribute(self, node):
                if isinstance(node.value, ast.Name) and node.value.id == "self":
                    return ast.Name(
                        {"guard": "offline_guard"}.get(node.attr, node.attr), ast.Load()
                    )
                return self.generic_visit(node)

        for name in ("capture", "cleanup", "check_runtime"):
            function = copy.deepcopy(current[name])
            function.args.args = function.args.args[1:]
            normalized = ast.dump(Normalize().visit(function), include_attributes=False)
            self.assertEqual(
                normalized, ast.dump(originals[name], include_attributes=False), name
            )

    def test_history_and_lifecycle_predicates_preserve_qualified_source_ast(self):
        old_history = ast.parse(
            (ROOT / "scripts/kubernetes/node_history.py").read_text()
        )
        new_history = ast.parse((BUNDLE / "authority_history.py").read_text())
        old_functions = {
            node.name: node
            for node in old_history.body
            if isinstance(node, ast.FunctionDef)
        }
        new_functions = {
            node.name: node
            for node in new_history.body
            if isinstance(node, ast.FunctionDef)
        }
        for name in (
            "schema",
            "enroll",
            "verify_schema",
            "event_hash",
            "record",
            "initial_ledger",
            "reconcile",
        ):
            self.assertEqual(
                ast.dump(new_functions[name]), ast.dump(old_functions[name]), name
            )

        class Normalize(ast.NodeTransformer):
            def visit_Call(self, node):
                if (
                    isinstance(node.func, ast.Name)
                    and node.func.id == "str"
                    and len(node.args) == 1
                    and isinstance(node.args[0], ast.Attribute)
                    and node.args[0].attr == "SYSTEMCTL"
                ):
                    return ast.Constant("/usr/bin/systemctl")
                return self.generic_visit(node)

            def visit_Attribute(self, node):
                if isinstance(node.value, ast.Name) and node.value.id == "self":
                    return ast.Name(node.attr, ast.Load())
                return self.generic_visit(node)

        old_lifecycle = ast.parse(
            (ROOT / "scripts/kubernetes/node_lifecycle.py").read_text()
        )
        originals = {
            node.name: node
            for node in old_lifecycle.body
            if isinstance(node, ast.FunctionDef)
        }
        current = ast.parse((BUNDLE / "authority_lifecycle.py").read_text()).body
        methods = next(node for node in current if isinstance(node, ast.ClassDef)).body
        for method in methods:
            if not isinstance(method, ast.FunctionDef) or method.name == "__init__":
                continue
            value = copy.deepcopy(method)
            value.args.args = value.args.args[1:]
            self.assertEqual(
                ast.dump(Normalize().visit(value)),
                ast.dump(originals[value.name]),
                value.name,
            )


class TransactionalInspectionTest(unittest.TestCase):
    """Real SQLite/files/ledger; API, processes, guard and daemon identity are fixtures."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.engine = Verifier(config())
        # This suite supplies fixture kernel/API/runtime roots. Actual root
        # custody is verified separately and by the manual Linux installation.
        custody = patch(
            "authority_verifier.verify_filesystem", return_value=self.engine.config
        )
        custody.start()
        self.addCleanup(custody.stop)
        self.engine.STATE = self.root
        # URI metacharacters must refer to this exact database inode.
        self.engine.DATABASE = self.root / "runtime?#.db"
        self.engine.ENROLLMENT = self.root / "enrollment.json"
        self.engine.LEDGER = self.root / "ledger.json"
        for name in ("VM_ROOT", "SHARE_ROOT"):
            directory = self.root / name
            directory.mkdir()
            setattr(self.engine, name, directory)
        self.engine.bundle = self.root / "programs"
        self.engine.bundle.mkdir()
        for name in assets.PROGRAMS:
            shutil.copyfile(BUNDLE / name, self.engine.bundle / name)
        write_manifest(self.engine.bundle)
        self.receipt = copy.deepcopy(json.loads(VECTORS.read_text())["receipt"])
        self.uid = self.receipt["pod_uid"]
        self.sid = self.receipt["observation"]["sandbox_ids"][0]
        self.process = self.receipt["observation"]["processes"][0]
        self.identity = {
            key: self.engine.binding[key]
            for key in (
                "cluster_anchor_uid",
                "namespace_uid",
                "node_uid",
                "node_boot_id",
            )
        }
        self.write(
            "CREATE TABLE vms(name TEXT PRIMARY KEY NOT NULL,data BLOB NOT NULL)"
        )
        self.write(
            "CREATE TABLE vm_create_reservations(name TEXT PRIMARY KEY NOT NULL)"
        )
        enrollment = history.enroll(self.engine.DATABASE, self.identity, lambda: None)
        lifecycle_root = self.root / "cgroups"
        lifecycle_root.mkdir()
        (lifecycle_root / "kubepods.slice").mkdir()
        self.engine.lifecycle.ROOT = lifecycle_root
        self.cgroup = self.engine.lifecycle.path(self.uid)
        info = lifecycle_root.stat()
        lifecycle = {
            "mount": {"id": 33, "device": info.st_dev, "inode": info.st_ino},
            "daemons": [{"pid": 10, "start_ticks": 100}],
        }
        programs = self.engine.programs()
        manifest = contract.sha256({"version": 1, "files": programs})
        fields = {
            "version": 1,
            "binding_generation": self.engine.binding["generation"],
            "history_epoch": enrollment["epoch"],
            "enrollment_nonce": "1" * 64,
            "verifier_manifest_sha256": manifest,
            "configuration_sha256": self.engine.config.sha256,
        }
        enrollment.update(
            {
                "active": True,
                "lifecycle": lifecycle,
                "programs": programs,
                **{
                    key: fields[key]
                    for key in (
                        "enrollment_nonce",
                        "verifier_manifest_sha256",
                        "configuration_sha256",
                    )
                },
                "authority_generation": contract.generation(fields),
            }
        )
        self.enrollment = enrollment
        history.atomic_json(self.engine.ENROLLMENT, enrollment)
        history.atomic_json(
            self.engine.LEDGER, {**history.initial_ledger(enrollment), "lifecycles": {}}
        )
        self.sandboxes, self.processes, self.pods = [], [], []
        for name, side_effect in (
            ("identity", lambda: self.identity),
            ("cri", lambda: self.sandboxes),
            ("physical", lambda _: self.processes),
            ("check_runtime", lambda *_: None),
            ("isolation", lambda *_: self.receipt["observation"]["interfaces"]),
            (
                "birth",
                lambda _: self.process["start_ticks"] if self.processes else None,
            ),
            ("kube", lambda *a, **k: None if k.get("absent") else {"items": self.pods}),
        ):
            mocked = patch.object(self.engine, name, side_effect=side_effect)
            mocked.start()
            self.addCleanup(mocked.stop)
        mocked = patch.object(
            self.engine.lifecycle,
            "current",
            side_effect=lambda *_: copy.deepcopy(lifecycle),
        )
        mocked.start()
        self.addCleanup(mocked.stop)

    def write(self, sql, arguments=()):
        connection = sqlite3.connect(self.engine.DATABASE)
        try:
            with connection:
                connection.execute(sql, arguments)
        finally:
            connection.close()

    def inspect(self, action, **arguments):
        return self.engine.inspect(
            {
                "version": 1,
                "action": action,
                "binding": self.engine.binding,
                **arguments,
            }
        )

    def start(self):
        data = {
            "name": self.sid,
            "runtime_managed": True,
            "cpus": 2,
            "mem": 1024,
            "pid": None,
            "pid_start_time": None,
        }
        self.write("INSERT INTO vms VALUES(?,?)", (self.sid, json.dumps(data).encode()))
        data.update(pid=self.process["pid"], pid_start_time=self.process["start_ticks"])
        self.write(
            "UPDATE vms SET data=? WHERE name=?", (json.dumps(data).encode(), self.sid)
        )
        self.sandboxes = [
            {
                "id": self.sid,
                "metadata": {
                    "uid": self.uid,
                    "namespace": config().binding["namespace"],
                },
            }
        ]
        self.processes = [self.process]
        self.pods = [{"metadata": {"uid": self.uid}}]
        self.cgroup.mkdir()

    def finish(self):
        self.write("DELETE FROM vms WHERE name=?", (self.sid,))
        self.sandboxes, self.processes, self.pods = [], [], []
        self.cgroup.rmdir()

    def test_capture_restart_cleanup_retains_original_uid_and_committed_prefix(self):
        self.assertTrue(self.inspect("check")["value"]["idle"])
        self.start()
        captured = self.inspect("capture", pod_uid=self.uid)
        contract.observation(captured["value"])
        self.receipt["observation"] = captured["value"]
        self.assertEqual(captured["journal"]["watermark"], 2)
        committed = self.engine.read_state(self.engine.LEDGER)
        self.assertEqual(committed["owners"], {self.sid: self.uid})
        self.assertIn(self.uid, committed["lifecycles"])
        self.finish()
        # Cleanup must not depend on isolation/runtime asset health. It must
        # still verify all original lifecycle/history witnesses after restart.
        self.engine.check_runtime.side_effect = RuntimeError("unhealthy assets")
        self.engine.check_runtime.reset_mock()
        result = self.inspect("cleanup", receipt=self.receipt)
        self.engine.check_runtime.assert_not_called()
        self.assertEqual(result["value"]["version"], 3)
        self.assertEqual(result["value"]["terminated_processes"], [self.process])
        self.assertEqual(result["journal"]["watermark"], 3)
        self.assertEqual(
            result["value"]["observer_epoch"], self.enrollment["authority_generation"]
        )
        self.assertEqual(
            self.engine.read_state(self.engine.LEDGER)["watermark_hash"],
            result["journal"]["prefix_sha256"],
        )
        self.engine.check_runtime.side_effect = lambda *_: None
        self.assertTrue(self.inspect("check")["value"]["idle"])

    def test_changed_runtime_during_capture_returns_no_evidence_and_keeps_old_ledger(
        self,
    ):
        self.start()
        prior = self.engine.LEDGER.read_bytes()
        capture = self.engine.capture

        def change(*arguments):
            value = capture(*arguments)
            self.write("DELETE FROM vms WHERE name=?", (self.sid,))
            return value

        with patch.object(self.engine, "capture", side_effect=change):
            with self.assertRaisesRegex(RuntimeError, "runtime or node changed"):
                self.inspect("capture", pod_uid=self.uid)
        self.assertEqual(self.engine.LEDGER.read_bytes(), prior)

    def test_ledger_publication_failure_never_returns_observation(self):
        self.start()
        original = history.atomic_json

        def publish(path, value, tick):
            original(path, value, tick)
            raise RuntimeError("interrupted after publication")

        with patch.object(history, "atomic_json", side_effect=publish):
            with self.assertRaisesRegex(RuntimeError, "after publication"):
                self.inspect("capture", pod_uid=self.uid)
        # A retry revalidates the real committed ledger, never invents a new
        # epoch or substitutes another process incarnation.
        result = self.inspect("capture", pod_uid=self.uid)
        self.assertEqual(result["value"]["processes"], [self.process])
        self.assertEqual(
            result["value"]["observer_epoch"], self.enrollment["authority_generation"]
        )

    def test_sqlite_wait_cannot_reset_the_original_operation_deadline(self):
        writer = sqlite3.connect(self.engine.DATABASE)
        try:
            writer.execute("BEGIN EXCLUSIVE")
            self.engine.runner = Runner(timeout_ms=40)
            started = time.monotonic()
            with self.assertRaises((sqlite3.OperationalError, ValueError)):
                self.inspect("check")
            self.assertLess(time.monotonic() - started, 0.5)
        finally:
            writer.rollback()
            writer.close()


class LedgerInterruptionTest(unittest.TestCase):
    def test_each_publication_boundary_preserves_or_advances_without_repairing_partial_state(
        self,
    ):
        for boundary in range(1, 6):
            with self.subTest(
                boundary=boundary
            ), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "ledger.json"
                old, new = {"watermark": 1}, {"watermark": 2}
                history.atomic_json(path, old)
                calls = 0

                def interrupt():
                    nonlocal calls
                    calls += 1
                    if calls == boundary:
                        raise RuntimeError("interrupted publication")

                with self.assertRaisesRegex(RuntimeError, "interrupted publication"):
                    history.atomic_json(path, new, interrupt)
                self.assertEqual(
                    history.decode(path.read_bytes()), old if boundary <= 3 else new
                )
                partial = path.with_suffix(".part")
                if boundary in (2, 3):
                    self.assertTrue(partial.exists())
                    with self.assertRaises(FileExistsError):
                        history.atomic_json(path, new)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class PhysicalInventoryTest(unittest.TestCase):
    def test_original_process_birth_kvm_executable_and_unknown_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            engine = Verifier(config())
            engine.paths["proc_root"] = root / "proc"
            engine.RUNTIME = root / "runtime"
            engine.VM_ROOT, engine.SHARE_ROOT = root / "vms", root / "shares"
            engine.RUNTIME.mkdir()
            shim = engine.RUNTIME / "containerd-shim-smolvm-v2"
            shim.write_bytes(b"approved fixture image")
            proc = engine.paths["proc_root"] / "1234"
            proc.mkdir(parents=True)
            sid = "d" * 64
            directory = hashlib.sha256(sid.encode()).hexdigest()[:16]
            (proc / "exe").symlink_to(shim)
            (proc / "cmdline").write_bytes(
                b"shim\0_boot-vm\0"
                + str(engine.VM_ROOT / directory / "boot-config.json").encode()
                + b"\0"
            )
            (proc / "stat").write_text(
                "1234 (fixture) " + " ".join(["S", "1"] + ["0"] * 17 + ["777"])
            )
            (proc / "fd").mkdir()
            for index, target in enumerate(contract.KVM):
                (proc / "fd" / str(index)).symlink_to(target)
            result = engine.physical({sid: {}})
            self.assertEqual(
                result,
                [
                    {
                        "sandbox_id": sid,
                        "vm_directory": directory,
                        "pid": 1234,
                        "start_ticks": 777,
                        "exe_sha256": hashlib.sha256(shim.read_bytes()).hexdigest(),
                        "kvm": contract.KVM,
                    }
                ],
            )
            with self.assertRaisesRegex(RuntimeError, "unmapped boot process"):
                engine.physical({})
            (proc / "cmdline").write_bytes(b"unknown-process\0")
            with self.assertRaisesRegex(RuntimeError, "unmapped KVM process"):
                engine.physical({sid: {}})
            for fd in (proc / "fd").iterdir():
                fd.unlink()
            engine.VM_ROOT.mkdir()
            leaked = engine.VM_ROOT / "foreign"
            leaked.mkdir()
            with self.assertRaisesRegex(RuntimeError, "unmapped VM directory"):
                engine.physical({sid: {}})
            self.assertTrue(leaked.exists())


class GuardComparisonTest(unittest.TestCase):
    def setUp(self):
        import offline_guard

        self.legacy = offline_guard
        self.guard = Guard(config(), lambda _: b"")
        self.table = {
            "nftables": [
                {
                    "table": {
                        "name": self.guard.TABLE,
                        "family": "bridge",
                        "comment": self.guard.MARKER,
                    }
                },
                {
                    "set": {
                        "name": "isolated_ports",
                        "type": "ifname",
                        "elem": ["vethcafe"],
                    }
                },
            ]
        }
        for name, hook, key in (
            ("from_pod", "prerouting", "iifname"),
            ("to_pod", "postrouting", "oifname"),
        ):
            self.table["nftables"].extend(
                [
                    {
                        "chain": {
                            "name": name,
                            "hook": hook,
                            "prio": -300,
                            "type": "filter",
                            "policy": "accept",
                        }
                    },
                    {
                        "rule": {
                            "chain": name,
                            "expr": [
                                {
                                    "match": {
                                        "op": "==",
                                        "left": {"meta": {"key": key}},
                                        "right": "@isolated_ports",
                                    }
                                },
                                {"counter": {"packets": 0, "bytes": 0}},
                                {"drop": None},
                            ],
                        }
                    },
                ]
            )

    def test_same_rules_match_legacy_and_both_reject_changed_isolation(self):
        self.assertEqual(self.guard.rules(self.table), self.legacy.rules(self.table))
        for mutate in (
            lambda v: v["nftables"][0]["table"].update(comment="foreign"),
            lambda v: v["nftables"][1]["set"].update(elem=["eth0"]),
            lambda v: v["nftables"][2]["chain"].update(prio=0),
            lambda v: v["nftables"][3]["rule"]["expr"].__setitem__(2, {"accept": None}),
            lambda v: v["nftables"].append(copy.deepcopy(v["nftables"][3])),
        ):
            changed = copy.deepcopy(self.table)
            mutate(changed)
            for rules in (self.guard.rules, self.legacy.rules):
                with self.assertRaises(RuntimeError):
                    rules(changed)

    def test_original_cri_netns_peer_bridge_mapping_matches_legacy(self):
        uid, sid = "11111111-2222-4333-8444-555555555555", "d" * 64
        pods = [
            {
                "metadata": {"uid": uid, "namespace": config().binding["namespace"]},
                "status": {"podIP": "10.42.0.2"},
            }
        ]
        sandboxes = [{"id": sid, "metadata": {"uid": uid}}]
        links = [
            {"ifindex": 3, "ifname": "cni0"},
            {"ifindex": 9, "ifname": "vethcafe", "master": 3},
        ]

        def command(arguments):
            data = (
                {
                    "info": {
                        "runtimeSpec": {
                            "linux": {
                                "namespaces": [
                                    {"type": "network", "path": "/run/netns/cni-" + uid}
                                ]
                            }
                        }
                    }
                }
                if "inspectp" in arguments
                else [{"link_index": 9}]
            )
            return subprocess.CompletedProcess(
                arguments, 0, json.dumps(data).encode(), b""
            )

        with patch.object(self.guard, "command", side_effect=command), patch.object(
            self.legacy, "command", side_effect=command
        ):
            self.assertEqual(
                self.guard.mapped_ports(pods, sandboxes, links),
                self.legacy.mapped_ports(pods, sandboxes, links),
            )
            links[1]["master"] = 99
            for mapper in (self.guard.mapped_ports, self.legacy.mapped_ports):
                with self.assertRaisesRegex(RuntimeError, "not on cni0"):
                    mapper(pods, sandboxes, links)

    def test_lifecycle_uses_the_approved_systemctl_path(self):
        value = config().as_dict()
        value["paths"]["systemctl_executable"] = "/approved/systemctl"
        lifecycle = Lifecycle(Configuration.from_dict(value))
        with patch.object(lifecycle, "PROC") as proc:
            proc.__truediv__.return_value.__truediv__.return_value.resolve.side_effect = RuntimeError(
                "fixture stop"
            )
            with patch.object(lifecycle, "K3S"):
                commands = []

                def run(argv):
                    commands.append(argv)
                    return b"123"

                with self.assertRaisesRegex(RuntimeError, "fixture stop"):
                    lifecycle.daemons(run, lambda _: "a" * 64, lambda: None)
                self.assertEqual(commands[0][0], "/approved/systemctl")


def reference_module(name, filename, replacements=None):
    """Load a second test namespace so original lab tests retain their globals."""
    module = types.ModuleType(name)
    module.__file__ = str(ROOT / "scripts/kubernetes" / filename)
    module.__spec__ = importlib.util.spec_from_file_location(name, module.__file__)
    source = Path(module.__file__).read_text()
    for before, after in (replacements or {}).items():
        source = source.replace(before, after)
    exec(compile(source, module.__file__, "exec"), module.__dict__)
    return module


def load_tests(loader, tests, pattern):
    legacy_history = reference_module(
        "authority_history_reference", "test_node_history.py"
    )
    legacy_history.history = history
    tests.addTests(loader.loadTestsFromModule(legacy_history))
    legacy_lifecycle = reference_module(
        "authority_lifecycle_reference", "test_node_lifecycle.py"
    )
    legacy_lifecycle.lifecycle = Lifecycle(config())
    tests.addTests(loader.loadTestsFromModule(legacy_lifecycle))

    # The physical predicates are unchanged; the deliberate public epoch rename
    # is isolated to these comparison fixtures. Lock/owner tests use RunnerTest.
    legacy_inspector = reference_module(
        "authority_inspector_reference",
        "test_node_inspector.py",
        {
            'self.enrollment = {"epoch": EPOCH}': 'self.enrollment = {"epoch": EPOCH, "authority_generation": EPOCH}',
            'self.enrollment["epoch"] = "changed"': 'self.enrollment["authority_generation"] = "changed"',
        },
    )
    engine = Verifier(config())
    engine.hashlib = hashlib
    legacy_inspector.inspector = engine
    suite = loader.loadTestsFromModule(legacy_inspector)
    for group in suite:
        for case in group:
            if "test_lock_contention" not in case.id():
                tests.addTest(case)
    return tests


if __name__ == "__main__":
    unittest.main()
