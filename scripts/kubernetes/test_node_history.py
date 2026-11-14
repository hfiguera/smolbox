"""Manual offline transaction-history tests; no host/VM/Kubernetes access."""

import copy
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import node_history as history


SID = "a" * 64
OTHER = "b" * 64
UID = "11111111-2222-3333-4444-555555555555"


class HistoryTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.database = Path(self.directory.name) / "runtime.db"
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("CREATE TABLE vms(name TEXT PRIMARY KEY NOT NULL,data BLOB NOT NULL)")
            connection.execute("CREATE TABLE vm_create_reservations(name TEXT PRIMARY KEY NOT NULL)")
        self.enrollment = history.enroll(self.database, {"boot": "original"}, lambda: None)
        self.ledger = history.initial_ledger(self.enrollment)

    def write(self, sql, parameters=()):
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(sql, parameters)

    def value(self, sid=SID, pid=None, ticks=None):
        return json.dumps({"name": sid, "runtime_managed": True, "cpus": 2, "mem": 1024,
                           "pid": pid, "pid_start_time": ticks}).encode()

    def create(self, sid=SID):
        self.write("INSERT INTO vms VALUES(?,?)", (sid, self.value(sid)))

    def start(self, sid=SID, pid=123, ticks=456):
        self.write("UPDATE vms SET data=? WHERE name=?", (self.value(sid, pid, ticks), sid))

    def snapshot(self):
        return history.snapshot(self.database, self.enrollment, self.ledger)

    def sandbox(self, sid=SID, uid=UID):
        return {"id": sid, "metadata": {"uid": uid, "namespace": "smolbox-preview"}}

    def test_atomic_insert_update_delete_survives_observer_restart(self):
        self.create()
        self.start()
        self.ledger, complete = history.reconcile(self.snapshot(), self.ledger, [self.sandbox()], "smolbox-preview")
        self.assertTrue(complete)
        path = Path(self.directory.name) / "ledger.json"
        history.atomic_json(path, self.ledger)
        self.ledger = history.decode(path.read_bytes())
        self.write("DELETE FROM vms WHERE name=?", (SID,))
        audit = self.snapshot()
        self.assertEqual(audit["watermark"], 3)
        self.assertEqual(audit["attempts"][SID]["processes"], {(123, 456)})
        self.assertEqual(audit["material"], {})
        self.ledger, complete = history.reconcile(audit, self.ledger, [], "smolbox-preview")
        self.assertTrue(complete)
        self.assertEqual(self.ledger["owners"], {SID: UID})

    def test_attempt_created_and_deleted_between_snapshots_is_not_missed(self):
        self.create()
        self.start()
        self.write("DELETE FROM vms")
        audit = self.snapshot()
        self.assertEqual(set(audit["attempts"]), {SID})
        _, complete = history.reconcile(audit, self.ledger, [], "smolbox-preview")
        self.assertFalse(complete)

    def test_failed_transaction_cannot_append_a_phantom_event(self):
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("BEGIN")
            connection.execute("INSERT INTO vms VALUES(?,?)", (SID, self.value()))
            connection.rollback()
        self.assertEqual(self.snapshot()["watermark"], 0)

    def test_original_uid_mapping_is_immutable(self):
        self.create()
        self.ledger, _ = history.reconcile(self.snapshot(), self.ledger, [self.sandbox()], "smolbox-preview")
        with self.assertRaisesRegex(RuntimeError, "Pod UID changed"):
            history.reconcile(self.snapshot(), self.ledger,
                              [self.sandbox(uid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")], "smolbox-preview")

    def test_multiple_attempts_and_same_sid_restart_remain_visible(self):
        self.create()
        self.start()
        self.start(pid=124, ticks=457)
        self.write("DELETE FROM vms")
        self.create()
        self.create(OTHER)
        audit = self.snapshot()
        self.assertEqual(audit["attempts"][SID]["inserts"], 2)
        self.assertEqual(audit["attempts"][SID]["processes"], {(123, 456), (124, 457)})
        self.assertEqual(set(audit["attempts"]), {SID, OTHER})

    def test_lost_event_or_tail_cannot_look_like_empty_inventory(self):
        self.create()
        self.start()
        self.write(f"DELETE FROM {history.EVENTS} WHERE seq=1")
        with self.assertRaisesRegex(RuntimeError, "sequence/identity gap"):
            self.snapshot()

    def test_lost_complete_tail_fails_autoincrement_check(self):
        self.create()
        self.write("DELETE FROM vms")
        self.write(f"DELETE FROM {history.EVENTS}")
        with self.assertRaisesRegex(RuntimeError, "tail lost"):
            self.snapshot()

    def test_rewritten_prefix_cannot_cross_saved_watermark(self):
        self.create()
        self.ledger, _ = history.reconcile(self.snapshot(), self.ledger, [self.sandbox()], "smolbox-preview")
        altered = self.value().replace(b'"pid": null', b'"pid":null')
        self.write(f"UPDATE {history.EVENTS} SET new_data=?", (altered,))
        self.write(f"DROP TRIGGER {history.PREFIX}update")
        self.write("UPDATE vms SET data=?", (altered,))
        self.write(history.schema(self.enrollment["epoch"])[history.PREFIX + "update"])
        with self.assertRaisesRegex(RuntimeError, "rollback/preimage"):
            self.snapshot()

    def test_runtime_row_bypass_is_detected_even_if_triggers_are_restored(self):
        self.create()
        self.write(f"DROP TRIGGER {history.PREFIX}update")
        self.start()
        self.write(history.schema(self.enrollment["epoch"])[history.PREFIX + "update"])
        with self.assertRaisesRegex(RuntimeError, "state differs"):
            self.snapshot()

    def test_missing_trigger_and_epoch_change_fail_closed(self):
        self.write(f"DELETE FROM {history.EPOCH}")
        with self.assertRaisesRegex(RuntimeError, "epoch changed"):
            self.snapshot()
        self.write(f"INSERT INTO {history.EPOCH} VALUES(?)", (self.enrollment["epoch"],))
        self.write(f"DROP TRIGGER {history.PREFIX}insert")
        with self.assertRaisesRegex(RuntimeError, "schema changed"):
            self.snapshot()

    def test_database_replacement_and_ledger_rollback_fail_closed(self):
        self.create()
        bad = copy.deepcopy(self.enrollment)
        bad["database_inode"] += 1
        with self.assertRaisesRegex(RuntimeError, "database replaced"):
            history.snapshot(self.database, bad, self.ledger)
        self.ledger["watermark"] = 2
        with self.assertRaisesRegex(RuntimeError, "rollback/preimage"):
            self.snapshot()

    def test_nonempty_baseline_and_reenrollment_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "already enrolled"):
            history.enroll(self.database, {}, lambda: None)
        other = Path(self.directory.name) / "nonempty.db"
        with closing(sqlite3.connect(other)) as connection, connection:
            connection.execute("CREATE TABLE vms(name TEXT,data BLOB)")
            connection.execute("INSERT INTO vms VALUES(?,?)", (SID, self.value()))
        with self.assertRaisesRegex(RuntimeError, "not empty"):
            history.enroll(other, {}, lambda: None)

    def test_size_and_event_bounds_are_checked_before_loading_blobs(self):
        self.create()
        with patch.object(history, "MAX_RECORD", 10):
            with self.assertRaisesRegex(RuntimeError, "allocation bound"):
                self.snapshot()
        with patch.object(history, "MAX_EVENTS", 0):
            with self.assertRaisesRegex(RuntimeError, "allocation bound"):
                self.snapshot()
        with patch.object(history, "MAX_HISTORY", 10):
            with self.assertRaisesRegex(RuntimeError, "allocation bound"):
                self.snapshot()

    def test_unknown_reservation_foreign_namespace_and_duplicate_cri_fail_closed(self):
        self.create()
        foreign = self.sandbox()
        foreign["metadata"]["namespace"] = "another"
        with self.assertRaisesRegex(RuntimeError, "outside enrolled"):
            history.reconcile(self.snapshot(), self.ledger, [foreign], "smolbox-preview")
        with self.assertRaisesRegex(RuntimeError, "duplicate CRI"):
            history.reconcile(self.snapshot(), self.ledger, [self.sandbox()] * 2, "smolbox-preview")
        self.write("INSERT INTO vm_create_reservations VALUES(?)", (OTHER,))
        with self.assertRaisesRegex(RuntimeError, "creation in progress"):
            self.snapshot()

    def test_primary_key_rename_cannot_erase_authority(self):
        self.create()
        with self.assertRaises(sqlite3.IntegrityError):
            self.write("UPDATE vms SET name=?", (OTHER,))
        self.assertEqual(set(self.snapshot()["material"]), {SID})


if __name__ == "__main__":
    unittest.main()
