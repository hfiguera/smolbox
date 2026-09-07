#!/usr/bin/env python3
"""Read-only checks for an operator-provisioned, pinned private live-test worker."""

import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import platform
import re
import stat
import subprocess
import time
import urllib.request
import urllib.parse


PINS = {
    "linux": {"system": "Linux", "architecture": "x86_64",
              "binary_sha256": "bb2432804d4bf5d6cbb688d3af160a6a01c99194830f0099d64f291d4ad62373"},
    "macos": {"system": "Darwin", "architecture": "arm64",
              "binary_sha256": "af238c1190aefbc1c293f515c720c9c15f968498ad67624a9b9f824a51af0c79"},
}


def private_file(path, limit):
    path = pathlib.Path(path)
    info = path.lstat()
    if not path.is_absolute() or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("manifest must be an absolute owned regular file")
    if info.st_mode & 0o077 or info.st_size > limit:
        raise ValueError("manifest permissions or size are invalid")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("manifest grew beyond its byte limit")
    return data


def digest(path):
    path = pathlib.Path(path)
    info = path.lstat()
    if not path.is_absolute() or not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 2**33:
        raise ValueError("expected an absolute bounded regular fixture file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate(manifest, system, development):
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        raise ValueError("unsupported worker manifest")
    if manifest.get("platform") != system:
        raise ValueError("manifest platform differs from selected job")
    if os.environ.get("GITHUB_ACTIONS") == "true" and development:
        raise ValueError("development preflight cannot qualify GitHub CI")
    if not development:
        if manifest.get("ephemeral_runner") is not True:
            raise ValueError("CI requires an externally managed disposable runner")
        expires = manifest.get("expires_at_unix")
        if type(expires) is not int or not time.time() + 3300 <= expires <= time.time() + 7200:
            raise ValueError("CI requires a bounded independent teardown deadline")
    lifecycle = manifest.get("lifecycle_id")
    if not isinstance(lifecycle, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", lifecycle):
        raise ValueError("worker lifecycle identity is required")
    pid = manifest.get("worker_pid")
    if type(pid) is not int or pid <= 1:
        raise ValueError("worker process identity is required")
    url = manifest.get("worker_url", "")
    if not isinstance(url, str) or not re.fullmatch(r"http://127\.0\.0\.1:[0-9]{1,5}", url):
        raise ValueError("live fixtures require an exact loopback URL")
    address = urllib.parse.urlsplit(url)
    if address.scheme != "http" or address.hostname != "127.0.0.1" or not address.port:
        raise ValueError("live fixtures require an explicit loopback worker")
    if address.path or address.query or address.fragment or address.username or address.password:
        raise ValueError("worker URL contains unsupported components")
    for key in ["python_sha256", "javascript_sha256"]:
        if not re.fullmatch(r"[0-9a-f]{64}", manifest.get(key, "")):
            raise ValueError("fixture digest is missing")
    for key in ["python_artifact", "javascript_artifact", "database_socket_dir"]:
        value = manifest.get(key)
        if not isinstance(value, str) or "\n" in value or "\r" in value or not value.startswith("/"):
            raise ValueError("invalid fixture path")
    if type(manifest.get("database_port")) is not int or not 1024 <= manifest["database_port"] <= 65535:
        raise ValueError("invalid private database port")
    for key in ["database_user", "database_name"]:
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,62}", manifest.get(key, "")):
            raise ValueError("invalid example database identity")
    if os.environ.get("DATABASE_URL"):
        raise ValueError("DATABASE_URL must not override the isolated fixture database")
    return address


def process_executable(pid, system):
    if system == "linux":
        return os.readlink(f"/proc/{pid}/exe")
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    path = ctypes.create_string_buffer(4096)
    if function(pid, path, len(path)) <= 0:
        raise ValueError("could not inspect owned worker executable")
    return os.fsdecode(path.value)


def verify_listener(pid, port, system):
    uid = subprocess.check_output(["ps", "-p", str(pid), "-o", "uid="], text=True, timeout=3).strip()
    if uid != str(os.getuid()):
        raise ValueError("worker process must belong to the fixture account")
    if system == "linux":
        inodes = set()
        for line in pathlib.Path(f"/proc/{pid}/net/tcp").read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1] == f"0100007F:{port:04X}" and fields[3] == "0A":
                inodes.add(f"socket:[{fields[9]}]")
        for descriptor in pathlib.Path(f"/proc/{pid}/fd").iterdir():
            try:
                if os.readlink(descriptor) in inodes:
                    return
            except FileNotFoundError:
                continue
    else:
        output = subprocess.check_output(
            ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid),
             f"-iTCP@127.0.0.1:{port}", "-sTCP:LISTEN", "-Fn"], timeout=3)
        if len(output) <= 4096 and f"n127.0.0.1:{port}".encode() in output.splitlines():
            return
    raise ValueError("selected worker process does not own the private listener")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _request, _file, _code, _message, _headers, _url):
        return None


def read_http(url, cap=4096):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(url, timeout=3) as response:
        data = response.read(cap + 1)
        if len(data) > cap or response.status != 200:
            raise ValueError("worker preflight response is invalid")
        return data


def preflight(manifest, system, development):
    address = validate(manifest, system, development)
    pins = PINS[system]
    if platform.system() != pins["system"] or platform.machine() != pins["architecture"]:
        raise ValueError("host is outside the qualified platform matrix")
    if system == "linux":
        if not stat.S_ISCHR(os.stat("/dev/kvm").st_mode) or not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise ValueError("read/write KVM is required")
    verify_listener(manifest["worker_pid"], address.port, system)
    executable = process_executable(manifest["worker_pid"], system)
    if digest(executable) != pins["binary_sha256"]:
        raise ValueError("worker executable differs from the pinned release archive")
    cli = pathlib.Path(executable).with_name("smolvm")
    if digest(cli) != "8caeb3b6e7d834493a578b0fe8bd1e7aa02e68fba6d61bcf70fdbec41a27ce68":
        raise ValueError("worker CLI wrapper differs from the pinned release archive")
    for language in ["python", "javascript"]:
        if digest(manifest[language + "_artifact"]) != manifest[language + "_sha256"]:
            raise ValueError("prepared runtime fixture digest differs")
    socket_dir = pathlib.Path(manifest["database_socket_dir"])
    info = socket_dir.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("database socket directory must be private and owned")
    if not stat.S_ISSOCK((socket_dir / f'.s.PGSQL.{manifest["database_port"]}').stat().st_mode):
        raise ValueError("private database socket is absent")
    health = json.loads(read_http(manifest["worker_url"] + "/health"))
    counts = health.get("machines", {})
    if (health.get("version") != "1.14.1" or counts != {"total": 0, "running": 0}
            or any(type(value) is not int for value in counts.values())):
        raise ValueError("worker must be pinned and idle before this job")
    if read_http(manifest["worker_url"] + "/readyz") != b"":
        raise ValueError("worker readiness did not match the pinned contract")
    if json.loads(read_http(manifest["worker_url"] + "/api/v1/machines")) != {"machines": []}:
        raise ValueError("worker inventory is not empty")
    if process_executable(manifest["worker_pid"], system) != executable:
        raise ValueError("worker process changed during preflight")
    return {
        "status": "preflight_passed", "development": development,
        "platform": system, "architecture": platform.machine(), "kernel": platform.release(),
        "logical_cpus": os.cpu_count(), "worker_version": "1.14.1",
        "worker_binary_sha256": pins["binary_sha256"],
        "python_sha256": manifest["python_sha256"], "javascript_sha256": manifest["javascript_sha256"],
        "lifecycle_id": manifest["lifecycle_id"],
        "declared_teardown_at_unix": manifest.get("expires_at_unix"),
        "isolation": "Operator-provisioned lifecycle; this check is not hard resource or hypervisor attestation",
        "virtualization": "KVM accessible" if system == "linux" else "Actual VM boot is required in the following suite",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=PINS, required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    if args.report.exists():
        raise ValueError("preflight report must be new")
    manifest = json.loads(private_file(args.manifest, 16384))
    report = preflight(manifest, args.platform, args.development)
    report["commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    report["working_tree_changes"] = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"]))
    if report["working_tree_changes"] and not args.development:
        raise ValueError("CI requires an unchanged candidate checkout")
    with args.report.open("x", encoding="utf-8") as output:
        output.write(json.dumps(report, indent=2) + "\n")
    if output_file := os.environ.get("GITHUB_ENV"):
        values = {
            "SMOLBOX_SMOLVM_CLI": pathlib.Path(process_executable(manifest["worker_pid"], args.platform)).with_name("smolvm"),
            "SMOLBOX_RUNTIME_URL": manifest["worker_url"],
            "SMOLBOX_PYTHON_ARTIFACT": manifest["python_artifact"],
            "SMOLBOX_PYTHON_SHA256": manifest["python_sha256"],
            "SMOLBOX_JS_ARTIFACT": manifest["javascript_artifact"],
            "SMOLBOX_DATABASE_SOCKET_DIR": manifest["database_socket_dir"],
            "SMOLBOX_DATABASE_PORT": manifest["database_port"],
            "SMOLBOX_DATABASE_USER": manifest["database_user"],
            "SMOLBOX_DATABASE_NAME": manifest["database_name"],
        }
        with open(output_file, "a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
