#!/usr/bin/env python3
"""Manual serial public SDK campaign against the already enrolled dedicated guest.

Starts only owned loopback proxies and controller processes. Never provisions,
resets, repairs or stops node infrastructure. Stops at the first failed case;
existing reports, store data, keys and authority remain untouched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

REPOSITORY = Path(__file__).resolve().parents[3]
CASES = (
    ("memory-binary", "memory", "binary", "observe", "kubernetes-preview", 1),
    ("postgres-binary", "postgresql", "binary", "observe", "kubernetes-preview", 1),
    (
        "memory-silent-cap1",
        "memory",
        "silent",
        "observe",
        "kubernetes-preview-cap-1",
        1,
    ),
    (
        "memory-silent-cap4096",
        "memory",
        "silent",
        "observe",
        "kubernetes-preview-cap-4096",
        1,
    ),
    (
        "postgres-silent-cap4096",
        "postgresql",
        "silent",
        "observe",
        "kubernetes-preview-cap-4096",
        1,
    ),
    ("memory-cancel", "memory", "cancel", "observe", "kubernetes-preview-cap-4096", 1),
    (
        "postgres-cancel",
        "postgresql",
        "cancel",
        "observe",
        "kubernetes-preview-cap-4096",
        1,
    ),
    (
        "memory-overflow",
        "memory",
        "overflow",
        "observe",
        "kubernetes-preview-cap-4096",
        1,
    ),
    (
        "memory-lost-create",
        "memory",
        "reject",
        "lost-create",
        "kubernetes-preview-cap-4096",
        0,
    ),
    (
        "postgres-lost-create",
        "postgresql",
        "reject",
        "lost-create",
        "kubernetes-preview-cap-4096",
        0,
    ),
    (
        "memory-lost-status",
        "memory",
        "lost",
        "lost-status",
        "kubernetes-preview-cap-4096",
        1,
    ),
    (
        "postgres-lost-status",
        "postgresql",
        "lost",
        "lost-status",
        "kubernetes-preview-cap-4096",
        1,
    ),
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def document(path, value, exclusive=False):
    with path.open("x" if exclusive else "w") as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write("\n")
    path.chmod(0o600)


def validate(trace, report, expected_exec):
    rows = [json.loads(line) for line in trace.read_text().splitlines()]
    require(
        sum(row.get("create", False) for row in rows) == 1,
        "expected exactly one Pod create",
    )
    require(
        sum(row.get("exec_operation") == "exec" for row in rows) == expected_exec,
        "application request count differs",
    )
    require(
        not any(row.get("exec_operation_unavailable", False) for row in rows),
        "unclassified exec request",
    )
    created = [row["created_pod_uid"] for row in rows if "created_pod_uid" in row]
    deleted = [
        row["delete_precondition_uid"]
        for row in rows
        if "delete_precondition_uid" in row
    ]
    require(
        created == [report["pod_uid"]] and deleted == created,
        "original UID create/delete differs",
    )
    require(
        report["cleanup"] == "complete"
        and report["cleanup_proof_version"] == 3
        and all(value == 0 for value in report["usage"].values()),
        "positive v3 cleanup/zero usage required",
    )
    return {
        "creates": 1,
        "application_exec_requests": expected_exec,
        "original_uid_delete": True,
    }


def run_case(directory, case):
    name, store, mode, fault, profile, expected_exec = case
    identifier = "authority-" + name
    trace = directory / (name + "-trace.jsonl")
    output = directory / (name + ".log")
    proxy_output = directory / (name + "-proxy.log")
    report_path = directory / "reports" / (identifier + ".json")
    require(
        not any(path.exists() for path in (trace, output, proxy_output, report_path)),
        "case output already exists; no replay or overwrite",
    )
    environment = dict(os.environ)
    environment.pop("DATABASE_URL", None)
    environment.update(
        {
            "MIX_ENV": "dev",
            "SMOLBOX_NODE_AUTHORITY_QUALIFICATION": str(directory),
            "SMOLBOX_KUBERNETES_ENROLLMENT": str(directory / "settings.json"),
            "SMOLBOX_AUTHORITY_STORE": store,
            "SMOLBOX_AUTHORITY_PROFILE": profile,
            "SMOLBOX_DATABASE_SOCKET_DIR": str(
                REPOSITORY / ".local/kubernetes-phase2-db/socket"
            ),
            "SMOLBOX_DATABASE_PORT": "27613",
            "SMOLBOX_DATABASE_USER": "smolbox",
            "SMOLBOX_DATABASE_NAME": "smolbox_contract",
        }
    )
    for key in ("SMOLBOX_AUTHORITY_BAD_APPROVAL", "SMOLBOX_AUTHORITY_FAULT_SSH"):
        environment.pop(key, None)
    environment.pop("SMOLBOX_KUBERNETES_DISPATCH_TRACE", None)
    if mode == "cancel":
        environment["SMOLBOX_KUBERNETES_DISPATCH_TRACE"] = str(trace)
    helper = hashlib.sha256(
        (REPOSITORY / "priv/kubernetes/guest_helper_v1.py").read_bytes()
    ).hexdigest()
    with proxy_output.open("x") as proxy_log, output.open("x") as controller_log:
        proxy = subprocess.Popen(
            [
                "python3",
                "-B",
                str(REPOSITORY / "scripts/kubernetes/fault_proxy.py"),
                "--mode",
                fault,
                "--helper-sha256",
                helper,
                "--certificate",
                str(directory / "proxy-leaf.crt"),
                "--key",
                str(directory / "proxy-leaf-key.pem"),
                "--upstream-ca",
                str(directory / "node-ca.crt"),
                "--trace",
                str(trace),
                "--port",
                "18444",
                "--upstream-port",
                "17444",
            ],
            stdin=subprocess.DEVNULL,
            stdout=proxy_log,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 5
            while "Loopback TLS fault proxy ready" not in proxy_output.read_text():
                require(
                    proxy.poll() is None and time.monotonic() < deadline,
                    "owned proxy did not start",
                )
                time.sleep(0.05)
            cwd = (
                REPOSITORY
                if store == "memory"
                else REPOSITORY / "examples/durable_host"
            )
            controller = subprocess.Popen(
                [
                    "mix",
                    "run",
                    str(REPOSITORY / "scripts/kubernetes/backend-smoke.exs"),
                    str(
                        REPOSITORY
                        / "scripts/kubernetes/node-authority/campaign_settings.exs"
                    ),
                    mode,
                    identifier,
                ],
                cwd=cwd,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=controller_log,
                stderr=subprocess.STDOUT,
            )
            document(
                directory / "campaign-active.json",
                {
                    "case": name,
                    "controller_pid": controller.pid,
                    "proxy_pid": proxy.pid,
                    "started_at_unix_ms": round(time.time() * 1000),
                },
            )
            code = controller.wait()
            require(
                code == 0,
                "public case failed; preserve its trace, records and controller log",
            )
            report = json.loads(report_path.read_text())
            counts = validate(trace, report, expected_exec)
            return {
                "case": name,
                "store": store,
                "mode": mode,
                "passed": True,
                "counts": counts,
                "report": report,
                "trace_sha256": hashlib.sha256(trace.read_bytes()).hexdigest(),
                "controller_log_sha256": hashlib.sha256(
                    output.read_bytes()
                ).hexdigest(),
            }
        finally:
            if proxy.poll() is None:
                proxy.terminate()
            proxy.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument(
        "--report",
        type=Path,
        help="new report for an explicitly selected unattempted case set",
    )
    parser.add_argument("--cases", nargs="+", choices=[case[0] for case in CASES])
    options = parser.parse_args()
    directory = options.directory.resolve()
    require(
        (directory / "approval.json").is_file()
        and (directory / "settings.json").is_file(),
        "approved enrolled campaign inputs required",
    )
    result_path = options.report or directory / "public-campaign.json"
    require(
        not result_path.exists(),
        "campaign report exists; no automatic continuation/replay",
    )
    chosen = [case for case in CASES if not options.cases or case[0] in options.cases]
    results = []
    for case in chosen:
        result = run_case(directory, case)
        results.append(result)
        document(
            result_path,
            {
                "version": 1,
                "scope": "real_enrolled_public_runtime",
                "completed": results,
                "all_requested_cases_complete": len(results) == len(chosen),
            },
        )
        print("Public campaign passed: " + case[0], flush=True)


if __name__ == "__main__":
    main()
