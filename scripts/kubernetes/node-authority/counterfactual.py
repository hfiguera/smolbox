#!/usr/bin/env python3
"""Manual scoped proof-predicate replays using a real enrolled idle node.

Observations/witnesses are changed only in process-local copies or a separate
fixture directory. No installed code/configuration, real daemon, node boot,
runtime path, database, history or evidence ledger is changed. These results
must never be described as real boot/daemon failures or used as release proofs.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rejected(function, predicate):
    try:
        function()
    except RuntimeError as error:
        require(
            str(error) == predicate, "unexpected proof rejection; preserve diagnostic"
        )
        return {"rejected": True, "predicate": predicate}
    raise RuntimeError("counterfactual unexpectedly produced evidence")


def run(receipt_path, report_path, helpers):
    _, contract = helpers.core(installed=True)
    import authority_history as history
    from authority_config import Configuration
    from authority_verifier import Verifier

    configuration = Configuration(helpers.CONFIGURATION.read_bytes())
    engine = Verifier(configuration)
    positive = engine.inspect(
        {"version": 1, "action": "check", "binding": configuration.binding}
    )
    require(
        positive["value"]["idle"] is True
        and positive["value"]["complete_history"] is True,
        "finish real work and reach positive idle before counterfactual replay",
    )
    enrollment = engine.read_state(engine.ENROLLMENT)
    ledger = engine.read_state(engine.LEDGER)
    before = {
        str(path): helpers.sha(path)
        for path in (engine.ENROLLMENT, engine.LEDGER, helpers.CONFIGURATION)
    }
    audit = history.snapshot(engine.DATABASE, enrollment, ledger, engine.runner)
    receipt = json.loads(receipt_path.read_bytes())
    contract.receipt(
        receipt,
        {
            "binding_generation": configuration.binding["generation"],
            "authority_generation": enrollment["authority_generation"],
        },
    )
    require(
        receipt["binding"] == configuration.binding,
        "original receipt belongs to another authority",
    )
    request = {
        "version": 1,
        "action": "cleanup",
        "binding": configuration.binding,
        "receipt": receipt,
    }
    controls = {}

    original_identity = engine.identity
    changed = engine.identity()
    changed["node_boot_id"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    engine.identity = lambda: changed
    try:
        controls["changed_node_boot_observation"] = rejected(
            lambda: engine.inspect(
                {"version": 1, "action": "check", "binding": configuration.binding}
            ),
            "enrolled node changed",
        )
    finally:
        engine.identity = original_identity

    changed_enrollment = copy.deepcopy(enrollment)
    changed_enrollment["lifecycle"]["daemons"][0]["start_ticks"] += 1
    controls["changed_saved_daemon_birth"] = rejected(
        lambda: engine.lifecycle.same(
            changed_enrollment, engine.run, engine.sha, engine.tick
        ),
        "kubelet/containerd lifecycle epoch changed",
    )

    changed_ledger = copy.deepcopy(ledger)
    sid = receipt["observation"]["sandbox_ids"][0]
    require(
        changed_ledger["owners"].get(sid) == receipt["pod_uid"],
        "original sandbox mapping unavailable",
    )
    del changed_ledger["owners"][sid]
    controls["missing_original_sandbox_mapping"] = rejected(
        lambda: engine.cleanup(request, enrollment, audit, changed_ledger, True, []),
        "cleanup sandbox history changed",
    )

    original_root = engine.VM_ROOT
    with tempfile.TemporaryDirectory(
        prefix="counterfactual-leak-", dir=helpers.ROOT
    ) as directory:
        fixture = Path(directory)
        name = receipt["observation"]["processes"][0]["vm_directory"]
        (fixture / name).mkdir(mode=0o700)
        engine.VM_ROOT = fixture
        try:
            controls["owned_vm_directory_remains_fixture"] = rejected(
                lambda: engine.cleanup(request, enrollment, audit, ledger, True, []),
                "owned record/directory/share remains",
            )
        finally:
            engine.VM_ROOT = original_root

    after = {
        str(path): helpers.sha(path)
        for path in (engine.ENROLLMENT, engine.LEDGER, helpers.CONFIGURATION)
    }
    require(before == after, "counterfactual changed real authority state")
    result = {
        "version": 1,
        "scope": "counterfactual_inputs_against_real_enrolled_verifier",
        "authority_generation": enrollment["authority_generation"],
        "verifier_manifest_sha256": enrollment["verifier_manifest_sha256"],
        "original_pod_uid": receipt["pod_uid"],
        "controls": controls,
        "installed_configuration_enrollment_and_ledger_unchanged": True,
        "actual_node_boot_daemons_runtime_and_history_unchanged": True,
        "real_physical_failure_claim": False,
        "release_proof_produced": False,
        "original_receipt_sha256": hashlib.sha256(
            contract.canonical(receipt)
        ).hexdigest(),
    }
    helpers.write(report_path, helpers.canonical(result))
    print(json.dumps(result, sort_keys=True))


def main():
    require(
        os.geteuid() == 0 and os.uname().nodename == "smolbox-k3s",
        "dedicated root guest required",
    )
    # The root operator stages both reviewed administrator tools in this private
    # directory; neither tool is an endpoint dependency or request parameter.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import qualification

    qualification.trusted_directory(Path(__file__).resolve().parent)
    require(
        qualification.command(["/usr/bin/systemd-detect-virt"]).strip() == b"kvm",
        "dedicated KVM guest required",
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    arguments = parser.parse_args()
    run(arguments.receipt, arguments.report, qualification)


if __name__ == "__main__":
    main()
