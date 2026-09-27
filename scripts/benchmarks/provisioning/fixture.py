#!/usr/bin/env python3
"""Build synthetic, idle bare fixtures on an empty dedicated physical Linux worker."""
import json
import os
import platform
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path


def main(config):
    assert platform.system() == 'Linux'
    probe = subprocess.run(['systemd-detect-virt'], capture_output=True, text=True)
    assert (probe.returncode, probe.stdout.strip()) == (1, 'none')
    root = Path(config['root']).resolve(strict=True)
    assert root.stat().st_mode & 0o077 == 0
    assert not (root / 'bare-base.smolmachine').exists()
    assert not (root / 'seed.smolcheckpoint').exists()
    base = config['worker_url']
    assert base.startswith('http://127.0.0.1:')

    def call(method, path, data=None):
        request = urllib.request.Request(base + path, method=method,
            data=None if data is None else json.dumps(data).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=900) as response:
            return json.load(response)

    assert call('GET', '/api/v1/machines')['machines'] == []
    name = 'fixture-' + uuid.uuid4().hex[:12]
    # Save intent before dispatch. A lost reply needs operator recovery, never replay.
    (root / 'fixture-intent.json').write_text(json.dumps({'name': name}))
    machine = call('POST', '/api/v1/machines', dict(name=name, cpus=1,
                    memoryMb=256, storageGb=1, overlayGb=1, network=False))
    (root / 'fixture-created.json').write_text(json.dumps(machine))
    endpoint = '/api/v1/machines/' + name
    call('POST', endpoint + '/start?branchable=true', {})
    request = urllib.request.Request(base + endpoint + '/checkpoint', data=b'', method='POST')
    with urllib.request.urlopen(request, timeout=900) as response, (root / 'seed.smolcheckpoint').open('xb') as output:
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            assert total <= 1024**3
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())
    call('POST', endpoint + '/stop', {})
    env = {'SMOLVM_DATA_DIR': config['worker_data'], 'XDG_CONFIG_HOME': str(root / 'config'),
           'XDG_CACHE_HOME': str(root / 'cache'), 'TMPDIR': str(root / 'scratch')}
    subprocess.run(['systemd-run', '--user', '--wait', '--pipe', '--collect',
        '-p', 'MemoryMax=8G', '-p', 'MemorySwapMax=0', '-p', 'CPUQuota=400%',
        '-p', 'TasksMax=256', '-p', 'RuntimeMaxSec=900', 'env',
        *[key + '=' + value for key, value in env.items()], config['smolvm'],
        'pack', 'create', '--from-vm', name, '--output', str(root / 'bare-base'),
        '--cpus', '1', '--mem', '256'], check=True)
    observed = call('GET', endpoint)
    assert all(observed[key] == machine[key]
               for key in ['name', 'createdAt', 'cpus', 'memoryMb', 'storageGb', 'overlayGb'])
    call('DELETE', endpoint)
    try:
        call('GET', endpoint)
    except urllib.error.HTTPError as error:
        assert error.code == 404
    else:
        raise AssertionError('deleted fixture still present')
    assert call('GET', '/api/v1/machines')['machines'] == []


if __name__ == '__main__':
    os.umask(0o077)
    main(json.loads(Path(sys.argv[1]).read_text()))
