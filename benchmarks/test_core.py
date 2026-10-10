"""Core performance runner correctness and acceptance-gate tests."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import bench


class CoreBenchTests(unittest.TestCase):
    def test_median_preserves_samples(self):
        summary = bench.summarize([8, 1, 3])
        self.assertEqual(summary['median'], 3)
        self.assertEqual(summary['samples'], [8, 1, 3])

    def test_process_failure_is_not_a_timing(self):
        from subprocess import CompletedProcess
        with patch.object(bench.subprocess, 'run', return_value=CompletedProcess([], 1, '', 'bad assertion')):
            with self.assertRaisesRegex(RuntimeError, 'bad assertion'):
                bench.measure('fake', 'assert(false)', 1, 5)

    def test_alternating_order_and_per_workload_gate(self):
        order = []
        def measure(binary, *args):
            order.append(binary)
            return (3 if binary == 'd' else 1), .01, 4
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            with patch.object(bench, 'identity', return_value={}), patch.object(bench, 'measure', side_effect=measure):
                result = bench.main(['--c-lua', 'c', '--dlua', 'd', '--runs', '2',
                                     '--only', 'numeric_for_loop', '--max-ratio', '2', '--json', str(output)])
            self.assertEqual(result, 1)
            self.assertEqual(order, ['c', 'd', 'd', 'c'])
            self.assertEqual(json.loads(output.read_text())['workloads']['numeric_for_loop']['ratio'], 3)

    def test_timeout_fails_and_records_error(self):
        import subprocess
        with patch.object(bench, 'identity', return_value={}), patch.object(bench, 'measure', side_effect=subprocess.TimeoutExpired('fake', 1)):
            self.assertEqual(bench.main(['--runs', '1', '--only', 'numeric_for_loop']), 1)


if __name__ == '__main__':
    unittest.main()
