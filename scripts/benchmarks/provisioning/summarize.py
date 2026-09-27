#!/usr/bin/env python3
"""Summarize complete provisioning runs. Fail closed on missing/failed samples."""
import argparse
import json
import math
import statistics
from pathlib import Path

MODES = ('fresh', 'export', 'checkpoint', 'branch', 'reuse')
PHASES = ('ready', 'memory-ready', 'isolation', 'cleanup')


def stats(values):
    ordered = sorted(values)
    return {'n': len(values), 'median': statistics.median(ordered),
            'p95': ordered[math.ceil(.95 * len(ordered)) - 1],
            'min': ordered[0], 'max': ordered[-1]}


def summarize(rows, samples):
    if not 1 <= samples <= 40:
        raise ValueError('samples must be in 1..40')
    if any(row.get('success') is not True for row in rows):
        raise ValueError('failed or incomplete stage; preserve and investigate the run')
    indexed = {}
    for row in rows:
        if row['phase'] not in PHASES:
            continue
        key = row['mode'], row['index'], row['phase']
        if key in indexed:
            raise ValueError(f'duplicate stage: {key}')
        indexed[key] = row
    expected = {(mode, index, phase) for mode in MODES
                for index in range(samples + 1) for phase in PHASES}
    if set(indexed) != expected:
        raise ValueError(f'incomplete run: missing {expected - indexed.keys()}, '
                         f'unexpected {indexed.keys() - expected}')
    for (_, index, _), row in indexed.items():
        if row['warmup'] != (index == 0) or row['worker_oom_kills'] != 0:
            raise ValueError('warmup labeling mismatch or worker OOM kill')
        if row['finished_us'] < row['started_us'] or row['elapsed_ms'] < 0:
            raise ValueError('invalid monotonic interval')
    report = {}
    for mode in MODES:
        measured = [indexed[mode, i, 'ready'] for i in range(1, samples + 1)]
        ram = [indexed[mode, i, 'memory-ready'] for i in range(1, samples + 1)]
        cleanup = [indexed[mode, i, 'cleanup']['elapsed_ms'] for i in range(1, samples + 1)]
        report[mode] = {
            'disk_result_ms': stats([r['elapsed_ms'] for r in measured]),
            # Includes the instrumentation gap between stages; same BEAM invocation.
            'ram_result_ms': stats([(m['finished_us'] - r['started_us']) / 1000
                                    for r, m in zip(measured, ram)]),
            'cleanup_ms': stats(cleanup),
            'worker_cpu_ms_to_ram': stats([(r['worker_cpu_us'] + m['worker_cpu_us']) / 1000
                                          for r, m in zip(measured, ram)]),
            'worker_peak_mib': stats([max(r['worker_memory_peak_bytes'], m['worker_memory_peak_bytes']) / 2**20
                                      for r, m in zip(measured, ram)]),
            'worker_baseline_mib': stats([r['worker_memory_before_bytes'] / 2**20 for r in measured]),
            'worker_disk_delta_mib': stats([(m['worker_disk_after_bytes'] - r['worker_disk_before_bytes']) / 2**20
                                            for r, m in zip(measured, ram)]),
            'worker_throttled_ms': stats([(r['worker_throttled_us'] + m['worker_throttled_us']) / 1000
                                          for r, m in zip(measured, ram)]),
        }
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rows', type=Path)
    parser.add_argument('--samples', type=int, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.rows.read_text().splitlines()]
    print(json.dumps(summarize(rows, args.samples), indent=2))
