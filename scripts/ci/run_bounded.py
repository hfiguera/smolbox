#!/usr/bin/env python3
"""Run one owned CI child with finite output/time and emit a payload-free report."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import selectors
import signal
import subprocess
import time


def stop_owned(process):
    # start_new_session below gives this invocation its own process group.
    # Never signal a worker daemon or another job by name/port.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # An exited leader can leave descendants holding its output pipe open.
    # Reap that owned group too; a leader exit alone is not group completion.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def execute(arguments, timeout, output_limit):
    started = time.monotonic()
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, start_new_session=True)
    data = bytearray()
    failure = None
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    failure = "deadline"
                    break
                for key, _event in selector.select(min(remaining, 0.25)):
                    chunk = os.read(key.fileobj.fileno(), min(65536, output_limit + 1 - len(data)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    data.extend(chunk)
                    if len(data) > output_limit:
                        failure = "output_limit"
                        break
                if failure:
                    break
            if failure is None:
                try:
                    process.wait(timeout=max(0.01, timeout - (time.monotonic() - started)))
                except subprocess.TimeoutExpired:
                    failure = "deadline"
    finally:
        stop_owned(process)
        process.stdout.close()
    return bytes(data), {
        "exit_code": process.returncode, "failure": failure,
        "seconds": round(time.monotonic() - started, 3),
        "captured_bytes": len(data), "output_sha256": hashlib.sha256(data).hexdigest(),
    }


def exunit_summary(data, expected):
    if type(expected) is not int or expected < 1:
        raise ValueError("a positive required suite size is necessary")
    text = data.decode("utf-8", errors="replace")
    # Canonical CI is Elixir 1.20.4. Reject a zero-test success, exclusions, a
    # fractional pass count, skipped tests or an unexpected suite size.
    matches = re.findall(r"^Result: (\d+) passed\s*$", text, re.MULTILINE)
    seeds = re.findall(r"^Running ExUnit with seed: (\d+),", text, re.MULTILINE)
    if matches != [str(expected)] or len(seeds) != 1 or re.search(r"\b(?:skipped|excluded)\b", text):
        raise ValueError("required ExUnit cases did not all execute and pass")
    return {"passed": expected, "seed": int(seeds[0])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--output-limit", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--expected-tests", type=int)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 1800 or not 1024 <= args.output_limit <= 8 * 1024 * 1024:
        raise ValueError("invalid runner bounds")
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if not arguments or args.report.exists():
        raise ValueError("command required and report must be new")
    with args.report.open("x", encoding="utf-8") as report_file:
        data, report = execute(arguments, args.timeout, args.output_limit)
        if args.expected_tests is not None and report["exit_code"] == 0 and report["failure"] is None:
            try:
                report["tests"] = exunit_summary(data, args.expected_tests)
            except ValueError:
                report["failure"] = "test_evidence"
        report["status"] = "passed" if report["exit_code"] == 0 and report["failure"] is None else "failed"
        report_file.write(json.dumps(report, indent=2) + "\n")
    # No child output or command arguments enter CI artifacts. Test failures can
    # contain complete input specifications; only counts/status/digests leave.
    print(json.dumps(report, sort_keys=True))
    if report["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
