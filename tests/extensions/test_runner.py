"""Exercise timeout and rejection handling with small synthetic interpreters."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("extension_runner", Path(__file__).with_name("run-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def run_fake(self, body, negative=False, timeout=5):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "fake-interpreter"
            binary.write_text("#!/usr/bin/env python3\n" + body + "\n")
            binary.chmod(0o755)
            name = "negative_self_negation" if negative else "zero_arity"
            return runner.run_case(str(binary), runner.ROOT / "cases" / (name + ".lua"), timeout)

    def test_success_requires_completion_marker(self):
        self.assertTrue(self.run_fake('print("EXTENSION_CASE_COMPLETE")')[0])
        self.assertFalse(self.run_fake('print("early exit")')[0])

    def test_negative_requires_correct_diagnostic(self):
        self.assertTrue(self.run_fake('import sys; print("negation cycle"); sys.exit(1)', True)[0])
        self.assertFalse(self.run_fake('import sys; print("syntax error"); sys.exit(1)', True)[0])
        self.assertFalse(self.run_fake('print("negation cycle")', True)[0])
        self.assertFalse(self.run_fake('import sys; print("negation cycle UNEXPECTED SUCCESS"); sys.exit(1)', True)[0])

    def test_crash_is_not_expected_rejection(self):
        self.assertFalse(self.run_fake('import os, signal; print("negation cycle", flush=True); os.kill(os.getpid(), signal.SIGKILL)', True)[0])

    def test_timeout_is_failure_even_with_matching_output(self):
        passed, elapsed, output = self.run_fake('import time; print("negation cycle", flush=True); time.sleep(60)', True, 0.1)
        self.assertFalse(passed)
        self.assertIn("timed out", output)
        self.assertLess(elapsed, 5)


if __name__ == "__main__":
    unittest.main()
