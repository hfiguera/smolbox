"""Fixed SBK1 helper. Application data arrives only on length-framed stdin."""
from contextlib import contextmanager
import hashlib
import json
import os
import re
import select
import signal
import stat
import sys

# The loader's sealed source descriptor is infrastructure, never workload input.
# Python has already read/compiled it; do not pass it into the application exec.
if sys.argv[0].startswith("/proc/self/fd/"):
    source_fd = int(sys.argv[0].rsplit("/", 1)[1])
    if source_fd >= 3:
        os.close(source_fd)

MAX_HEADER = 1048576
ACK = b"SBK1\x00\x00\x00\x00"
MAX_FILE = 1048576
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


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


def write_all(fd, data):
    view = memoryview(data)
    while view:
        count = os.write(fd, view[:16384])
        require(count > 0)
        view = view[count:]


def file_parts(path):
    require(text(path, 1024) and path.startswith("/workspace/"))
    require("\\" not in path and "%" not in path)
    parts = path.split("/")[2:]
    require(1 <= len(parts) <= 64)
    require(all(part not in ("", ".", "..") and len(part.encode("utf-8")) <= 255 for part in parts))
    return parts


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def target(parent, name):
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
    return identity(info)


@contextmanager
def parent_directory(path, create):
    parts = file_parts(path)
    opened = [os.open("/workspace", DIRECTORY)]
    try:
        for part in parts[:-1]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=opened[-1])
                except FileExistsError:
                    pass
            opened.append(os.open(part, DIRECTORY, dir_fd=opened[-1]))

        def stable():
            root = os.open("/workspace", DIRECTORY)
            try:
                require(os.fstat(root).st_ino == os.fstat(opened[0]).st_ino and
                        os.fstat(root).st_dev == os.fstat(opened[0]).st_dev)
            finally:
                os.close(root)
            for index, part in enumerate(parts[:-1]):
                current = os.stat(part, dir_fd=opened[index], follow_symlinks=False)
                held = os.fstat(opened[index + 1])
                require(stat.S_ISDIR(current.st_mode) and
                        (current.st_dev, current.st_ino) == (held.st_dev, held.st_ino))

        yield opened[-1], parts[-1], stable
    finally:
        for fd in reversed(opened):
            os.close(fd)


def file_control(header, operation, extra):
    require(set(header) == {"version", "operation", "path", "data_bytes", "timeout_ms"} | extra)
    require(type(header["version"]) is int and header["version"] == 1 and header["operation"] == operation)
    require(type(header["timeout_ms"]) is int and 0 < header["timeout_ms"] <= 300000)
    signal.signal(signal.SIGALRM, lambda *_: require(False))
    signal.setitimer(signal.ITIMER_REAL, header["timeout_ms"] / 1000)


def file_reply(operation, path, size, digest, data=b""):
    header = json.dumps({"version": 1, "operation": operation, "path": path,
                         "size": size, "sha256": digest}, ensure_ascii=False,
                        separators=(",", ":")).encode()
    require(0 < len(header) <= 8192)
    write_all(1, ACK + b"SBF1" + len(header).to_bytes(4, "big") + header)
    write_all(1, data)


def upload(header):
    file_control(header, "upload", {"sha256"})
    size = header["data_bytes"]
    require(type(size) is int and 0 <= size <= MAX_FILE)
    require(isinstance(header["sha256"], str) and re.fullmatch(r"[a-f0-9]{64}", header["sha256"]))
    with parent_directory(header["path"], True) as (parent, name, stable):
        original = target(parent, name)
        temporary = ".smolbox-upload-" + os.urandom(16).hex()
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        own = os.fstat(fd)
        try:
            digest = hashlib.sha256()
            remaining = size
            while remaining:
                chunk = exact(min(16384, remaining))
                digest.update(chunk)
                write_all(fd, chunk)
                remaining -= len(chunk)
            require(digest.hexdigest() == header["sha256"])
            require(not select.select([0], [], [], 0)[0])
            os.fsync(fd)
            stable()
            require(target(parent, name) == original)
            os.replace(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
            temporary = None
            os.fsync(parent)
            file_reply("upload", header["path"], size, digest.hexdigest())
        finally:
            os.close(fd)
            if temporary is not None:
                try:
                    item = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
                    if (item.st_dev, item.st_ino) == (own.st_dev, own.st_ino):
                        os.unlink(temporary, dir_fd=parent)
                except FileNotFoundError:
                    pass


def download(header):
    file_control(header, "download", {"max_bytes"})
    require(type(header["data_bytes"]) is int and header["data_bytes"] == 0)
    require(type(header["max_bytes"]) is int and 0 < header["max_bytes"] <= MAX_FILE)
    require(not select.select([0], [], [], 0)[0])
    with parent_directory(header["path"], False) as (parent, name, stable):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= header["max_bytes"])
            data = bytearray()
            while len(data) < before.st_size:
                chunk = os.read(fd, min(16384, before.st_size - len(data)))
                require(chunk)
                data.extend(chunk)
            require(os.read(fd, 1) == b"")
            after = os.fstat(fd)
            require(identity(before) == identity(after) == target(parent, name))
            stable()
            require(not select.select([0], [], [], 0)[0])
            file_reply("download", header["path"], len(data), hashlib.sha256(data).hexdigest(), data)
        finally:
            os.close(fd)


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
    require(isinstance(header, dict))
    operation = header.get("operation")
    if operation == "exec":
        command(header)
    elif operation == "upload":
        upload(header)
    elif operation == "download":
        download(header)
    else:
        require(False)


try:
    main()
except BaseException:
    os.write(2, b"smolbox helper request failed\n")
    os._exit(126)
