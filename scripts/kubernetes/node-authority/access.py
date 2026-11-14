#!/usr/bin/env python3
"""Manual SSH access fixture on a fresh disposable guest, before enrollment.

This intentionally leaves an un-enrolled installation. Preserve this guest as
access evidence; use another fresh domain for the real runtime campaign.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import secrets
import socket
import struct
import subprocess
import tarfile
import time

PRINCIPAL = "smolbox-evidence"
HOME = Path("/var/lib/smolbox-node-evidence-home")
PROGRAMS = Path("/usr/local/lib/smolbox-node-authority/v1")
MARKER = Path("/var/lib/smolbox-node-authority-access-fixture.json")
ROOT_KEY = Path("/root/.ssh/id_ed25519")
HOSTS = Path("/root/.ssh/authority-known-hosts")
ENTRY = Path("/usr/local/libexec/smolbox-node-authority")
FORCED = Path("/usr/local/libexec/smolbox-node-authority-ssh")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def write(path, data, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb") as target:
        os.fchmod(target.fileno(), mode)
        target.write(data)


def prepare(bundle, expected, public_key):
    require(
        not any(
            os.path.lexists(path)
            for path in [
                PROGRAMS,
                ENTRY,
                FORCED,
                HOME,
                MARKER,
                Path("/var/lib/smolbox-node-authority"),
                ROOT_KEY,
            ]
        ),
        "access fixture requires a fresh guest; no replacement",
    )
    try:
        pwd.getpwnam(PRINCIPAL)
    except KeyError:
        pass
    else:
        raise RuntimeError("evidence principal already exists")
    require(digest(bundle.read_bytes()) == expected, "offline bundle checksum differs")
    files, expanded = {}, 0
    with tarfile.open(bundle) as archive:
        for member in archive:
            require(
                member.isfile()
                and member.name.startswith("smolbox-node-authority-v1/")
                and ".." not in Path(member.name).parts
                and len(files) < 64
                and member.size <= 262144,
                "unsafe offline bundle",
            )
            expanded += member.size
            require(
                expanded <= 2097152 and member.name not in files,
                "offline bundle bounds",
            )
            files[member.name] = archive.extractfile(member).read()
    prefix = "smolbox-node-authority-v1/"
    files = {name[len(prefix) :]: value for name, value in files.items()}
    package = json.loads(files["package-manifest.json"])
    require(
        package
        == {
            "version": 1,
            "files": {
                name: digest(value)
                for name, value in files.items()
                if name != "package-manifest.json"
            },
        },
        "offline package manifest differs",
    )
    manifest = json.loads(files["programs/manifest.json"])
    programs = {
        name[len("programs/") :]: value
        for name, value in files.items()
        if name.startswith("programs/")
    }
    require(
        manifest
        == {
            "version": 1,
            "files": {
                name: digest(value)
                for name, value in programs.items()
                if name != "manifest.json"
            },
        },
        "offline verifier manifest differs",
    )
    for path in [PROGRAMS.parent, PROGRAMS, ENTRY.parent]:
        path.mkdir(mode=0o755, parents=True, exist_ok=True)
        path.chmod(0o755)
    for name, data in programs.items():
        require(Path(name).name == name, "invalid program name")
        write(PROGRAMS / name, data, 0o755 if name.endswith(".sh") else 0o644)
    ENTRY.symlink_to(PROGRAMS / "entrypoint.sh")
    FORCED.symlink_to(PROGRAMS / "ssh-command.sh")
    run(
        [
            "useradd",
            "--system",
            "--user-group",
            "--no-create-home",
            "--home-dir",
            str(HOME),
            "--shell",
            "/bin/sh",
            PRINCIPAL,
        ]
    )
    for path in [HOME, HOME / ".ssh"]:
        path.mkdir(mode=0o755)
        path.chmod(0o755)
    parts = public_key.read_text().split()
    require(
        len(parts) >= 2
        and parts[0] == "ssh-ed25519"
        and len(base64.b64decode(parts[1], validate=True)) == 51,
        "expected one Ed25519 public key",
    )
    Path("/root/.ssh").mkdir(mode=0o700, exist_ok=True)
    run(
        [
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-C",
            "access-fixture-default-key",
            "-f",
            str(ROOT_KEY),
        ]
    )
    defaults = ROOT_KEY.with_suffix(".pub").read_text().split()[:2]
    policy = 'restrict,command="' + str(FORCED) + '" '
    # Public key policy is readable by the non-root SSH principal, unwritable.
    write(
        HOME / ".ssh/authorized_keys",
        (
            policy + " ".join(parts[:2]) + "\n" + policy + " ".join(defaults) + "\n"
        ).encode(),
        0o644,
    )
    write(
        HOSTS,
        b"127.0.0.1 "
        + b" ".join(Path("/etc/ssh/ssh_host_ed25519_key.pub").read_bytes().split()[:2])
        + b"\n",
        0o600,
    )
    sudoers = Path("/etc/sudoers.d/smolbox-node-authority")
    write(
        sudoers,
        (
            "Defaults:"
            + PRINCIPAL
            + " env_reset,!setenv\n"
            + PRINCIPAL
            + " ALL=(root) NOPASSWD: NOSETENV: "
            + str(ENTRY)
            + ' ""\n'
        ).encode(),
        0o440,
    )
    run(["visudo", "-cf", str(sudoers)])
    config = Path("/etc/ssh/sshd_config")
    original = config.read_text()
    require(
        not re.search(r"^Match\s", original, re.MULTILINE),
        "unexpected existing SSH Match policy",
    )
    config.write_text(
        "LogLevel DEBUG3\nPermitUserEnvironment no\n"
        + original
        + "\n# SmolBox pre-enrollment access fixture\nMatch User "
        + PRINCIPAL
        + "\n"
        + "    AuthorizedKeysFile "
        + str(HOME / ".ssh/authorized_keys")
        + "\n"
        + "    AuthenticationMethods publickey\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n"
        + "    PermitTTY no\n    DisableForwarding yes\n    PermitUserRC no\n"
        + "    ForceCommand "
        + str(FORCED)
        + "\n"
    )
    run(["/usr/sbin/sshd", "-t"])
    run(["systemctl", "reload", "ssh.service"])
    value = {
        "version": 1,
        "scope": "pre_enrollment_access_fixture_only",
        "archive_sha256": expected,
        "verifier_manifest_sha256": digest(
            json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
        ),
        "node_boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "uid": pwd.getpwnam(PRINCIPAL).pw_uid,
        "programs": manifest["files"],
    }
    write(MARKER, json.dumps(value, sort_keys=True).encode(), 0o600)
    print(json.dumps(value, sort_keys=True))


def arguments(key=ROOT_KEY, hosts=HOSTS, defaults_disabled=True, agent="none"):
    options = [
        "BatchMode=yes",
        "StrictHostKeyChecking=yes",
        "IdentitiesOnly=yes",
        "IdentityAgent=" + str(agent),
        "PreferredAuthentications=publickey",
        "GlobalKnownHostsFile=/dev/null",
        "UpdateHostKeys=no",
        "ControlMaster=no",
        "ControlPath=none",
        "ConnectTimeout=3",
        "UserKnownHostsFile=" + str(hosts),
    ]
    if defaults_disabled:
        options.append("IdentityFile=none")
    return [
        "/usr/bin/ssh",
        "-F",
        "/dev/null",
        "-T",
        *[part for option in options for part in ["-o", option]],
        "-i",
        str(key),
        "-l",
        PRINCIPAL,
    ]


def invoke(arguments, body=None, env=None, timeout=6):
    with subprocess.Popen(
        arguments,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    ) as process:
        out, err, count = [], [], 0
        try:
            if body is None:
                process.stdin.close()
            else:
                process.stdin.write(body)
                process.stdin.flush()
            deadline = time.monotonic() + timeout
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, out)
                selector.register(process.stderr, selectors.EVENT_READ, err)
                while selector.get_map():
                    require(time.monotonic() < deadline, "SSH access probe timeout")
                    for key, _ in selector.select(0.05):
                        value = os.read(key.fd, 16384)
                        count += len(value)
                        require(count <= 131072, "SSH access probe byte bound")
                        if value:
                            key.data.append(value)
                        else:
                            selector.unregister(key.fd)
            return process.wait(timeout=1), b"".join(out), b"".join(err)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)


def forwarding(kind):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    spec = "127.0.0.1:" + str(port) + (":127.0.0.1:22" if kind == "local" else "")
    argv = [
        *arguments(),
        "-N",
        "-o",
        "ExitOnForwardFailure=yes",
        "-L" if kind == "local" else "-D",
        spec,
        "127.0.0.1",
    ]
    process = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    observed = b""
    try:
        deadline = time.monotonic() + 4
        while True:
            require(
                process.poll() is None and time.monotonic() < deadline,
                "client forwarding listener unavailable",
            )
            try:
                client = socket.create_connection(("127.0.0.1", port), timeout=0.5)
                break
            except ConnectionRefusedError:
                time.sleep(0.02)
        with client:
            client.settimeout(2)
            if kind == "dynamic":
                client.sendall(b"\x05\x01\x00")
                require(client.recv(2) == b"\x05\x00", "SOCKS request was not made")
                client.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x16")
            try:
                while chunk := client.recv(1024):
                    observed += chunk
                    require(len(observed) <= 4096, "forwarding control byte bound")
            except ConnectionResetError:
                pass
    finally:
        if process.poll() is None:
            process.terminate()
        _, error = process.communicate(timeout=2)
    return b"administratively prohibited" in error and b"SSH-2.0" not in observed


def journal_cursor():
    value = run(
        [
            "journalctl",
            "_COMM=sshd",
            "SYSLOG_IDENTIFIER=sshd",
            "-n",
            "1",
            "--show-cursor",
            "--no-pager",
            "-o",
            "cat",
        ],
        capture_output=True,
        text=True,
    ).stdout
    return next(
        line[len("-- cursor: ") :]
        for line in value.splitlines()
        if line.startswith("-- cursor: ")
    )


def journal_after(cursor):
    run(["journalctl", "--sync"], capture_output=True)
    return run(
        [
            "journalctl",
            "_COMM=sshd",
            "SYSLOG_IDENTIFIER=sshd",
            "--after-cursor=" + cursor,
            "--no-pager",
            "-o",
            "cat",
            "-n",
            "5000",
        ],
        capture_output=True,
    ).stdout.lower()


def agent_forwarding(body, unavailable):
    agent_socket = Path("/root/.ssh/authority-access-agent.sock")
    require(not agent_socket.exists(), "old agent fixture socket remains")
    process = subprocess.Popen(
        ["ssh-agent", "-D", "-a", str(agent_socket)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 2
        while not agent_socket.exists():
            require(
                process.poll() is None and time.monotonic() < deadline,
                "agent fixture unavailable",
            )
            time.sleep(0.01)
        environment = dict(os.environ, SSH_AUTH_SOCK=str(agent_socket))
        run(
            ["ssh-add", "-t", "30", str(ROOT_KEY)], env=environment, capture_output=True
        )
        cursor = journal_cursor()
        result = invoke(
            [
                *arguments(agent=agent_socket),
                "-A",
                "127.0.0.1",
                "smolbox-node-authority-v1",
            ],
            body,
            environment,
        )
        server = journal_after(cursor)
        return unavailable(result) and b"agent forwarding disabled" in server
    finally:
        process.terminate()
        process.communicate(timeout=2)


def endpoint_processes():
    values = set()
    for path in Path("/proc").glob("[0-9]*/cmdline"):
        try:
            if str(
                PROGRAMS / "authority_bootstrap.py"
            ).encode() in path.read_bytes().split(b"\0"):
                fields = path.with_name("stat").read_text().rsplit(")", 1)[1].split()
                if fields[0] != "Z":
                    values.add((int(path.parent.name), int(fields[19])))
        except FileNotFoundError:
            pass
    return values


def disconnected_endpoint():
    require(not endpoint_processes(), "another endpoint observation is active")
    with subprocess.Popen(
        [*arguments(), "127.0.0.1", "smolbox-node-authority-v1"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as process:
        process.stdin.write(b"SBA1")
        process.stdin.flush()
        deadline = time.monotonic() + 3
        original = set()
        while not original:
            require(time.monotonic() < deadline, "endpoint did not start")
            original = endpoint_processes()
            time.sleep(0.01)
        process.terminate()
        process.wait(timeout=2)
        deadline = time.monotonic() + 2
        while original & endpoint_processes() and time.monotonic() < deadline:
            time.sleep(0.01)
        return not original & endpoint_processes()


def check(report):
    marker = json.loads(MARKER.read_text())
    require(
        not Path("/var/lib/smolbox-node-authority").exists()
        and marker["node_boot_id"]
        == Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "fixture authority/boot changed",
    )
    require(
        all(
            digest((PROGRAMS / name).read_bytes()) == expected
            for name, expected in marker["programs"].items()
        ),
        "fixture verifier changed",
    )
    request = {
        "version": 1,
        "action": "check",
        "nonce": secrets.token_hex(32),
        "binding_generation": "1" * 64,
        "authority_generation": "2" * 64,
        "verifier_manifest_sha256": marker["verifier_manifest_sha256"],
        "timeout_ms": 3000,
        "max_response_bytes": 65544,
        "arguments": {},
    }
    data = json.dumps(request, separators=(",", ":")).encode()
    body = b"SBA1" + struct.pack(">I", len(data)) + data
    results = {}
    effective = run(
        [
            "/usr/sbin/sshd",
            "-T",
            "-C",
            "user=" + PRINCIPAL + ",host=localhost,addr=127.0.0.1",
        ],
        capture_output=True,
        text=True,
    ).stdout
    options = dict(line.split(" ", 1) for line in effective.splitlines())
    required = {
        "authenticationmethods": "publickey",
        "passwordauthentication": "no",
        "kbdinteractiveauthentication": "no",
        "permittty": "no",
        "disableforwarding": "yes",
        "permituserrc": "no",
        "permituserenvironment": "no",
        "forcecommand": str(FORCED),
        "authorizedkeysfile": str(HOME / ".ssh/authorized_keys"),
    }
    results["effective_sshd_policy"] = all(
        options[key].strip() == value for key, value in required.items()
    )

    def unavailable(value):
        status, output, _ = value
        if status != 1 or output[:4] != b"SBA1" or len(output) < 8:
            return False
        length = struct.unpack(">I", output[4:8])[0]
        if length != len(output) - 8:
            return False
        response = json.loads(output[8:])
        return (
            response["nonce"] == request["nonce"]
            and response["ok"] is False
            and response["value"] is None
            and response["error"] == "unavailable"
        )

    results["literal_fixed_root_entrypoint"] = unavailable(
        invoke([*arguments(), "127.0.0.1", "smolbox-node-authority-v1"], body)
    )
    for name, command in [
        ("shell", []),
        ("arbitrary_command", ["printf forbidden"]),
        ("arbitrary_sudo_over_ssh", ["sudo id"]),
        ("wrong_token", ["smolbox-node-authority-v2"]),
        ("additional_arguments", ["smolbox-node-authority-v1 extra"]),
        ("shell_metacharacters", ["smolbox-node-authority-v1; id"]),
    ]:
        status, output, _ = invoke([*arguments(), "127.0.0.1", *command])
        results[name + "_denied"] = status != 0 and not output
    status, output, _ = invoke([*arguments(), "-s", "127.0.0.1", "sftp"])
    results["subsystem_denied"] = status != 0 and not output
    status, output, error = invoke(
        [*arguments(), "-tt", "127.0.0.1", "smolbox-node-authority-v1"], body
    )
    results["pty_denied"] = b"PTY allocation request failed" in error
    status, output, _ = invoke(
        [
            *arguments(),
            "-o",
            "SetEnv=SSH_ORIGINAL_COMMAND=smolbox-node-authority-v1",
            "127.0.0.1",
            "printf forbidden",
        ]
    )
    results["original_command_environment_injection_denied"] = (
        status != 0 and not output
    )
    results["interpreter_environment_injection_denied"] = unavailable(
        invoke(
            [
                *arguments(),
                "-o",
                "SetEnv=PYTHONPATH=/private LD_PRELOAD=/private BASH_ENV=/private",
                "127.0.0.1",
                "smolbox-node-authority-v1",
            ],
            body,
        )
    )
    missing = Path("/root/.ssh/authority-intentionally-missing")
    require(not missing.exists(), "missing-key control path exists")
    status, output, _ = invoke(
        [*arguments(key=missing), "127.0.0.1", "smolbox-node-authority-v1"], body
    )
    results["missing_explicit_key_no_default_fallback"] = status == 255 and not output
    results["missing_key_control_would_fallback_without_none"] = unavailable(
        invoke(
            [
                *arguments(key=missing, defaults_disabled=False),
                "127.0.0.1",
                "smolbox-node-authority-v1",
            ],
            body,
        )
    )
    foreign = Path("/root/.ssh/foreign-authority-key")
    if not foreign.exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(foreign)])
    status, output, _ = invoke(
        [*arguments(key=foreign), "127.0.0.1", "smolbox-node-authority-v1"], body
    )
    results["wrong_key_denied"] = status == 255 and not output
    foreign_hosts = Path("/root/.ssh/foreign-authority-known-hosts")
    if not foreign_hosts.exists():
        write(
            foreign_hosts,
            b"127.0.0.1 "
            + b" ".join(foreign.with_suffix(".pub").read_bytes().split()[:2])
            + b"\n",
            0o600,
        )
    status, output, _ = invoke(
        [*arguments(hosts=foreign_hosts), "127.0.0.1", "smolbox-node-authority-v1"],
        body,
    )
    results["wrong_host_key_denied"] = status == 255 and not output
    for name, argv in [
        ("arbitrary_sudo", ["/usr/bin/id"]),
        ("interpreter_sudo", ["/usr/bin/python3", "-V"]),
        ("entrypoint_arguments_sudo", [str(ENTRY), "extra"]),
    ]:
        value = subprocess.run(
            ["sudo", "-u", PRINCIPAL, "sudo", "-n", "--", *argv], capture_output=True
        )
        results[name + "_denied"] = value.returncode != 0 and not value.stdout
    for name, path in [
        ("home", HOME),
        ("ssh_directory", HOME / ".ssh"),
        ("authorized_keys", HOME / ".ssh/authorized_keys"),
        ("programs", PROGRAMS),
    ]:
        value = subprocess.run(["sudo", "-u", PRINCIPAL, "test", "-w", str(path)])
        results[name + "_not_principal_writable"] = value.returncode == 1
    status, output, error = invoke(
        [
            *arguments(),
            "-N",
            "-o",
            "ExitOnForwardFailure=yes",
            "-R",
            "0:127.0.0.1:22",
            "127.0.0.1",
        ]
    )
    results["remote_forwarding_denied"] = (
        status == 255 and b"remote port forwarding failed" in error
    )
    results["local_forwarding_denied"] = forwarding("local")
    results["dynamic_forwarding_denied"] = forwarding("dynamic")
    results["agent_forwarding_denied"] = agent_forwarding(body, unavailable)
    cursor = journal_cursor()
    x11 = invoke(
        [
            *arguments(),
            "-X",
            "-o",
            "ForwardX11Trusted=yes",
            "-o",
            "XAuthLocation=/usr/bin/true",
            "127.0.0.1",
            "smolbox-node-authority-v1",
        ],
        body,
        dict(os.environ, DISPLAY=":99"),
    )
    server = journal_after(cursor)
    results["x11_forwarding_denied"] = unavailable(x11) and (
        b"x11 forwarding disabled" in server
        or b"x11 forwarding request failed" in x11[2].lower()
    )
    results["client_loss_ends_original_endpoint"] = disconnected_endpoint()
    started = time.monotonic()
    status, output, _ = invoke(
        [*arguments(), "127.0.0.1", "smolbox-node-authority-v1"], b"SBA1", timeout=35
    )
    results["partial_header_original_30_second_deadline"] = (
        status != 0 and not output and 28 <= time.monotonic() - started <= 33
    )
    value = {
        "version": 1,
        "scope": "pre_enrollment_access_fixture_only",
        "node_boot_id": marker["node_boot_id"],
        "archive_sha256": marker["archive_sha256"],
        "verifier_manifest_sha256": marker["verifier_manifest_sha256"],
        "ssh_version": subprocess.run(
            ["/usr/bin/ssh", "-V"], capture_output=True, text=True
        ).stderr.strip(),
        "controls": results,
        "all_controls_passed": all(results.values()),
        "not_yet_tested": [],
        "no_node_enrollment_or_workload_evidence": True,
    }
    report.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    print(json.dumps(value, sort_keys=True))
    require(all(results.values()), "access control campaign failed; preserve report")


def main():
    require(
        os.geteuid() == 0
        and os.uname().nodename == "smolbox-k3s"
        and run(["systemd-detect-virt"], capture_output=True, text=True).stdout.strip()
        == "kvm",
        "fresh disposable root guest required",
    )
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "check"])
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--archive-sha256")
    parser.add_argument("--public-key", type=Path)
    parser.add_argument("--report", type=Path)
    options = parser.parse_args()
    if options.action == "prepare":
        prepare(options.bundle, options.archive_sha256, options.public_key)
    else:
        check(options.report)


if __name__ == "__main__":
    main()
