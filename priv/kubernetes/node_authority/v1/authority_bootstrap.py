"""Isolated interpreter bootstrap. No arguments, environment or cwd imports."""

import os
from pathlib import Path
import platform
import signal
import sys
import time

started = time.monotonic()


def expired(_signal, _frame):
    raise TimeoutError("authority deadline")


def main():
    if (
        len(sys.argv) != 1
        or os.geteuid() != 0
        or platform.system() != "Linux"
        or platform.machine() != "x86_64"
    ):
        return 1
    signal.signal(signal.SIGALRM, expired)
    signal.signal(signal.SIGHUP, expired)
    signal.signal(signal.SIGTERM, expired)
    signal.setitimer(signal.ITIMER_REAL, 30)
    directory = Path("/usr/local/lib/smolbox-node-authority/v1")
    if Path(__file__) != directory / "authority_bootstrap.py":
        return 1
    # Python -I -S -B supplied by the fixed root entrypoint leaves only the
    # standard library. The fixed approved directory is the sole added path.
    sys.path.insert(0, str(directory))
    from authority_runner import Runner
    from authority_endpoint import serve

    runner = Runner()
    runner.started = started
    runner.deadline = started + 30
    return serve(runner=runner)


if __name__ == "__main__":
    try:
        result = main()
    except Exception:
        result = 1
    raise SystemExit(result)
