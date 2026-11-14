"""Version-1 data contract. This module performs no I/O or node observation."""
import hashlib
import json
import re
import uuid

MAGIC = b"SBA1"
MAX_BODY = 65_536
MAX_TIMEOUT_MS = 30_000
MAX_EVENTS = 4096
COMMAND = "smolbox-node-authority-v1"
ACTIONS = {"check", "capture", "cleanup"}
ERRORS = {"invalid_request", "identity_conflict", "unavailable", "expired", "output_limit"}
IDENTITY_KEYS = {"binding_generation", "authority_generation", "verifier_manifest_sha256"}
REQUEST_KEYS = {"version", "action", "nonce", "timeout_ms", "max_response_bytes", "arguments"} | IDENTITY_KEYS
RESPONSE_KEYS = {"version", "action", "nonce", "ok", "journal", "value", "error"} | IDENTITY_KEYS
GENERATION_KEYS = {"version", "binding_generation", "history_epoch", "enrollment_nonce",
                   "verifier_manifest_sha256", "configuration_sha256"}
BINDING_KEYS = {"version", "kind", "target_id", "cluster_id", "cluster_anchor_uid", "namespace",
                "namespace_uid", "node_name", "node_uid", "node_boot_id", "runtime_class",
                "runtime_class_uid", "runtime_policy_digest", "runtime_identity", "generation"}
RUNTIME_VERSIONS = {"smolvm_version": "1.34.0", "k3s_version": "v1.35.10+k3s1",
                    "containerd_version": "2.2.10-k3s1"}
RUNTIME_DIGESTS = {"archive_sha256", "shim_sha256", "libkrun_sha256", "kernel_sha256",
                   "rootfs_sha256", "guard_sha256", "guard_template_sha256"}
OBSERVATION_KEYS = {"version", "binding_generation", "pod_uid", "sandbox_ids", "processes",
                    "interfaces", "observer_epoch", "observed_at_ms", "guard_sha256",
                    "guard_template_sha256", "complete_history", "isolated"}
PROCESS_KEYS = {"sandbox_id", "vm_directory", "pid", "start_ticks", "exe_sha256", "kvm"}
INTERFACE_KEYS = {"sandbox_id", "name", "ifindex"}
RECEIPT_KEYS = {"version", "phase", "binding", "pod_name", "pod_uid", "nonce", "intent_digest",
                "image_reference", "container_id", "image_id", "observation"}
PROOF_KEYS = {"version", "observed_at_ms", "observer_epoch", "api_absent", "terminated_processes",
              "absent_records", "absent_vm_directories", "absent_shares", "complete_history"}
KVM = ["anon_inode:kvm-vcpu:0", "anon_inode:kvm-vcpu:1", "anon_inode:kvm-vm"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact(value, keys):
    return isinstance(value, dict) and set(value) == set(keys)


def text(value, maximum=4096):
    return isinstance(value, str) and 0 < len(value) <= maximum and all(32 <= ord(c) <= 126 for c in value)


def digest(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def history_epoch(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        return False


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate key")
        result[key] = value
    return result


def data(value, depth=0):
    require(depth <= 24, "data nesting bound")
    if value is None or type(value) is bool:
        return
    if type(value) is int:
        require(-(2**63) <= value < 2**63, "integer bound")
    elif isinstance(value, str):
        require(len(value) <= MAX_BODY and all(32 <= ord(c) <= 126 for c in value), "string encoding")
    elif isinstance(value, list):
        require(len(value) <= 4096, "list bound")
        for item in value:
            data(item, depth + 1)
    elif isinstance(value, dict):
        require(len(value) <= 4096, "object bound")
        for key, item in value.items():
            require(text(key, 128), "object key")
            data(item, depth + 1)
    else:
        raise ValueError("unsupported data type")


def canonical(value):
    data(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode("ascii")


def sha256(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def decode(raw):
    require(isinstance(raw, bytes) and 0 < len(raw) <= MAX_BODY, "body bound")
    # Bound nesting before json's recursive parser. Quoted braces do not count.
    depth, quoted, escaped = 0, False, False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= 24, "JSON nesting bound")
        elif byte in (93, 125):
            depth -= 1
            require(depth >= 0, "JSON nesting")
    value = json.loads(raw, object_pairs_hook=pairs)
    data(value)
    require(isinstance(value, dict), "body object")
    return value


def generation(fields):
    require(exact(fields, GENERATION_KEYS) and type(fields["version"]) is int and fields["version"] == 1,
            "generation schema")
    require(history_epoch(fields["history_epoch"]), "history epoch")
    require(all(digest(fields[key]) for key in GENERATION_KEYS - {"version", "history_epoch"}),
            "generation digest")
    return sha256(fields)


def binding(value):
    require(exact(value, BINDING_KEYS) and type(value["version"]) is int and value["version"] == 1 and
            value["kind"] == "kubernetes", "binding schema")
    for key in BINDING_KEYS - {"version", "runtime_identity", "runtime_policy_digest", "generation"}:
        require(text(value[key], 253), "binding text")
    require(history_epoch(value["node_boot_id"]) and digest(value["generation"]) and
            digest(value["runtime_policy_digest"]), "binding identity")
    runtime = value["runtime_identity"]
    require(exact(runtime, set(RUNTIME_VERSIONS) | RUNTIME_DIGESTS) and
            all(runtime[key] == expected for key, expected in RUNTIME_VERSIONS.items()) and
            all(digest(runtime[key]) for key in RUNTIME_DIGESTS), "runtime identity")
    return value


def observation(value):
    require(exact(value, OBSERVATION_KEYS) and type(value["version"]) is int and value["version"] == 1,
            "observation schema")
    require(all(digest(value[key]) for key in ("binding_generation", "observer_epoch", "guard_sha256",
                                              "guard_template_sha256")) and
            history_epoch(value["pod_uid"]) and integer(value["observed_at_ms"], 0, 2**63 - 1) and
            value["complete_history"] is True and type(value["isolated"]) is bool, "observation identity")
    ids, processes, interfaces = value["sandbox_ids"], value["processes"], value["interfaces"]
    require(isinstance(ids, list) and 1 <= len(ids) <= 16 and all(digest(sid) for sid in ids) and
            ids == sorted(set(ids)) and isinstance(processes, list) and isinstance(interfaces, list) and
            len(processes) == len(interfaces) == len(ids), "observation inventories")
    for process in processes:
        require(exact(process, PROCESS_KEYS) and process["sandbox_id"] in ids and
                process["vm_directory"] == hashlib.sha256(process["sandbox_id"].encode()).hexdigest()[:16] and
                integer(process["pid"], 1, 4194304) and integer(process["start_ticks"], 1, 2**63 - 1) and
                digest(process["exe_sha256"]) and process["kvm"] == KVM, "process identity")
    for interface in interfaces:
        require(exact(interface, INTERFACE_KEYS) and interface["sandbox_id"] in ids and
                isinstance(interface["name"], str) and
                re.fullmatch(r"veth[0-9a-f]{1,11}", interface["name"]) and
                integer(interface["ifindex"], 1, 2147483647), "interface identity")
    for items, keys in ((processes, ("sandbox_id", "pid")), (interfaces, ("sandbox_id", "name", "ifindex"))):
        require(all(len({item[key] for item in items}) == len(ids) for key in keys), "inventory alias")
    return value


def receipt(value, original):
    require(exact(value, RECEIPT_KEYS) and type(value["version"]) is int and value["version"] == 1 and
            value["phase"] == "ready", "receipt schema")
    enrolled = binding(value["binding"])
    capture = observation(value["observation"])
    require(text(value["pod_name"], 63) and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value["pod_name"]) and
            history_epoch(value["pod_uid"]) and digest(value["nonce"]) and digest(value["intent_digest"]) and
            text(value["image_reference"], 1024) and
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}", value["image_reference"]) and
            value["image_id"] == value["image_reference"] and isinstance(value["container_id"], str) and
            re.fullmatch(r"containerd://[0-9a-f]{64}", value["container_id"]), "receipt identity")
    require(capture["binding_generation"] == enrolled["generation"] == original["binding_generation"] and
            capture["observer_epoch"] == original["authority_generation"] and
            capture["pod_uid"] == value["pod_uid"] and
            capture["guard_sha256"] == enrolled["runtime_identity"]["guard_sha256"] and
            capture["guard_template_sha256"] == enrolled["runtime_identity"]["guard_template_sha256"] and
            all(p["exe_sha256"] == enrolled["runtime_identity"]["shim_sha256"] for p in capture["processes"]),
            "receipt authority")
    return value


def request(value):
    require(exact(value, REQUEST_KEYS) and type(value["version"]) is int and value["version"] == 1,
            "request schema")
    require(isinstance(value["action"], str) and value["action"] in ACTIONS and digest(value["nonce"]) and
            all(digest(value[key]) for key in IDENTITY_KEYS), "request identity")
    require(integer(value["timeout_ms"], 1, MAX_TIMEOUT_MS) and
            integer(value["max_response_bytes"], 9, MAX_BODY + 8), "request budget")
    args = value["arguments"]
    if value["action"] == "check":
        require(exact(args, set()), "check arguments")
    elif value["action"] == "capture":
        require(exact(args, {"pod_uid"}) and history_epoch(args["pod_uid"]), "capture arguments")
    else:
        require(exact(args, {"receipt", "receipt_sha256"}) and isinstance(args["receipt"], dict) and
                digest(args["receipt_sha256"]) and sha256(args["receipt"]) == args["receipt_sha256"],
                "cleanup arguments")
        receipt(args["receipt"], value)
    require(len(canonical(value)) <= MAX_BODY, "request size")
    return value


def response(value, original):
    request(original)
    require(exact(value, RESPONSE_KEYS) and type(value["version"]) is int and value["version"] == 1,
            "response schema")
    require(all(value[key] == original[key] for key in IDENTITY_KEYS | {"nonce", "action"}),
            "response identity")
    require(type(value["ok"]) is bool, "response outcome")
    if value["ok"]:
        journal = value["journal"]
        require(value["error"] is None and isinstance(value["value"], dict) and
                exact(journal, {"history_epoch", "watermark", "prefix_sha256"}) and
                history_epoch(journal["history_epoch"]) and
                integer(journal["watermark"], 0, MAX_EVENTS) and digest(journal["prefix_sha256"]),
                "response evidence")
        evidence = value["value"]
        if original["action"] == "check":
            require(exact(evidence, {"complete_history", "idle", "observer_epoch"}) and
                    type(evidence["complete_history"]) is bool and type(evidence["idle"]) is bool and
                    evidence["observer_epoch"] == original["authority_generation"], "check evidence")
        elif original["action"] == "capture":
            observation(evidence)
            require(evidence["observer_epoch"] == original["authority_generation"] and
                    evidence["binding_generation"] == original["binding_generation"] and
                    evidence["pod_uid"] == original["arguments"]["pod_uid"], "capture evidence")
        else:
            capture = original["arguments"]["receipt"]["observation"]
            require(exact(evidence, PROOF_KEYS) and type(evidence["version"]) is int and evidence["version"] == 3 and
                    evidence["api_absent"] is True and evidence["complete_history"] is True and
                    evidence["observer_epoch"] == capture["observer_epoch"] and
                    integer(evidence["observed_at_ms"], capture["observed_at_ms"], 2**63 - 1) and
                    evidence["terminated_processes"] == capture["processes"] and
                    evidence["absent_records"] == evidence["absent_shares"] == capture["sandbox_ids"] and
                    evidence["absent_vm_directories"] == sorted(p["vm_directory"] for p in capture["processes"]),
                    "cleanup evidence")
    else:
        require(value["journal"] is None and value["value"] is None and
                isinstance(value["error"], str) and value["error"] in ERRORS,
                "response rejection")
    require(len(canonical(value)) + 8 <= original["max_response_bytes"], "response budget")
    return value
