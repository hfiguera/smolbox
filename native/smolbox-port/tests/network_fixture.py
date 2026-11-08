#!/usr/bin/env python3
"""Ordinary local TCP responders in an explicitly isolated disposable lab netns."""
import argparse
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import threading

ADDRESSES = ('198.18.0.10', '198.18.0.11')
RESPONDER_PORT = 8088
RESPONSE = b'smolbox-native-network-fixture\n'


def require_namespace(expected=None):
    assert os.uname().sysname == 'Linux' and os.uname().nodename == 'smolbox-nested'
    identity = str(Path('/proc/self/ns/net').readlink())
    if os.geteuid() == 0:
        assert identity != str(Path('/proc/1/ns/net').readlink()), \
            'explicit unshare --net required; never change the ordinary host network'
    else:
        # PID 1 namespace metadata is intentionally inaccessible to lab. The
        # privileged fixture checked isolation before handing this identity off.
        assert expected is not None and identity == expected, 'verified namespace identity required'
    links = subprocess.check_output(['/usr/sbin/ip', '-o', 'link', 'show'], text=True)
    assert len(links.splitlines()) == 1 and ': lo:' in links, 'loopback-only namespace required'
    return identity


def positive_controls():
    for address in ADDRESSES:
        with socket.create_connection((address, RESPONDER_PORT), timeout=2) as peer:
            received = bytearray()
            while len(received) < len(RESPONSE):
                part = peer.recv(len(RESPONSE) - len(received))
                assert part, 'responder closed before its complete witness'
                received.extend(part)
            assert bytes(received) == RESPONSE


class Responder(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        self.request.sendall(RESPONSE)


def run(command):
    identity = require_namespace()
    assert os.geteuid() == 0, 'namespace setup only; SDK proof must run as lab'
    assert command[:4] == ['/usr/sbin/runuser', '-u', 'lab', '--']
    subprocess.run(['/usr/sbin/ip', 'link', 'set', 'lo', 'up'], check=True)
    for address in ADDRESSES:
        subprocess.run(['/usr/sbin/ip', 'address', 'add', address + '/32', 'dev', 'lo'], check=True)
    servers = []
    threads = []
    try:
        for address in ADDRESSES:
            server = socketserver.TCPServer((address, RESPONDER_PORT), Responder)
            thread = threading.Thread(target=server.serve_forever)
            servers.append(server)
            threads.append(thread)
            thread.start()
        positive_controls()
        # No timeout signal or automatic child termination. The ordinary proof
        # owns finite protocol budgets and preserves unresolved owner evidence.
        child = subprocess.Popen(command + ['--namespace-identity', identity], stdin=subprocess.DEVNULL)
        assert child.wait() == 0, 'ordinary native network proof failed; preserve its output'
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    run(command)
