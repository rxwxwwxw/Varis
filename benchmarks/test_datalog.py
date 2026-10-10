"""Regression enforcement must fail closed without silently moving its baseline."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import datalog


class DatalogBenchmarkTests(unittest.TestCase):
    def check_acceptance_rejections(self, crash):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "fake-lua"
            binary.write_text(f"#!{sys.executable}\n" + """
import os, signal, sys
name = os.path.basename(sys.argv[1])
messages = {
    '13_unsafe_negation.lua': "variable '?x' in rule head is not bound",
    '14_negation_cycle.lua': 'negation cycle',
    '15_relation_arity_mismatch.lua': "relation 'edge' expects arity 2, got 1",
}
if name in messages:
    print(messages[name] if CRASH else 'unrelated parse error', flush=True)
    if CRASH:
        os.kill(os.getpid(), signal.SIGKILL)
    sys.exit(1)
""".replace("CRASH", repr(crash)))
            binary.chmod(0o755)
            result = subprocess.run(
                ["sh", str(datalog.ROOT / "lua54_datalog_tests/run-tests.sh"), str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("12 passed, 3 failed", result.stdout)

    def test_acceptance_rejects_unrelated_errors(self):
        self.check_acceptance_rejections(crash=False)

    def test_acceptance_rejects_crash_after_expected_diagnostic(self):
        self.check_acceptance_rejections(crash=True)

    def run_benchmark(self, durations, returncode=0, record=False, timeout=False,
                      suites=("acceptance", "extensions", "scenarios"), extra=()):
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.json"
            original = json.dumps({"schema": 1, "suites": {
                name: {"median_seconds": 1.0}
                for name in suites}})
            baseline.write_text(original)
            process = MagicMock()
            process.__enter__.return_value = process
            process.returncode = returncode
            process.pid = 12345
            process.communicate.return_value = ("test output", "")
            if timeout:
                process.communicate.side_effect = [subprocess.TimeoutExpired("suite", 1),
                                                   ("", "")]
            argv = ["datalog.py", "--binary", sys.executable,
                    "--baseline", str(baseline), "--runs", "3"]
            if record:
                argv.append("--record")
            argv.extend(extra)
            ticks = [tick for duration in durations for tick in (0, duration)]
            with (patch.object(sys, "argv", argv),
                  patch.object(datalog.subprocess, "Popen", return_value=process),
                  patch.object(datalog.time, "perf_counter", side_effect=ticks),
                  patch.object(datalog.os, "killpg") as kill,
                  contextlib.redirect_stdout(io.StringIO()),
                  contextlib.redirect_stderr(io.StringIO())):
                status = datalog.main()
            return status, original, baseline.read_text(), kill.called

    def test_median_ignores_one_scheduling_outlier(self):
        status, original, after, _ = self.run_benchmark([1, 20, 1, 1, 1, 1, 1, 1, 1])
        self.assertEqual(status, 0)
        self.assertEqual(after, original)

    def test_slowdown_fails_without_changing_baseline(self):
        status, original, after, _ = self.run_benchmark([1.36] * 9)
        self.assertEqual(status, 1)
        self.assertEqual(after, original)

    def test_failed_tests_cannot_record_baseline(self):
        status, original, after, _ = self.run_benchmark([1], returncode=1, record=True)
        self.assertEqual(status, 1)
        self.assertEqual(after, original)

    def test_explicit_record_saves_measurements(self):
        status, _, after, _ = self.run_benchmark([1, 2, 3, 4, 5, 6, 7, 8, 9], record=True)
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(after)["suites"]["acceptance"]["median_seconds"], 2)
        self.assertEqual(json.loads(after)["suites"]["extensions"]["median_seconds"], 5)
        self.assertEqual(json.loads(after)["suites"]["scenarios"]["median_seconds"], 8)

    def test_unrecorded_suite_fails_closed(self):
        status, original, after, _ = self.run_benchmark(
            [1] * 9, suites=("acceptance", "extensions"))
        self.assertEqual(status, 1)
        self.assertEqual(after, original)

    def test_record_suite_replaces_only_that_suite(self):
        status, _, after, _ = self.run_benchmark(
            [1, 1, 1, 1, 1, 1, 7, 8, 9], suites=("acceptance", "extensions"),
            extra=["--record-suite", "scenarios"])
        recorded = json.loads(after)["suites"]
        self.assertEqual(status, 0)
        self.assertEqual(recorded["acceptance"]["median_seconds"], 1.0)   # untouched
        self.assertEqual(recorded["extensions"]["median_seconds"], 1.0)   # untouched
        self.assertEqual(recorded["scenarios"]["median_seconds"], 8)

    def test_record_suite_still_reports_other_regressions(self):
        status, _, after, _ = self.run_benchmark(
            [3, 3, 3, 1, 1, 1, 7, 8, 9], suites=("acceptance", "extensions"),
            extra=["--record-suite", "scenarios"])
        recorded = json.loads(after)["suites"]
        self.assertEqual(status, 1)                                       # acceptance slow
        self.assertEqual(recorded["acceptance"]["median_seconds"], 1.0)   # not rewritten
        self.assertEqual(recorded["scenarios"]["median_seconds"], 8)

    def test_timeout_fails_and_kills_descendants(self):
        status, original, after, killed = self.run_benchmark([1], timeout=True)
        self.assertEqual(status, 1)
        self.assertEqual(after, original)
        self.assertTrue(killed)


if __name__ == "__main__":
    unittest.main()
