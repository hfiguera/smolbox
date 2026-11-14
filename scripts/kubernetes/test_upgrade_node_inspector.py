"""Offline administrator-maintenance invariants; never opens the real lab."""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

import node_history as history
import upgrade_node_inspector as maintenance


class UpgradeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.source, self.target, self.state = [root / name for name in ["source", "target", "state"]]
        for path in [self.source, self.target, self.state]:
            path.mkdir()
        for name in maintenance.inspector.PROGRAMS:
            (self.source / name).write_bytes(b"original")
            if name != "node_lifecycle.py":
                (self.target / name).write_bytes(b"original")
        (self.source / "node_inspector.py").write_bytes(b"approved source")
        self.approved = maintenance.digest(self.source / "node_inspector.py")
        prior = patch.object(maintenance, "OLD_INSPECTOR", maintenance.digest(self.target / "node_inspector.py"))
        prior.start()
        self.addCleanup(prior.stop)
        maintenance.inspector.DEADLINE = time.monotonic() + 30
        self.database = root / "runtime.db"
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("CREATE TABLE vms(name TEXT PRIMARY KEY NOT NULL,data BLOB NOT NULL)")
            connection.execute("CREATE TABLE vm_create_reservations(name TEXT PRIMARY KEY NOT NULL)")
        self.enrollment = history.enroll(self.database, {"node": "original"}, lambda: None)
        self.enrollment["programs"] = {name: maintenance.digest(self.target / name) for name in maintenance.inspector.PROGRAMS if name != "node_lifecycle.py"}
        approved = patch.object(maintenance.inspector, "LIFECYCLE_SHA256", maintenance.digest(self.source / "node_lifecycle.py"))
        approved.start()
        self.addCleanup(approved.stop)
        sid = "a" * 64
        raw = json.dumps({"name": sid, "runtime_managed": True, "cpus": 2, "mem": 1024}).encode()
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("INSERT INTO vms VALUES(?,?)", (sid, raw))
            connection.execute("DELETE FROM vms")
        self.ledger = history.initial_ledger(self.enrollment)
        self.ledger["owners"][sid] = "11111111-2222-3333-4444-555555555555"
        history.atomic_json(self.state / "node-history-enrollment.json", self.enrollment)
        history.atomic_json(self.state / "node-history-ledger.json", self.ledger)
        self.original = history.snapshot(self.database, self.enrollment, self.ledger)

    def upgrade(self, baseline=lambda *_: {"empty": True, "lifecycle": {"pinned": True}}):
        return maintenance.upgrade(self.source, self.target, self.state, self.database, self.approved, baseline)

    def test_preserves_all_events_owners_and_database_inode_with_new_epoch(self):
        result = self.upgrade()
        self.assertEqual(result["status"], "complete")
        enrollment = history.decode((self.state / "node-history-enrollment.json").read_bytes())
        ledger = history.decode((self.state / "node-history-ledger.json").read_bytes())
        after = history.snapshot(self.database, enrollment, ledger)
        self.assertEqual(after["hashes"], self.original["hashes"])
        self.assertEqual(ledger["owners"], self.ledger["owners"])
        self.assertEqual(enrollment["database_inode"], self.database.stat().st_ino)
        self.assertNotEqual(enrollment["epoch"], self.enrollment["epoch"])
        self.assertEqual(maintenance.digest(self.target / "node_inspector.py"), self.approved)
        self.assertEqual(self.upgrade(), result)

    def test_incomplete_ownership_and_failed_empty_baseline_preserve_original_files(self):
        def fail(*_):
            raise RuntimeError("active node")
        with self.assertRaisesRegex(RuntimeError, "active node"):
            self.upgrade(fail)
        self.assertFalse((self.state / "node-history-proof-v3-upgrade.json").exists())
        ledger = {**self.ledger, "owners": {}}
        history.atomic_json(self.state / "node-history-ledger.json", ledger)
        with self.assertRaisesRegex(RuntimeError, "ownership history incomplete"):
            self.upgrade()
        self.assertEqual((self.target / "node_inspector.py").read_bytes(), b"original")

    def test_unapproved_source_other_program_changes_and_installed_drift_reject(self):
        self.approved = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "approval mismatch"):
            self.upgrade()
        self.approved = maintenance.digest(self.source / "node_inspector.py")
        (self.source / "smoke.py").write_bytes(b"other change")
        with self.assertRaisesRegex(RuntimeError, "only the approved inspector"):
            self.upgrade()
        (self.target / "smoke.py").write_bytes(b"installed drift")
        with self.assertRaisesRegex(RuntimeError, "differs from enrollment"):
            self.upgrade()

    def test_interrupted_upgrade_is_not_automatically_rebaselined(self):
        original_epoch = self.enrollment["epoch"]
        with patch.object(maintenance, "program", side_effect=OSError("interrupted write")):
            with self.assertRaisesRegex(OSError, "interrupted write"):
                self.upgrade()
        self.assertEqual(history.decode((self.state / "node-history-enrollment.json").read_bytes())["epoch"], original_epoch)
        with self.assertRaisesRegex(RuntimeError, "partial/different maintenance"):
            self.upgrade()
        self.assertEqual((self.target / "node_inspector.py").read_bytes(), b"original")


if __name__ == "__main__":
    unittest.main()
