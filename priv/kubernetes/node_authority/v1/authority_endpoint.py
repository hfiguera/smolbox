"""One bounded read-only protocol invocation; never an administrator API."""

import os
from pathlib import Path
import selectors
import struct

import authority_contract as contract
from authority_config import Configuration, owned_path
from authority_runner import Runner
from authority_verifier import Verifier

CONFIGURATION = Path("/etc/smolbox-node-authority/enrollment.json")


def transfer(fd, runner, size=None, output=None):
    """Bounded framing I/O; output cannot reset the input/observation deadline."""
    buffer = bytearray()
    offset = 0
    with selectors.DefaultSelector() as selector:
        selector.register(
            fd, selectors.EVENT_WRITE if output is not None else selectors.EVENT_READ
        )
        while offset < (len(output) if output is not None else size):
            runner.tick()
            if not selector.select(min(0.05, max(0, runner.remaining()))):
                continue
            if output is not None:
                try:
                    count = os.write(fd, output[offset : offset + 16384])
                except BlockingIOError:
                    continue
                contract.require(count > 0, "output channel lost")
                offset += count
            else:
                try:
                    chunk = os.read(fd, min(16384, size - offset))
                except BlockingIOError:
                    continue
                contract.require(chunk, "input channel lost")
                buffer.extend(chunk)
                offset += len(chunk)
    runner.tick()
    return bytes(buffer)


def load_configuration():
    owned_path(CONFIGURATION, "file", private=True)
    fd = os.open(CONFIGURATION, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as source:
        raw = source.read(131073)
    return Configuration(raw)


def rejection(request, code):
    return {
        **{
            key: request[key]
            for key in contract.IDENTITY_KEYS | {"version", "action", "nonce"}
        },
        "ok": False,
        "journal": None,
        "value": None,
        "error": code,
    }


def serve(input_fd=0, output_fd=1, runner=None):
    runner = runner if runner is not None else Runner()
    # A pipe write larger than PIPE_BUF could otherwise block after select.
    os.set_blocking(input_fd, False)
    os.set_blocking(output_fd, False)
    request = None
    writing = False
    try:
        header = transfer(input_fd, runner, size=8)
        magic, length = header[:4], struct.unpack(">I", header[4:])[0]
        contract.require(
            magic == contract.MAGIC and 1 <= length <= contract.MAX_BODY,
            "request frame",
        )
        request = contract.request(
            contract.decode(transfer(input_fd, runner, size=length))
        )
        runner.tighten(request["timeout_ms"])
        runner.input_fd = input_fd
        runner.tick()
        engine = Verifier(load_configuration(), runner)
        enrollment = engine.read_state(engine.ENROLLMENT)
        generation = engine.verify_enrollment(enrollment)
        expected = {
            "binding_generation": engine.binding["generation"],
            "authority_generation": generation,
            "verifier_manifest_sha256": enrollment["verifier_manifest_sha256"],
        }
        if any(request[key] != value for key, value in expected.items()):
            response = rejection(request, "identity_conflict")
        else:
            arguments = request["arguments"]
            action = request["action"]
            internal = {"version": 1, "action": action, "binding": engine.binding}
            if action == "capture":
                internal["pod_uid"] = arguments["pod_uid"]
            elif action == "cleanup":
                internal["receipt"] = arguments["receipt"]
            evidence = engine.inspect(internal)
            response = {
                **rejection(request, "unavailable"),
                **evidence,
                "ok": True,
                "error": None,
            }
        try:
            contract.response(response, request)
        except ValueError:
            # Never truncate evidence or enlarge the caller's response grant.
            response = rejection(request, "output_limit")
            contract.response(response, request)
        raw = contract.canonical(response)
        writing = True
        transfer(
            output_fd, runner, output=contract.MAGIC + struct.pack(">I", len(raw)) + raw
        )
        return 0
    except Exception:
        # No exception text, paths, credentials or raw subprocess diagnostics
        # are returned. An invalid/pre-identity request gets no response.
        if request is not None and not writing:
            try:
                runner.tick()
                response = rejection(request, "unavailable")
                contract.response(response, request)
                raw = contract.canonical(response)
                transfer(
                    output_fd,
                    runner,
                    output=contract.MAGIC + struct.pack(">I", len(raw)) + raw,
                )
            except (OSError, RuntimeError, ValueError):
                pass
        return 1
