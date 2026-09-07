#!/usr/bin/env python3
"""Required-status gate: missing, cancelled and unexpected skipped jobs fail."""

import json
import os
import sys

SCOPE = "smolbox-change-scope"
LIVE = {"smolbox-linux-runtime", "smolbox-macos-runtime"}
ORDINARY = {
    "smolbox-format-compile", "smolbox-credo-ex-slop", "smolbox-ex-dna",
    "smolbox-credence", "smolbox-dialyzer", "smolbox-tests", "smolbox-coverage",
    "smolbox-quality-canaries", "smolbox-security", "smolbox-docs-package",
    "smolbox-compatibility", "smolbox-minimum-dependencies", "smolbox-minimal-host",
    "smolbox-store-contract",
}


def failures(results):
    expected = ORDINARY | LIVE | {SCOPE}
    if set(results) != expected:
        return {"job_set": "missing or unexpected required dependency"}
    scope = results[SCOPE]
    runtime = scope.get("outputs", {}).get("runtime_required")
    if scope.get("result") != "success" or runtime not in ("true", "false"):
        return {SCOPE: "classification failed or supplied no valid selection"}
    failed = {}
    for job, value in results.items():
        status = value.get("result")
        allowed_skip = job in LIVE and runtime == "false" and status == "skipped"
        if status != "success" and not allowed_skip:
            failed[job] = status or "missing result"
    return failed


if __name__ == "__main__":
    failed = failures(json.loads(os.environ["NEEDS_JSON"]))
    print(json.dumps({"failed_dependencies": failed}, sort_keys=True))
    if any(job in LIVE for job in failed):
        print("Trusted real-worker validation of this exact candidate is required; a skip is not evidence.")
    sys.exit(1 if failed else 0)
