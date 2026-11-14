"""One observation deadline/owner, bounded output, no shell or workload lifecycle."""

from contextlib import contextmanager
import fcntl
import os
import selectors
import stat
import subprocess
import time

from authority_contract import require


class Runner:
    def __init__(self, timeout_ms=30_000, input_fd=None):
        self.started = time.monotonic()
        self.deadline = self.started + min(timeout_ms, 30_000) / 1000
        self.input_fd = input_fd

    def tighten(self, timeout_ms):
        self.deadline = min(self.deadline, self.started + timeout_ms / 1000)
        self.tick()

    def owner(self):
        if self.input_fd is not None:
            with selectors.DefaultSelector() as selector:
                selector.register(self.input_fd, selectors.EVENT_READ)
                require(not selector.select(0), "observation owner/input lost")

    def tick(self):
        require(time.monotonic() < self.deadline, "observation deadline")
        self.owner()

    def remaining(self):
        self.tick()
        return self.deadline - time.monotonic()

    def __call__(self, arguments):
        self.tick()
        require(
            isinstance(arguments, list)
            and arguments
            and os.path.isabs(arguments[0])
            and all(isinstance(arg, str) and "\0" not in arg for arg in arguments),
            "observation argument vector",
        )
        # Each command has its complete fixed argument family in the verifier.
        # Neither the endpoint request nor inherited environment selects commands.
        environment = {
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG": "C.UTF-8",
            "HOME": "/nonexistent",
        }
        with subprocess.Popen(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        ) as process:
            chunks, size = [], 0
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
                    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
                    if self.input_fd is not None:
                        selector.register(self.input_fd, selectors.EVENT_READ, "parent")
                    while any(
                        key.data != "parent" for key in selector.get_map().values()
                    ):
                        self.tick()
                        for key, _ in selector.select(
                            min(0.1, max(0, self.deadline - time.monotonic()))
                        ):
                            require(
                                key.data != "parent", "observation owner/input lost"
                            )
                            chunk = os.read(key.fd, 16384)
                            size += len(chunk)
                            require(size <= 2097152, "observation command byte bound")
                            if not chunk:
                                selector.unregister(key.fd)
                            elif key.data == "stdout":
                                chunks.append(chunk)
                    while process.poll() is None:
                        self.tick()
                        time.sleep(min(0.01, max(0, self.deadline - time.monotonic())))
                    require(process.returncode == 0, "observation command unavailable")
                self.tick()
                return b"".join(chunks)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=2)

    @contextmanager
    def locked(self, path):
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, "r+") as lock:
            info = os.fstat(lock.fileno())
            require(
                stat.S_ISREG(info.st_mode)
                and info.st_nlink == 1
                and info.st_uid == os.geteuid()
                and stat.S_IMODE(info.st_mode) == 0o600,
                "observation lock ownership",
            )
            while True:
                self.tick()
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(min(0.05, max(0, self.deadline - time.monotonic())))
            yield
            self.tick()
