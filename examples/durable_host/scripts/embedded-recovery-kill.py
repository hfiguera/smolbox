#!/usr/bin/env python3
"""Kill only the owned BEAM at a selected native persistence checkpoint."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def save(path, value):
    with path.open('x') as output:
        os.chmod(path, 0o600)
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def process_identity(pid):
    result = subprocess.run(
        ['ps', '-p', str(pid), '-o', 'lstart=,command='],
        capture_output=True, text=True, check=False)
    assert result.returncode in (0, 1), 'cannot observe owned helper'
    return result.stdout.strip()


def run(options):
    output = Path(options.output).resolve()
    assert not output.exists(), 'proof output must be new'
    package = Path(options.package).resolve()
    command = ['mix', 'run', 'scripts/embedded-recovery-proof.exs',
               '--phase', 'prepare', '--termination', 'sigkill',
               '--fault', options.fault,
               '--package', str(package), '--fixture', str(Path(options.fixture).resolve()),
               '--sha256', options.sha256,
               '--guest-mode', options.guest_mode,
               '--domain-json', str(Path(options.domain_json).resolve()),
               '--output', str(output)]
    host = Path(__file__).resolve().parent.parent
    log_path = output.with_name(output.name + '-prepare.log')
    with log_path.open('xb') as log:
        os.chmod(log_path, 0o600)
        process = subprocess.Popen(command, cwd=host, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 180
            ready_path = output / 'ready-for-kill.json'
            while not ready_path.exists():
                assert process.poll() is None, 'prepare failed; inspect private log'
                assert time.monotonic() < deadline, 'dispatch barrier deadline'
                time.sleep(0.05)
            while True:
                try:
                    ready = json.loads(ready_path.read_text())
                    break
                except json.JSONDecodeError:
                    assert process.poll() is None, 'prepare exited during evidence write'
                    assert time.monotonic() < deadline, 'incomplete kill barrier evidence'
                    time.sleep(0.01)
            # mix/Elixir execs the BEAM in this process. Refuse any PID that
            # is not the still-live direct child owned by this invocation.
            assert int(ready['beam_os_pid']) == process.pid, 'unexpected BEAM process'
            assert process.poll() is None, 'owned BEAM already exited'
            helper_pid = ready['helper_os_pid']
            helper_identity = process_identity(helper_pid)
            assert str(package / 'smolbox-port') in helper_identity, 'unexpected helper process'
            process.send_signal(signal.SIGKILL)
            assert process.wait(timeout=10) == -signal.SIGKILL, 'wrong termination evidence'
            # Do not kill the helper or VMM. Observe their owner-bound EOF
            # shutdown before opening a replacement account-domain authority.
            deadline = time.monotonic() + 20
            while process_identity(helper_pid) == helper_identity:
                assert time.monotonic() < deadline, 'owned helper did not exit'
                time.sleep(0.05)
            evidence = {'beam_os_pid': ready['beam_os_pid'], 'exit_signal': 9,
                        'helper_exit_observed': True}
            save(output / 'kill-observed.json', evidence)
            print(json.dumps(evidence))
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=20)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('package', 'fixture', 'sha256', 'domain-json', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--guest-mode', choices=['container', 'vm'], default='container')
    parser.add_argument('--fault', choices=['exec-intent', 'exec-result', 'create-intent', 'create-receipt', 'start-receipt'], default='exec-intent')
    run(parser.parse_args())
