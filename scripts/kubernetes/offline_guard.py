#!/usr/bin/env python3
"""Administrator-only L2 isolation for the single-node preview namespace.

This is lab infrastructure, not an application NodeEvidence provider. It owns
one nftables bridge table and never changes K3s or another namespace's rules.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time


STATE = Path("/var/lib/smolbox-kubernetes")
TABLE = "smolbox_preview_guard"
MARKER = "SmolBox preview offline guard v1"
NAMESPACE = "smolbox-preview"
MANAGER = "smolbox-kubernetes-preview"
TEMPLATE = f'''table bridge {TABLE} {{
 comment "{MARKER}"
 set isolated_ports {{ type ifname; }}
 chain from_pod {{ type filter hook prerouting priority -300; policy accept;
  iifname @isolated_ports counter drop
 }}
 chain to_pod {{ type filter hook postrouting priority -300; policy accept;
  oifname @isolated_ports counter drop
 }}
}}
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(args, data=None, check=True):
    result = subprocess.run(args, input=data, capture_output=True, timeout=20)
    require(len(result.stdout) <= 2097152 and len(result.stderr) <= 8192, "guard response too large")
    if check:
        require(result.returncode == 0, f"guard command failed: {args[0]}")
    return result


def kubectl(*args):
    return json.loads(command(["/usr/local/bin/kubectl", "--request-timeout=15s", *args, "-o", "json"]).stdout)


def atomic_json(path, value):
    temporary = path.with_suffix(".part")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def rules(document):
    objects = document["nftables"]
    table = [x["table"] for x in objects if "table" in x]
    require(len(table) == 1 and table[0].get("comment") == MARKER and
            table[0]["name"] == TABLE and table[0]["family"] == "bridge", "unowned nft table")
    sets = [x["set"] for x in objects if "set" in x]
    require(len(sets) == 1 and sets[0]["name"] == "isolated_ports" and sets[0]["type"] == "ifname", "unexpected guard set")
    ports = sets[0].get("elem", [])
    require(all(isinstance(p, str) and re.fullmatch(r"veth[a-f0-9]{1,11}", p) for p in ports), "unexpected guard port")
    chains = [x["chain"] for x in objects if "chain" in x]
    require(len(chains) == 2, "unexpected guard chains")
    for name, hook, key in [("from_pod", "prerouting", "iifname"), ("to_pod", "postrouting", "oifname")]:
        chain = [c for c in chains if c["name"] == name]
        require(len(chain) == 1 and chain[0].get("hook") == hook and chain[0].get("prio") == -300 and
                chain[0].get("type") == "filter" and chain[0].get("policy") == "accept", "guard hook changed")
        found = [x["rule"] for x in objects if "rule" in x and x["rule"]["chain"] == name]
        require(len(found) == 1, "unexpected guard rules")
        expressions = found[0]["expr"]
        require(len(expressions) == 3 and expressions[0] == {"match": {"op": "==", "left": {"meta": {"key": key}}, "right": "@isolated_ports"}}
                and set(expressions[1]) == {"counter"} and expressions[2] == {"drop": None}, "guard rule changed")
    require(len([x for x in objects if "rule" in x]) == 2, "additional guard rules")
    return sorted(ports)


def table_document():
    result = command(["/usr/sbin/nft", "-j", "list", "table", "bridge", TABLE], check=False)
    require(result.returncode == 0, "guard table unavailable")
    document = json.loads(result.stdout)
    rules(document)
    return document


def mapped_ports(pods, sandboxes, links):
    by_index = {link["ifindex"]: link for link in links}
    mappings = []
    for pod in pods:
        uid = pod["metadata"]["uid"]
        require(pod["metadata"]["namespace"] == NAMESPACE, "guard namespace differs")
        if not pod.get("status", {}).get("podIP"):
            continue
        matches = [s for s in sandboxes if s.get("metadata", {}).get("uid") == uid]
        require(matches, "Pod CRI mapping unavailable")
        for sandbox in matches:
            sandbox_id = sandbox["id"]
            require(re.fullmatch(r"[a-f0-9]{64}", sandbox_id), "invalid sandbox ID")
            inspection = json.loads(command(["/usr/local/bin/k3s", "crictl", "inspectp", sandbox_id]).stdout)
            spaces = inspection["info"]["runtimeSpec"]["linux"]["namespaces"]
            paths = [Path(n["path"]) for n in spaces if n["type"] == "network"]
            require(len(paths) == 1 and paths[0].parent.resolve() == Path("/run/netns") and
                    re.fullmatch(r"cni-[a-f0-9-]{36}", paths[0].name), "unexpected network namespace")
            interface = json.loads(command(["/usr/bin/nsenter", f"--net={paths[0]}", "/usr/sbin/ip", "-j", "link", "show", "eth0"]).stdout)
            require(len(interface) == 1, "expected one Pod eth0")
            peer = by_index.get(interface[0].get("link_index"))
            require(peer is not None and re.fullmatch(r"veth[a-f0-9]{1,11}", peer["ifname"]), "invalid Pod bridge port")
            bridge = next((l for l in links if l["ifname"] == "cni0"), None)
            require(bridge is not None and peer.get("master") in (bridge["ifindex"], "cni0"), "Pod is not on cni0")
            mappings.append({"pod_uid": uid, "sandbox_id": sandbox_id, "interface": peer["ifname"], "ifindex": peer["ifindex"]})
    return mappings


def reconcile(permit=None):
    STATE.mkdir(exist_ok=True)
    with (STATE / "offline-guard.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        namespace = kubectl("get", "namespace", NAMESPACE)
        require(namespace["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") == MANAGER, "guard namespace unowned")
        node = kubectl("get", "node", "smolbox-k3s")
        binding = {"namespace_uid": namespace["metadata"]["uid"], "node_uid": node["metadata"]["uid"]}
        binding_file = STATE / "offline-guard-binding.json"
        if binding_file.exists():
            require(json.loads(binding_file.read_text()) == binding, "guard domain changed")
        else:
            atomic_json(binding_file, binding)
        permits_file = STATE / "offline-guard-permits.json"
        permits = json.loads(permits_file.read_text()) if permits_file.exists() else {}
        permits = {uid: until for uid, until in permits.items() if until > time.time()}
        if permit:
            uid, enabled = permit
            require(re.fullmatch(r"[a-f0-9-]{36}", uid), "invalid qualification UID")
            if enabled:
                permits[uid] = time.time() + 120
            else:
                permits.pop(uid, None)
        atomic_json(permits_file, permits)
        pods = kubectl("get", "pods", "-n", NAMESPACE)["items"]
        sandboxes = json.loads(command(["/usr/local/bin/k3s", "crictl", "pods", "-o", "json"]).stdout).get("items", [])
        links = json.loads(command(["/usr/sbin/ip", "-j", "link", "show"]).stdout)
        mappings = mapped_ports(pods, sandboxes, links)
        for uid in permits:
            owned = [p for p in pods if p["metadata"]["uid"] == uid]
            require(len(owned) == 1 and "smolbox.dev/qualification" in owned[0]["metadata"].get("labels", {}),
                    "only administrator qualification Pods can be permitted")
        ports = sorted({m["interface"] for m in mappings if m["pod_uid"] not in permits})
        table_document()  # Refuse foreign or edited rules before any mutation.
        batch = f"flush set bridge {TABLE} isolated_ports\n"
        if ports:
            batch += f"add element bridge {TABLE} isolated_ports {{ " + ", ".join(json.dumps(p) for p in ports) + " }\n"
        command(["/usr/sbin/nft", "-f", "-"], batch.encode())
        document = table_document()
        require(rules(document) == ports, "guard ports differ after update")
        state = {"schema": 1, **binding, "node_boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                 "at_unix_ms": round(time.time() * 1000), "mappings": mappings, "isolated_ports": ports,
                 "qualification_permits": sorted(permits), "table": document,
                 "program_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                 "template_sha256": hashlib.sha256(TEMPLATE.encode()).hexdigest()}
        atomic_json(STATE / "offline-guard.json", state)
        return state


def install_table():
    # A failed list is not treated as absence; inventory the table names first.
    tables = json.loads(command(["/usr/sbin/nft", "-j", "list", "tables"]).stdout)["nftables"]
    existing = any(x.get("table", {}).get("family") == "bridge" and x["table"]["name"] == TABLE for x in tables)
    if not existing:
        command(["/usr/sbin/nft", "-f", "-"], TEMPLATE.encode())
    table_document()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "once", "serve", "permit", "unpermit"])
    parser.add_argument("uid", nargs="?")
    args = parser.parse_args()
    require(os.geteuid() == 0 and platform.node() == "smolbox-k3s", "dedicated root lab guest required")
    os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"
    if args.action == "install":
        install_table()
    if args.action == "serve":
        while True:
            try:
                reconcile()
            except Exception:
                # Keep the previous drop set on observation failure. A stale
                # state cannot qualify application dispatch, even if rules persist.
                print("offline guard reconciliation unavailable", file=sys.stderr, flush=True)
            time.sleep(1)
    else:
        permit = (args.uid, args.action == "permit") if args.action in ("permit", "unpermit") else None
        result = reconcile(permit)
        print(json.dumps({"isolated_ports": result["isolated_ports"], "qualification_permits": result["qualification_permits"]}))


if __name__ == "__main__":
    main()
