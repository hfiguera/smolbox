import unittest
from summarize import summarize, stats, MODES, PHASES


class SummaryTests(unittest.TestCase):
    def rows(self):
        return [dict(mode=m, phase=p, index=i, success=True, warmup=i == 0,
                     elapsed_ms=2, started_us=1000 if p == 'ready' else 4000,
                     finished_us=3000 if p == 'ready' else 6000,
                     worker_oom_kills=0, worker_cpu_us=500, worker_throttled_us=0,
                     worker_memory_peak_bytes=2**20, worker_memory_before_bytes=0,
                     worker_disk_after_bytes=2**20, worker_disk_before_bytes=0)
                for m in MODES for i in range(3) for p in PHASES]

    def test_empirical_percentile(self):
        self.assertEqual(stats(list(range(1, 21))),
                         dict(n=20, median=10.5, p95=19, min=1, max=20))

    def test_elapsed_includes_instrumentation_gap_and_excludes_warmup(self):
        rows = self.rows()
        rows[0]['elapsed_ms'] = 10000
        result = summarize(rows, 2)['fresh']
        self.assertEqual(result['disk_result_ms']['median'], 2)
        self.assertEqual(result['ram_result_ms']['median'], 5)
        self.assertEqual(result['ram_result_ms']['n'], 2)

    def test_missing_duplicate_failed_and_oom_are_rejected(self):
        rows = self.rows()
        for bad in [rows[:-1], rows + [rows[0]],
                    [dict(rows[0], success=False)] + rows[1:],
                    [dict(rows[0], worker_oom_kills=1)] + rows[1:]]:
            with self.assertRaises(ValueError):
                summarize(bad, 2)


if __name__ == '__main__':
    unittest.main()
