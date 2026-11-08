"""Bounded, reproducible guest-rootfs archive creation for an owned package copy.

No link targets are opened. This is build-time asset preparation, not export of
any guest disk, a cache lookup, or permission to publish a native package.
"""
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import time

MAX_BYTES = 2 * 1024 ** 3
MAX_ENTRIES = 32768
SECONDS = 120
MARKER = '.smolvm-ready.'


def version(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_uid, value.st_gid, value.st_mtime_ns, value.st_ctime_ns)


def snapshot(root, deadline):
    found = []
    pending = [root]
    root_version = version(root.lstat())
    while pending:
        directory = pending.pop()
        if time.monotonic() >= deadline:
            raise ValueError('rootfs archive deadline')
        with os.scandir(directory) as entries:
            for entry in entries:
                if entry.name.startswith(MARKER):
                    continue
                if len(found) >= MAX_ENTRIES:
                    raise ValueError('too many rootfs archive entries')
                path = Path(entry.path)
                metadata = entry.stat(follow_symlinks=False)
                if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)
                        or stat.S_ISLNK(metadata.st_mode)):
                    raise ValueError('unsupported rootfs archive entry')
                relative = path.relative_to(root).as_posix()
                link = os.readlink(path) if stat.S_ISLNK(metadata.st_mode) else None
                if len(relative.encode()) > 4096 or (link is not None and len(os.fsencode(link)) > 4096):
                    raise ValueError('rootfs archive path limit')
                found.append((relative, version(metadata), link))
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append(path)
    return root_version, sorted(found)


class Writer:
    def __init__(self, file, maximum, deadline):
        self.file, self.maximum, self.deadline, self.bytes = file, maximum, deadline, 0

    def write(self, data):
        if time.monotonic() >= self.deadline:
            raise ValueError('rootfs archive deadline')
        if self.bytes + len(data) > self.maximum:
            raise ValueError('rootfs archive byte limit')
        written = self.file.write(data)
        if written != len(data):
            raise OSError('short rootfs archive write')
        self.bytes += written
        return written


class Reader:
    def __init__(self, file, deadline):
        self.file, self.deadline = file, deadline

    def read(self, length):
        if time.monotonic() >= self.deadline:
            raise ValueError('rootfs archive deadline')
        return self.file.read(min(length, 64 * 1024))


def create(root, target, *, max_bytes=MAX_BYTES):
    root, target = Path(root).absolute(), Path(target).absolute()
    if root.is_symlink() or not root.is_dir() or target.is_relative_to(root):
        raise ValueError('rootfs archive requires a separate owned output')
    if not 0 < max_bytes <= MAX_BYTES:
        raise ValueError('rootfs archive byte limit')
    if target.exists() or target.is_symlink():
        raise FileExistsError('rootfs archive destination exists')
    deadline = time.monotonic() + SECONDS
    before = snapshot(root, deadline)
    with tempfile.NamedTemporaryFile(prefix='.rootfs-', dir=target.parent) as output:
        writer = Writer(output, max_bytes, deadline)
        # PAX supports long/UTF-8 guest paths without leaking host path metadata.
        # Sorted entries and normalized ownership/time yield reproducible bytes.
        with tarfile.open(fileobj=writer, mode='w|', format=tarfile.PAX_FORMAT,
                          bufsize=64 * 1024) as archive:
            for relative, expected, link in before[1]:
                path = root / relative
                if version(path.lstat()) != expected:
                    raise ValueError('rootfs archive input changed')
                header = tarfile.TarInfo(relative)
                header.mode = stat.S_IMODE(expected[2])
                header.uid = header.gid = header.mtime = 0
                header.uname = header.gname = ''
                if stat.S_ISDIR(expected[2]):
                    header.type = tarfile.DIRTYPE
                    archive.addfile(header)
                elif stat.S_ISLNK(expected[2]):
                    header.type, header.linkname = tarfile.SYMTYPE, link
                    archive.addfile(header)
                else:
                    if expected[3] > max_bytes:
                        raise ValueError('rootfs archive byte limit')
                    header.size = expected[3]
                    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
                    with os.fdopen(fd, 'rb') as file:
                        if version(os.fstat(file.fileno())) != expected:
                            raise ValueError('rootfs archive input changed')
                        archive.addfile(header, Reader(file, deadline))
                        if version(os.fstat(file.fileno())) != expected:
                            raise ValueError('rootfs archive input changed')
        if snapshot(root, deadline) != before:
            raise ValueError('rootfs archive input changed')
        output.flush()
        os.fchmod(output.fileno(), 0o400)
        os.fsync(output.fileno())
        # Publish without replacing any existing path; the caller owns this copy.
        os.link(output.name, target, follow_symlinks=False)
    directory = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
