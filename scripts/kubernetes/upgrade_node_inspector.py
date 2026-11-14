#!/usr/bin/env python3
"""Administrator-only, history-preserving transition to cleanup proof version 3.

All application controllers must already be positively quiescent. This is a
manual empty-node maintenance operation, never an application recovery action.
An interrupted upgrade fails closed; it is never automatically rebaselined.
"""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import sys
import time
import uuid

import node_history as history
import node_inspector as inspector

OLD_INSPECTOR = "800f8d58af96a12dfd9c7ec4dbfc03f07c0a57bdfab0ba66c65ccdbc570dc683"
require = history.require


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def program(path, data):
    temporary = path.with_suffix(".next")
    with temporary.open("xb") as writer:
        writer.write(data)
        writer.flush()
        os.fsync(writer.fileno())
    temporary.chmod(0o644)
    temporary.replace(path)
    directory = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def upgrade(source, target, state, database, approved, baseline):
    require(re.fullmatch(r"[a-f0-9]{64}", approved) is not None, "explicit inspector approval required")
    approved_source = (source / "node_inspector.py").read_bytes()
    require(len(approved_source) <= history.MAX_RECORD and
            hashlib.sha256(approved_source).hexdigest() == approved, "new source approval mismatch")
    lifecycle_source = (source / "node_lifecycle.py").read_bytes()
    require(hashlib.sha256(lifecycle_source).hexdigest() == inspector.LIFECYCLE_SHA256, "lifecycle source approval mismatch")
    enrollment_path = state / "node-history-enrollment.json"
    ledger_path = state / "node-history-ledger.json"
    plan_path = state / "node-history-proof-v3-upgrade.json"
    with (state / "node-history.lock").open("a") as lock:
        inspector.acquire(lock)
        enrollment = history.decode(enrollment_path.read_bytes())
        ledger = history.decode(ledger_path.read_bytes())
        current = {name: digest(target / name) for name in enrollment["programs"]}
        staged = {name: digest(source / name) for name in inspector.PROGRAMS}
        require(current == enrollment["programs"], "installed source differs from enrollment")
        require(staged["node_inspector.py"] == approved, "approved source changed during maintenance")
        if plan_path.exists():
            plan = history.decode(plan_path.read_bytes())
            require(plan["status"] == "complete" and current == staged and
                    current["node_inspector.py"] == approved and enrollment["epoch"] == plan["new_epoch"],
                    "partial/different maintenance requires administrator investigation")
            history.snapshot(database, enrollment, ledger)
            return plan
        require(current["node_inspector.py"] == OLD_INSPECTOR, "unsupported prior inspector")
        require(set(current) == set(inspector.PROGRAMS) - {"node_lifecycle.py"} and
                all(current[name] == staged[name] for name in current if name != "node_inspector.py") and
                staged["node_lifecycle.py"] == inspector.LIFECYCLE_SHA256,
                "only the approved inspector/lifecycle programs may change")
        with history.connect(database, write=True) as connection:
            connection.execute("BEGIN IMMEDIATE")
            audit = history.snapshot(database, enrollment, ledger)
            require(not audit["material"], "runtime records remain")
            advanced, complete = history.reconcile(audit, ledger, [], "smolbox-preview")
            require(complete, "ownership history incomplete")
            facts = baseline(enrollment, audit)
            next_epoch = str(uuid.uuid4())
            plan = {"status": "prepared", "old_epoch": enrollment["epoch"], "new_epoch": next_epoch,
                    "old_enrollment": enrollment, "old_ledger": ledger,
                    "new_inspector_sha256": approved, "baseline": facts,
                    "journal_watermark": audit["watermark"], "journal_hash": audit["hashes"][-1]}
            require(len(json.dumps(plan, separators=(",", ":")).encode()) <= history.MAX_RECORD, "maintenance plan allocation bound")
            history.atomic_json(plan_path, plan)
            next_enrollment = {**enrollment, "epoch": next_epoch, "programs": staged, "lifecycle": facts["lifecycle"]}
            next_ledger = {**advanced, "epoch": next_epoch, "lifecycles": {}}
            changed = connection.execute(f"UPDATE {history.EPOCH} SET value=? WHERE value=?",
                                         (next_epoch, enrollment["epoch"]))
            require(changed.rowcount == 1, "epoch changed during maintenance")
            history.verify_schema(connection, next_enrollment)
            program(target / "node_lifecycle.py", lifecycle_source)
            program(target / "node_inspector.py", approved_source)
            history.atomic_json(enrollment_path, next_enrollment)
            history.atomic_json(ledger_path, next_ledger)
            require(baseline(enrollment, audit) == facts, "empty lifecycle changed during maintenance")
        after = history.snapshot(database, next_enrollment, next_ledger)
        require(after["hashes"] == audit["hashes"] and next_ledger["owners"] == advanced["owners"],
                "history changed during maintenance")
        require(baseline(next_enrollment, after) == facts, "empty lifecycle changed after maintenance")
        plan["status"] = "complete"
        history.atomic_json(plan_path, plan)
        return plan


def empty_node(enrollment, audit):
    require(inspector.identity() == enrollment["identity"], "node identity changed")
    inspector.baseline()
    sandboxes = inspector.cri()
    require(not any(s.get("metadata", {}).get("namespace") == "smolbox-preview" for s in sandboxes),
            "preview CRI sandbox remains")
    for name, expected in enrollment["runtime"]["sha256"].items():
        require(inspector.sha(inspector.RUNTIME / name) == expected, "runtime asset changed")
    require(inspector.qualified_rootfs(inspector.RUNTIME / "agent-rootfs", audit["attempts"]) ==
            enrollment["runtime"]["agent_rootfs"], "runtime rootfs changed")
    for uid in set(audit_owner for audit_owner in history.decode(inspector.LEDGER.read_bytes())["owners"].values()):
        require(not os.path.lexists(inspector.lifecycle.path(uid)), "historical Pod cgroup remains")
    return {"lifecycle": inspector.lifecycle.current(inspector.run, inspector.sha, inspector.tick),
            "identity": enrollment["identity"], "preview_pods": 0, "preview_cri_sandboxes": 0,
            "runtime_records": 0, "creation_reservations": 0, "boot_processes": 0,
            "vm_directories": [], "shares": [], "runtime_assets_unchanged": True}


def main():
    source = Path(__file__).resolve().parent
    require(os.geteuid() == 0 and platform.node() == "smolbox-k3s" and
            source == Path("/home/lab/smolbox-kubernetes"), "dedicated lab administrator required")
    require(len(sys.argv) == 2, "expected approved new inspector SHA-256")
    inspector.DEADLINE = time.monotonic() + 30
    os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"
    result = upgrade(source, Path("/usr/local/lib/smolbox-kubernetes/node-history"),
                     inspector.STATE, inspector.DATABASE, sys.argv[1], empty_node)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
