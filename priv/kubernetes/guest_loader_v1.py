"""Fixed Linux loader: accept only the compile-time approved helper bytes."""
import fcntl
import hashlib
import os
import sys


def exact(size):
    data = bytearray()
    while len(data) < size:
        chunk = os.read(0, min(16384, size - len(data)))
        if not chunk:
            raise ValueError("short helper")
        data.extend(chunk)
    return bytes(data)


try:
    if exact(4) != b"SBP1" or int.from_bytes(exact(4), "big") != __HELPER_BYTES__:
        raise ValueError("helper framing")
    source = exact(__HELPER_BYTES__)
    if hashlib.sha256(source).hexdigest() != "__HELPER_SHA256__":
        raise ValueError("helper identity")
    fd = os.memfd_create("smolbox-helper-v1", os.MFD_ALLOW_SEALING)
    remaining = memoryview(source)
    while remaining:
        count = os.write(fd, remaining[:16384])
        if count <= 0:
            raise ValueError("helper write")
        remaining = remaining[count:]
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS,
                fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
    os.lseek(fd, 0, os.SEEK_SET)
    os.set_inheritable(fd, True)
    os.execv(sys.executable, [sys.executable, "-I", "-S", "-u", f"/proc/self/fd/{fd}"])
except BaseException:
    os.write(2, b"smolbox helper identity failed\n")
    os._exit(126)
