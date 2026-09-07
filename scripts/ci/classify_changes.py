#!/usr/bin/env python3
"""Conservative real-worker selection; unknown scope never grants a live-test skip."""

import argparse
import json
import os
import pathlib
import re
import subprocess


def documentation_only(path):
    parts = pathlib.PurePosixPath(path).parts
    if any(part in ("..", ".") for part in parts) or path.startswith("/"):
        return False
    if path in ("packages/smolbox/README.md", "packages/smolbox/CHANGELOG.md"):
        return True
    if path.startswith("packages/smolbox/docs/") and path.endswith(".md"):
        return True
    return path.startswith("ideas/") and path.endswith((".md", ".txt"))


def needs_runtime(paths, event):
    # A dispatch is also the release/candidate-validation entry point, even
    # when its most recent commit only records documentation or evidence.
    return event == "workflow_dispatch" or not paths or not all(map(documentation_only, paths))


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
    args = parser.parse_args()
    with args.payload.open("rb") as stream:
        payload_bytes = stream.read(1024 * 1024 + 1)
    if len(payload_bytes) > 1024 * 1024:
        raise ValueError("event payload exceeded CI bound")
    payload = json.loads(payload_bytes)
    head, paths = changes(args.event, payload)
    required = needs_runtime(paths, args.event)
    report = {"commit": head, "runtime_required": required, "changed_path_count": len(paths)}
    print(json.dumps(report, sort_keys=True))
    if output_file := os.environ.get("GITHUB_OUTPUT"):
        with open(output_file, "a", encoding="utf-8") as output:
            output.write(f"commit={head}\nruntime_required={str(required).lower()}\n")


if __name__ == "__main__":
    main()
