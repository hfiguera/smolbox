"""Fixed SBK1 helper. Application data arrives only on length-framed stdin."""
import json
import os
import re
import select

MAX_HEADER = 1048576
ACK = b"SBK1\x00\x00\x00\x00"


def require(condition):
    if not condition:
        raise ValueError("invalid request")


def exact(size):
    value = bytearray()
    while len(value) < size:
        chunk = os.read(0, min(16384, size - len(value)))
        require(chunk)
        value.extend(chunk)
    return bytes(value)


def pairs(entries):
    result = {}
    for key, value in entries:
        require(key not in result)
        result[key] = value
    return result


def depth(raw):
    level, string, escape = 0, False, False
    for byte in raw:
        if string:
            if escape:
                escape = False
            elif byte == 92:
                escape = True
            elif byte == 34:
                string = False
        elif byte == 34:
            string = True
        elif byte in (123, 91):
            level += 1
            require(level <= 8)
        elif byte in (125, 93):
            level -= 1
            require(level >= 0)
    require(level == 0 and not string)


def text(value, maximum):
    return isinstance(value, str) and "\x00" not in value and len(value.encode("utf-8")) <= maximum


def command(header):
    require(set(header) == {"version", "operation", "argv", "env", "workdir", "data_bytes"})
    require(type(header["version"]) is int and header["version"] == 1)
    require(type(header["data_bytes"]) is int and header["data_bytes"] == 0)
    argv, entries, workdir = header["argv"], header["env"], header["workdir"]
    require(isinstance(argv, list) and 1 <= len(argv) <= 256)
    require(all(text(arg, 16384) for arg in argv) and argv[0])
    require(sum(len(arg.encode("utf-8")) for arg in argv) <= 65536)
    require(isinstance(entries, list) and len(entries) <= 64)
    env = os.environ.copy()
    names = set()
    for entry in entries:
        require(isinstance(entry, list) and len(entry) == 2)
        key, value = entry
        require(text(key, 128) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key))
        require(text(value, 8192) and key not in names)
        names.add(key)
        env[key] = value
    require(text(workdir, 1024) and (workdir == "/workspace" or workdir.startswith("/workspace/")))
    require(not any(part in ("", ".", "..") for part in workdir.split("/")[1:]))
    require("\\" not in workdir and "%" not in workdir)
    os.chdir(workdir)
    # Producer remains open, so EOF is never a message delimiter. Reject excess
    # bytes already present; application stdin is separately replaced below.
    require(not select.select([0], [], [], 0)[0])
    os.write(1, ACK)
    null = os.open("/dev/null", os.O_RDONLY)
    os.dup2(null, 0)
    if null != 0:
        os.close(null)
    try:
        os.execvpe(argv[0], argv, env)
    except OSError:
        os.write(2, b"smolbox command could not execute\n")
        os._exit(127)


def main():
    require(exact(4) == b"SBK1")
    size = int.from_bytes(exact(4), "big")
    require(0 < size <= MAX_HEADER)
    raw = exact(size)
    depth(raw)
    header = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
    require(isinstance(header, dict) and header.get("operation") == "exec")
    command(header)


try:
    main()
except BaseException:
    os.write(2, b"smolbox helper request failed\n")
    os._exit(126)
