#!/usr/bin/env python3
"""Manual disposable-guest campaigns on ssh linux; never replace the old lab."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

LAB = Path("/var/lib/smolbox-lab")
SOURCE = Path(__file__).resolve().parent
FILES = (
    "install-node.sh",
    "install-preview.sh",
    "offline_guard.py",
    "qualify.py",
    "smoke.py",
    "websocket_probe.py",
    "pins.json",
    "preview-policy.json",
    "runtime-rbac.yaml",
    "source-basis.json",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, **kwargs)


def sha(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1048576):
            value.update(chunk)
    return value.hexdigest()


class Guest:
    def __init__(self, domain):
        require(
            re.fullmatch(r"node-authority-[a-z0-9-]{1,40}", domain),
            "invalid isolated domain name",
        )
        require(
            os.uname().nodename == "pop-os"
            and os.uname().machine == "x86_64"
            and os.geteuid() != 0,
            "run as the dedicated Linux lab operator",
        )
        require(
            run(
                ["findmnt", "-n", "-o", "LABEL", "--target", str(LAB)],
                capture_output=True,
                text=True,
            ).stdout.strip()
            == "smolbox-lab",
            "dedicated lab filesystem required",
        )
        self.root = LAB / domain
        self.domain = domain
        self.unit = "smolbox-" + domain + ".service"
        self.service = Path.home() / ".config/systemd/user" / self.unit

    def checked(self):
        require(
            not self.root.is_symlink()
            and self.root.stat().st_uid == os.getuid()
            and self.root.stat().st_mode & 0o777 == 0o700,
            "domain custody differs",
        )
        value = json.loads((self.root / "domain.json").read_text())
        require(
            value["domain"] == self.domain
            and value["uid"] == os.getuid()
            and value["lab_program_sha256"] == sha(Path(__file__)),
            "domain/tool approval differs",
        )
        return value

    def prepare(self, ssh_port, api_port):
        require(
            1024 <= ssh_port <= 65535
            and 1024 <= api_port <= 65535
            and ssh_port != api_port,
            "distinct unprivileged loopback ports required",
        )
        with (LAB / "vm.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            require(
                not os.path.lexists(self.root) and not os.path.lexists(self.service),
                "domain already exists; no reset or overwrite",
            )
            space = os.statvfs(LAB)
            require(
                space.f_bavail * space.f_frsize > 50 * 1024**3
                and os.access("/dev/kvm", os.R_OK | os.W_OK),
                "qualified free space/KVM access unavailable",
            )
            pins = json.loads((SOURCE / "inputs/pins.json").read_text())
            base = LAB / "images/ubuntu-24.04-server-cloudimg-amd64.img"
            require(
                sha(base) == pins["cloud_image"]["sha256"],
                "base image differs from pin",
            )
            for name, pin in (("k3s", "k3s"), ("smolvm.tar.gz", "smolvm")):
                require(
                    sha(LAB / "kubernetes" / name) == pins[pin]["sha256"],
                    "cached runtime input differs from pin",
                )
            self.root.mkdir(mode=0o700)
            run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    self.domain,
                    "-f",
                    str(self.root / "id_ed25519"),
                ]
            )
            public = (self.root / "id_ed25519.pub").read_text().strip()
            (self.root / "user-data").write_text(
                """#cloud-config
hostname: smolbox-k3s
manage_etc_hosts: true
users:
  - name: lab
    groups: [adm, sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - """
                + public
                + """
disable_root: true
ssh_pwauth: false
runcmd:
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer]
"""
            )
            (self.root / "meta-data").write_text(
                "instance-id: smolbox-"
                + self.domain
                + "\nlocal-hostname: smolbox-k3s\n"
            )
            run(
                [
                    "cloud-localds",
                    str(self.root / "cloud-init.iso"),
                    str(self.root / "user-data"),
                    str(self.root / "meta-data"),
                ]
            )
            run(
                [
                    "qemu-img",
                    "create",
                    "-f",
                    "qcow2",
                    "-F",
                    "qcow2",
                    "-b",
                    str(base),
                    str(self.root / "node.qcow2"),
                    "40G",
                ]
            )
            value = {
                "version": 1,
                "domain": self.domain,
                "uid": os.getuid(),
                "ssh_port": ssh_port,
                "api_port": api_port,
                "lab_program_sha256": sha(Path(__file__)),
                "pins": pins,
                "inputs": {name: sha(SOURCE / "inputs" / name) for name in FILES},
            }
            (self.root / "domain.json").write_text(
                json.dumps(value, sort_keys=True, indent=2) + "\n"
            )
            self.service.parent.mkdir(parents=True, exist_ok=True)
            self.service.write_text(
                """# Managed isolated node-authority campaign guest; no legacy-domain replacement
[Unit]
Description=Disposable SmolBox node-authority campaign guest
[Service]
Type=exec
ExecStart=/usr/bin/python3 -I -S -B """
                + str(Path(__file__).resolve())
                + " --domain "
                + self.domain
                + " vm\n"
                + """RuntimeMaxSec=4h
TimeoutStopSec=20s
KillMode=control-group
Restart=no
CPUQuota=400%
MemoryMax=12G
MemorySwapMax=0
TasksMax=256
LimitFSIZE=42G
LimitCORE=0
UMask=0077
"""
            )
            run(["systemd-analyze", "--user", "verify", str(self.service)])
            run(["systemctl", "--user", "daemon-reload"])
            print(
                "Prepared fresh disposable domain " + self.domain + "; no VM started."
            )

    def vm(self):
        value = self.checked()
        lock = (LAB / "vm.lock").open("r+")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.set_inheritable(lock.fileno(), True)
        arguments = [
            "/usr/bin/qemu-system-x86_64",
            "-add-fd",
            "fd=" + str(lock.fileno()) + ",set=9,opaque=smolbox-vm-lock",
            "-name",
            "smolbox-" + self.domain,
            "-machine",
            "q35,accel=kvm",
            "-cpu",
            "host",
            "-smp",
            "4",
            "-m",
            "8192",
            "-nodefaults",
            "-no-user-config",
            "-display",
            "none",
            "-monitor",
            "none",
            "-qmp",
            "unix:" + str(self.root / "control.sock") + ",server=on,wait=off",
            "-chardev",
            "ringbuf,id=serial,size=1048576",
            "-serial",
            "chardev:serial",
            "-drive",
            "file="
            + str(self.root / "node.qcow2")
            + ",if=virtio,format=qcow2,cache=none,discard=unmap",
            "-drive",
            "file="
            + str(self.root / "cloud-init.iso")
            + ",if=virtio,format=raw,readonly=on",
            "-netdev",
            "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:"
            + str(value["ssh_port"])
            + "-:22,hostfwd=tcp:127.0.0.1:"
            + str(value["api_port"])
            + "-:6443",
            "-device",
            "virtio-net-pci,netdev=net0",
            "-device",
            "virtio-rng-pci",
            "-boot",
            "order=c",
        ]
        os.execv(arguments[0], arguments)

    def ssh_arguments(self, bootstrap=False):
        value = self.checked()
        return [
            "-F",
            "/dev/null",
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentityFile=none",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "IdentityAgent=none",
            "-o",
            "ForwardAgent=no",
            "-o",
            "ClearAllForwardings=yes",
            "-o",
            "StrictHostKeyChecking=" + ("accept-new" if bootstrap else "yes"),
            "-o",
            "UserKnownHostsFile=" + str(self.root / "known_hosts"),
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "UpdateHostKeys=no",
            "-o",
            "ConnectTimeout=5",
            "-i",
            str(self.root / "id_ed25519"),
            "-p",
            str(value["ssh_port"]),
            "lab@127.0.0.1",
        ]

    def bootstrap(self):
        # TOFU is limited to administrator bootstrap on the operator-controlled
        # loopback QEMU endpoint. SDK evidence always requires a separate pin.
        self.checked()
        status = run(
            ["systemctl", "--user", "show", self.unit, "--property=MainPID", "--value"],
            capture_output=True,
            text=True,
        ).stdout.strip()
        require(
            status.isdigit()
            and int(status) > 0
            and str(self.root / "node.qcow2").encode()
            in Path("/proc", status, "cmdline").read_bytes(),
            "owned guest must be running before bootstrap",
        )
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = subprocess.run(
                [
                    "ssh",
                    *self.ssh_arguments(
                        bootstrap=not (self.root / "known_hosts").exists()
                    ),
                    "true",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if result.returncode == 0:
                run(
                    [
                        "ssh",
                        *self.ssh_arguments(),
                        "cloud-init status --wait >/dev/null",
                    ]
                )
                print("Pinned administrator SSH for " + self.domain)
                return
            time.sleep(2)
        raise RuntimeError("guest bootstrap timeout")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", required=True)
    parser.add_argument(
        "action",
        choices=["prepare", "start", "vm", "bootstrap", "ssh", "status", "stop"],
    )
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    guest = Guest(options.domain)
    if options.action == "prepare":
        require(not options.arguments, "prepare has fixed ports 22471/16444")
        guest.prepare(22471, 16444)
    elif options.action == "vm":
        guest.vm()
    elif options.action == "bootstrap":
        guest.bootstrap()
    elif options.action == "ssh":
        os.execvp("ssh", ["ssh", *guest.ssh_arguments(), *options.arguments])
    else:
        guest.checked()
        commands = {
            "start": ["start", guest.unit],
            "stop": ["stop", guest.unit],
            "status": [
                "show",
                guest.unit,
                "--property=ActiveState,SubState,MainPID,Result,RuntimeMaxUSec,MemoryMax,MemorySwapMax,CPUQuotaPerSecUSec,TasksMax",
            ],
        }
        run(["systemctl", "--user", *commands[options.action]])


if __name__ == "__main__":
    main()
