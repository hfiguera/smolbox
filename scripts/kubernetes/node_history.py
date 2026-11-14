#!/usr/bin/env python3
"""Fail-closed transaction history for the dedicated SmolVM lab database.

Only administrator enrollment writes runtime schema. Observation opens that
database read-only and writes only its separate, root-owned evidence ledger.
No machine lifecycle operation is exposed here.
"""

import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import sqlite3
import struct
import uuid


PREFIX = "smolbox_kubernetes_"
EVENTS = PREFIX + "events"
EPOCH = PREFIX + "epoch"
MAX_EVENTS = 4096
MAX_RECORD = 131072
MAX_HISTORY = 67108864
EMPTY_HASH = "0" * 64


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def pairs(entries):
    result = {}
    for key, value in entries:
        require(key not in result, "duplicate evidence key")
        result[key] = value
    return result


def decode(raw):
    require(isinstance(raw, (str, bytes)) and len(raw) <= MAX_RECORD, "evidence size")
    value = json.loads(raw, object_pairs_hook=pairs)
    require(isinstance(value, dict), "evidence object")
    return value


def atomic_json(path, value):
    temporary = path.with_suffix(".part")
    data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    with temporary.open("xb") as writer:
        writer.write(data)
        writer.flush()
        os.fsync(writer.fileno())
    temporary.chmod(0o600)
    temporary.replace(path)
    directory = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def schema(epoch):
    require(re.fullmatch(r"[a-f0-9-]{36}", epoch), "observer epoch")
    definitions = {
        EVENTS: f"CREATE TABLE {EVENTS} (seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, name TEXT NOT NULL, old_data BLOB, new_data BLOB)",
        EPOCH: f"CREATE TABLE {EPOCH} (value TEXT PRIMARY KEY NOT NULL)",
    }
    for action, old, new in [("INSERT", "NULL", "NEW.data"),
                             ("UPDATE", "OLD.data", "NEW.data"),
                             ("DELETE", "OLD.data", "NULL")]:
        name = PREFIX + action.lower()
        row = "OLD.name" if action == "DELETE" else "NEW.name"
        # A renamed primary key would otherwise erase the original association.
        reject = "SELECT RAISE(ABORT, 'SmolBox history name mutation') WHERE OLD.name != NEW.name; " if action == "UPDATE" else ""
        definitions[name] = (f"CREATE TRIGGER {name} AFTER {action} ON vms BEGIN " + reject +
                             f"INSERT INTO {EVENTS}(kind,name,old_data,new_data) "
                             f"VALUES ('{action[0]}',{row},{old},{new}); END")
    return definitions


@contextmanager
def connect(database, write=False):
    mode = "rw" if write else "ro"
    connection = sqlite3.connect(f"file:{database}?mode={mode}", uri=True, timeout=2)
    if not write:
        connection.execute("PRAGMA query_only=ON")
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def enroll(database, identity, baseline):
    """One-time administrator operation; never rebaseline existing history."""
    epoch = str(uuid.uuid4())
    with connect(database, write=True) as connection:
        connection.execute("BEGIN IMMEDIATE")
        existing = connection.execute("SELECT name FROM sqlite_master WHERE name LIKE ?", (PREFIX + "%",)).fetchall()
        require(not existing, "history already enrolled; no automatic reset")
        require(connection.execute("SELECT count(*) FROM vms").fetchone() == (0,), "runtime is not empty")
        require(connection.execute("SELECT count(*) FROM vm_create_reservations").fetchone() == (0,),
                "runtime creation in progress")
        baseline()
        for definition in schema(epoch).values():
            connection.execute(definition)
        connection.execute(f"INSERT INTO {EPOCH}(value) VALUES (?)", (epoch,))
    info = database.stat()
    return {"schema": 1, "epoch": epoch, "database_device": info.st_dev,
            "database_inode": info.st_ino, "identity": identity}


def initial_ledger(enrollment):
    return {"schema": 1, "epoch": enrollment["epoch"], "watermark": 0,
            "watermark_hash": EMPTY_HASH, "owners": {}}


def verify_schema(connection, enrollment):
    expected = schema(enrollment["epoch"])
    found = dict(connection.execute("SELECT name,sql FROM sqlite_master WHERE name LIKE ? AND type IN ('table','trigger')", (PREFIX + "%",)))
    require(found == expected, "history schema changed")
    triggers = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='vms'")}
    require(triggers == {PREFIX + x for x in ["insert", "update", "delete"]}, "runtime triggers changed")
    require(connection.execute(f"SELECT value FROM {EPOCH}").fetchall() == [(enrollment["epoch"],)], "history epoch changed")


def event_hash(previous, row):
    digest = hashlib.sha256(bytes.fromhex(previous))
    digest.update(struct.pack(">Q", row[0]))
    for value in row[1:]:
        material = value.encode() if isinstance(value, str) else value
        digest.update(struct.pack(">q", -1 if material is None else len(material)))
        if material is not None:
            digest.update(material)
    return digest.hexdigest()


def record(raw, name):
    require(isinstance(raw, bytes) and len(raw) <= MAX_RECORD, "runtime record size/type")
    value = decode(raw)
    require(value.get("name") == name and value.get("runtime_managed") is True and
            value.get("cpus") == 2 and value.get("mem") == 1024,
            "unqualified runtime machine")
    pid, ticks = value.get("pid"), value.get("pid_start_time")
    require((pid is None and ticks is None) or
            (type(pid) is int and 0 < pid <= 4194304 and type(ticks) is int and ticks > 0),
            "unqualified recorded process")
    return value


def replay(rows):
    attempts, material, hashes, total = {}, {}, [EMPTY_HASH], 0
    for index, row in enumerate(rows, 1):
        seq, kind, name, old, new = row
        require(seq == index and kind in ["I", "U", "D"] and
                isinstance(name, str) and re.fullmatch(r"[a-f0-9]{64}", name), "history sequence/identity gap")
        total += len(old or b"") + len(new or b"")
        require(total <= MAX_HISTORY, "history byte bound")
        require(old == material.get(name), "history preimage changed")
        require((kind == "I" and old is None and new is not None) or
                (kind == "U" and old is not None and new is not None) or
                (kind == "D" and old is not None and new is None), "history transition changed")
        entry = attempts.setdefault(name, {"inserts": 0, "processes": set()})
        entry["inserts"] += int(kind == "I")
        if new is not None:
            value = record(new, name)
            if value.get("pid") is not None:
                entry["processes"].add((value["pid"], value["pid_start_time"]))
            material[name] = new
        else:
            material.pop(name)
        hashes.append(event_hash(hashes[-1], row))
    return {"attempts": attempts, "material": material, "hashes": hashes, "watermark": len(rows)}


def snapshot(database, enrollment, ledger):
    info = database.stat()
    require((info.st_dev, info.st_ino) == (enrollment["database_device"], enrollment["database_inode"]),
            "runtime database replaced")
    require(ledger.get("schema") == 1 and ledger.get("epoch") == enrollment["epoch"], "observer ledger epoch changed")
    with connect(database) as connection:
        connection.execute("BEGIN")
        verify_schema(connection, enrollment)
        count, maximum, size = connection.execute(
            f"SELECT count(*),coalesce(max(max(coalesce(length(old_data),0),coalesce(length(new_data),0))),0),"
            f"coalesce(sum(coalesce(length(old_data),0)+coalesce(length(new_data),0)),0) FROM {EVENTS}").fetchone()
        require(count <= MAX_EVENTS and maximum <= MAX_RECORD and size <= MAX_HISTORY,
                "history allocation bound")
        rows = connection.execute(f"SELECT seq,kind,name,old_data,new_data FROM {EVENTS} ORDER BY seq LIMIT ?", (MAX_EVENTS + 1,)).fetchall()
        require(len(rows) <= MAX_EVENTS, "history event bound")
        history = replay(rows)
        sequence = connection.execute("SELECT seq FROM sqlite_sequence WHERE name=?", (EVENTS,)).fetchall()
        require(sequence == ([(len(rows),)] if rows else []), "history tail lost")
        require(connection.execute("SELECT coalesce(max(length(data)),0) FROM vms").fetchone()[0] <= MAX_RECORD,
                "runtime record allocation bound")
        live = dict(connection.execute("SELECT name,data FROM vms LIMIT ?", (MAX_EVENTS + 1,)))
        require(live == history["material"], "runtime state differs from journal")
        require(connection.execute("SELECT count(*) FROM vm_create_reservations").fetchone() == (0,),
                "runtime creation in progress")
    watermark = ledger.get("watermark")
    require(type(watermark) is int and 0 <= watermark <= history["watermark"] and
            ledger.get("watermark_hash") == history["hashes"][watermark], "history rollback/preimage lost")
    return history


def reconcile(history, ledger, sandboxes, namespace):
    owners = dict(ledger["owners"])
    require(set(owners) <= set(history["attempts"]) and
            all(isinstance(uid, str) and 0 < len(uid) <= 128 for uid in owners.values()), "observer ownership ledger changed")
    require(isinstance(sandboxes, list) and len(sandboxes) <= 1024, "CRI inventory bound")
    seen = set()
    for sandbox in sandboxes:
        sid, metadata = sandbox.get("id"), sandbox.get("metadata", {})
        require(sid not in seen, "duplicate CRI sandbox")
        seen.add(sid)
        if sid not in history["attempts"]:
            continue
        uid = metadata.get("uid")
        require(metadata.get("namespace") == namespace and isinstance(uid, str) and
                re.fullmatch(r"[a-f0-9-]{36}", uid), "runtime sandbox outside enrolled namespace")
        require(sid not in owners or owners[sid] == uid, "sandbox Pod UID changed")
        owners[sid] = uid
    complete = set(owners) == set(history["attempts"])
    next_ledger = {**ledger, "owners": owners, "watermark": history["watermark"],
                   "watermark_hash": history["hashes"][-1]}
    return next_ledger, complete
