import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("regression_run", HERE / "run.py")
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)


def fake_interpreter(directory, name, body):
    path = Path(directory) / name
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.saved = (run.C_LUA, run.D_LUA, run.HERE)
        self.addCleanup(lambda: setattr(run, "C_LUA", self.saved[0]) or setattr(run, "D_LUA", self.saved[1])
                        or setattr(run, "HERE", self.saved[2]))
        self.suite = Path(self.tmp.name) / "suite"
        self.suite.mkdir()
        (self.suite / "prog.lua").write_text("-- placeholder\n")
        run.HERE = self.suite

    def go(self, c_body, d_body, expected=None, *extra):
        run.C_LUA = fake_interpreter(self.tmp.name, "c", c_body)
        run.D_LUA = fake_interpreter(self.tmp.name, "d", d_body)
        if expected is not None:
            (self.suite / "expected.json").write_text(json.dumps(expected))
        out = io.StringIO()
        with redirect_stdout(out):
            code = run.main(list(extra))
        return code, out.getvalue()

    def test_identical_output_passes(self):
        body = "echo hello\necho 'CHECKSUM 00000000000000aa lines 1'\n"
        code, text = self.go(body, body)
        self.assertEqual(code, 0, text)

    def test_difference_is_reported_with_the_line(self):
        code, text = self.go("echo one\necho 'CHECKSUM 1 lines 1'\n", "echo two\necho 'CHECKSUM 1 lines 1'\n")
        self.assertEqual(code, 1)
        self.assertIn("line 1 differs", text)

    def test_checksum_must_match_expected(self):
        body = "echo 'CHECKSUM 00000000000000aa lines 0'\n"
        code, text = self.go(body, body, {"prog": "CHECKSUM 00000000000000bb lines 0"})
        self.assertEqual(code, 1)
        self.assertIn("!= expected", text)

    def test_failing_interpreter_is_a_failure(self):
        code, text = self.go("exit 0\n", "echo boom >&2\nexit 3\n")
        self.assertEqual(code, 1)
        self.assertIn("dlua exit 3", text)

    def test_record_writes_expected_file(self):
        body = "echo 'CHECKSUM 00000000000000cc lines 0'\n"
        code, _ = self.go(body, body, None, "--record")
        self.assertEqual(code, 0)
        data = json.loads((self.suite / "expected.json").read_text())
        self.assertEqual(data["prog"], "CHECKSUM 00000000000000cc lines 0")


if __name__ == "__main__":
    unittest.main()
