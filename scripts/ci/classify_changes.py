#!/usr/bin/env python3
"""Identify the CI candidate and select explicitly requested runtime qualification."""

import argparse
import json
import os
import pathlib
import re
import subprocess


def needs_runtime(event, requested):
    if event not in ("push", "pull_request", "workflow_dispatch"):
        raise ValueError("unsupported CI event")
    if requested not in ("true", "false"):
        raise ValueError("runtime qualification selection must be true or false")
    if requested == "true" and event != "workflow_dispatch":
        raise ValueError("runtime qualification requires a manual dispatch")
    return requested == "true"


def revision(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value):
        raise ValueError("event has no valid Git revision")
    return value


def changes(event, payload):
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    git = ["git", "-C", root]
    head = subprocess.check_output(git + ["rev-parse", "HEAD"], text=True).strip()
    revision(head)
    if event == "workflow_dispatch":
        return head, []
    if event == "pull_request":
        base = revision(payload["pull_request"]["base"]["sha"])
    elif event == "push":
        base = revision(payload["before"])
    else:
        raise ValueError("unsupported CI event")
    if set(base) == {"0"}:
        # First push: inspect every tracked file rather than invent a parent.
        command = git + ["ls-files", "-z"]
    else:
        command = git + ["diff", "--no-renames", "--name-only", "-z", base, head, "--"]
    output = subprocess.check_output(command)
    if len(output) > 4 * 1024 * 1024:
        raise ValueError("changed-path list exceeded CI bound")
    paths = [path.decode("utf-8", errors="strict") for path in output.split(b"\0") if path]
    return head, paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", choices=["push", "pull_request", "workflow_dispatch"], required=True)
    parser.add_argument("--payload", type=pathlib.Path, required=True)
    parser.add_argument("--qualify-runtime", choices=["true", "false"], required=True)
    args = parser.parse_args()
    with args.payload.open("rb") as stream:
        payload_bytes = stream.read(1024 * 1024 + 1)
    if len(payload_bytes) > 1024 * 1024:
        raise ValueError("event payload exceeded CI bound")
    payload = json.loads(payload_bytes)
    head, paths = changes(args.event, payload)
    required = needs_runtime(args.event, args.qualify_runtime)
    report = {"commit": head, "runtime_required": required, "changed_path_count": len(paths)}
    print(json.dumps(report, sort_keys=True))
    if output_file := os.environ.get("GITHUB_OUTPUT"):
        with open(output_file, "a", encoding="utf-8") as output:
            output.write(f"commit={head}\nruntime_required={str(required).lower()}\n")


if __name__ == "__main__":
    main()
