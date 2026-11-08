"""Observe an ordinary IPC worker; release stdin normally, without VM dispatch."""
import os
from pathlib import Path
import subprocess
import time
import unittest


@unittest.skipUnless(os.uname().sysname == 'Linux' and os.environ.get('SMOLBOX_UMASK_HELPER'),
                     'requires a built Linux helper')
class PortUmaskTests(unittest.TestCase):
    def test_helper_sets_private_umask_before_waiting_for_worker_input(self):
        helper = Path(os.environ['SMOLBOX_UMASK_HELPER']).resolve(strict=True)
        process = subprocess.Popen([str(helper), '--file-worker'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, umask=0o002)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                self.assertIsNone(process.poll(), 'worker exited before ordinary IPC input')
                status = Path(f'/proc/{process.pid}/status').read_text()
                value = next(line.split()[1] for line in status.splitlines() if line.startswith('Umask:'))
                if int(value, 8) == 0o077:
                    break
                time.sleep(0.01)
            else:
                self.fail('helper inherited the caller\'s shared umask')
        finally:
            process.stdin.close()  # Invalid/empty request exits normally; no signals.
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
        self.assertNotEqual(process.returncode, 0)


if __name__ == '__main__':
    unittest.main()
