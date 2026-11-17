"""Read-only bridge rule and CRI/netns mapping predicates; no guard mutation."""

from pathlib import Path
import json
import re
import subprocess
from authority_history import require, pairs


class Guard:
    def __init__(self, config, runner):
        self.paths = config.paths
        self.TABLE = config.guard["table_name"]
        self.MARKER = config.guard["marker"]
        self.TEMPLATE = f'table bridge {self.TABLE} {{\n comment "{self.MARKER}"\n set isolated_ports {{ type ifname; }}\n chain from_pod {{ type filter hook prerouting priority -300; policy accept;\n  iifname @isolated_ports counter drop\n }}\n chain to_pod {{ type filter hook postrouting priority -300; policy accept;\n  oifname @isolated_ports counter drop\n }}\n}}\n'
        self.NAMESPACE = config.binding["namespace"]
        self.bridge = config.guard["bridge"]
        self.runner = runner

    def command(self, arguments):
        if len(arguments) >= 2 and arguments[1] == "crictl":
            arguments = [
                *arguments[:2],
                "--runtime-endpoint=unix://" + str(self.paths["cri_socket"]),
                *arguments[2:],
            ]
        return subprocess.CompletedProcess(arguments, 0, self.runner(arguments), b"")

    def rules(self, document):
        objects = document["nftables"]
        table = [x["table"] for x in objects if "table" in x]
        require(
            len(table) == 1
            and table[0].get("comment") == self.MARKER
            and (table[0]["name"] == self.TABLE)
            and (table[0]["family"] == "bridge"),
            "unowned nft table",
        )
        sets = [x["set"] for x in objects if "set" in x]
        require(
            len(sets) == 1
            and sets[0]["name"] == "isolated_ports"
            and (sets[0]["type"] == "ifname"),
            "unexpected guard set",
        )
        ports = sets[0].get("elem", [])
        require(
            all(
                (
                    isinstance(p, str) and re.fullmatch("veth[a-f0-9]{1,11}", p)
                    for p in ports
                )
            ),
            "unexpected guard port",
        )
        chains = [x["chain"] for x in objects if "chain" in x]
        require(len(chains) == 2, "unexpected guard chains")
        for name, hook, key in [
            ("from_pod", "prerouting", "iifname"),
            ("to_pod", "postrouting", "oifname"),
        ]:
            chain = [c for c in chains if c["name"] == name]
            require(
                len(chain) == 1
                and chain[0].get("hook") == hook
                and (chain[0].get("prio") == -300)
                and (chain[0].get("type") == "filter")
                and (chain[0].get("policy") == "accept"),
                "guard hook changed",
            )
            found = [
                x["rule"] for x in objects if "rule" in x and x["rule"]["chain"] == name
            ]
            require(len(found) == 1, "unexpected guard rules")
            expressions = found[0]["expr"]
            require(
                len(expressions) == 3
                and expressions[0]
                == {
                    "match": {
                        "op": "==",
                        "left": {"meta": {"key": key}},
                        "right": "@isolated_ports",
                    }
                }
                and (set(expressions[1]) == {"counter"})
                and (expressions[2] == {"drop": None}),
                "guard rule changed",
            )
        require(len([x for x in objects if "rule" in x]) == 2, "additional guard rules")
        return sorted(ports)

    def mapped_ports(self, pods, sandboxes, links):
        by_index = {link["ifindex"]: link for link in links}
        mappings = []
        for pod in pods:
            uid = pod["metadata"]["uid"]
            require(
                pod["metadata"]["namespace"] == self.NAMESPACE,
                "guard namespace differs",
            )
            if not pod.get("status", {}).get("podIP"):
                continue
            matches = [s for s in sandboxes if s.get("metadata", {}).get("uid") == uid]
            require(matches, "Pod CRI mapping unavailable")
            for sandbox in matches:
                sandbox_id = sandbox["id"]
                require(re.fullmatch("[a-f0-9]{64}", sandbox_id), "invalid sandbox ID")
                inspection = json.loads(
                    self.command(
                        [
                            str(self.paths["k3s_executable"]),
                            "crictl",
                            "inspectp",
                            sandbox_id,
                        ]
                    ).stdout,
                    object_pairs_hook=pairs,
                )
                spaces = inspection["info"]["runtimeSpec"]["linux"]["namespaces"]
                paths = [Path(n["path"]) for n in spaces if n["type"] == "network"]
                require(
                    len(paths) == 1
                    and paths[0].parent.resolve() == Path(self.paths["netns_root"])
                    and re.fullmatch("cni-[a-f0-9-]{36}", paths[0].name),
                    "unexpected network namespace",
                )
                interface = json.loads(
                    self.command(
                        [
                            str(self.paths["nsenter_executable"]),
                            f"--net={paths[0]}",
                            str(self.paths["ip_executable"]),
                            "-j",
                            "link",
                            "show",
                            "eth0",
                        ]
                    ).stdout,
                    object_pairs_hook=pairs,
                )
                require(len(interface) == 1, "expected one Pod eth0")
                peer = by_index.get(interface[0].get("link_index"))
                require(
                    peer is not None
                    and re.fullmatch("veth[a-f0-9]{1,11}", peer["ifname"]),
                    "invalid Pod bridge port",
                )
                bridge = next((l for l in links if l["ifname"] == self.bridge), None)
                require(
                    bridge is not None
                    and peer.get("master") in (bridge["ifindex"], self.bridge),
                    "Pod is not on cni0",
                )
                mappings.append(
                    {
                        "pod_uid": uid,
                        "sandbox_id": sandbox_id,
                        "interface": peer["ifname"],
                        "ifindex": peer["ifindex"],
                    }
                )
        return mappings
