"""Regression tests for official-suite process and failure accounting."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[2] / "bin/test_runner"


class RunnerTests(unittest.TestCase):
    def run_fixture(self, script, *options):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            interpreter = root / "interpreter"
            interpreter.write_text("#!/usr/bin/env python3\n" + script)
            interpreter.chmod(0o755)
            (root / "fixture.lua").write_text("-- fixture\n")
            report = root / "results.json"
            result = subprocess.run(
                [str(RUNNER), "--lua", str(interpreter), "--dir", directory,
                 "--json", str(report), "--timeout", "1", "--strict", *options],
                capture_output=True, text=True, timeout=10,
            )
            return result, json.loads(report.read_text()) if report.exists() else None

    def test_large_output_cannot_deadlock(self):
        result, report = self.run_fixture(
            "import sys\nsys.stdout.write('x' * 200000)\nsys.stderr.write('y' * 200000)\n"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(report["passed"], 1)

    def test_stderr_failure_is_preserved(self):
        result, report = self.run_fixture(
            "import sys\nprint('varis: intended failure', file=sys.stderr)\nsys.exit(3)\n"
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["failed"], 1)
        self.assertEqual(report["results"][0]["exit_code"], 3)
        self.assertEqual(report["results"][0]["diagnostic"], "varis: intended failure")

    def test_timeout_is_failure(self):
        result, report = self.run_fixture("import time\ntime.sleep(30)\n")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(report["results"][0]["status"], "TIMEOUT")
        self.assertIsNone(report["results"][0]["exit_code"])

    def test_empty_filter_is_not_success(self):
        result, report = self.run_fixture("pass\n", "--filter", "absent")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no tests matched", result.stderr)

    def test_zero_timeout_is_rejected(self):
        result, report = self.run_fixture("pass\n", "--timeout", "0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be positive", result.stderr)


if __name__ == "__main__":
    unittest.main()
