"""The scenario runner must fail on wrong output, crashes, and unexpected gap changes."""
import contextlib
import io
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run  # noqa: E402


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "expected").mkdir()
        (self.root / "known_gaps").mkdir()
        self.binary = self.root / "fake-lua"
        # The fake interpreter prints the scale, or exits as the program text says.
        self.binary.write_text(f"""#!{sys.executable}
import sys
text = open(sys.argv[1]).read()
if "CRASH" in text:
    sys.stderr.write("boom happened\\n"); sys.exit(1)
if "SUCCEED" in text:
    print("GAP CLOSED"); sys.exit(0)
print("scale", sys.argv[2] if len(sys.argv) > 2 else "-")
""")
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IXUSR)

    def invoke(self, *argv):
        out = io.StringIO()
        with (patch.object(run, "ROOT", self.root), contextlib.redirect_stdout(out)):
            status = run.main(["--binary", str(self.binary), *argv])
        return status, out.getvalue()

    def program(self, name, body="ok"):
        (self.root / f"{name}.lua").write_text(body)

    def golden(self, name, scale, text):
        (self.root / "expected" / f"{name}.{scale}.txt").write_text(text)

    def test_matching_output_passes_both_scales(self):
        self.program("01_a")
        self.golden("01_a", "small", "scale small\n")
        self.golden("01_a", "large", "scale large\n")
        status, output = self.invoke("--no-gaps")
        self.assertEqual(status, 0, output)

    def test_output_difference_fails_and_is_located(self):
        self.program("01_a")
        self.golden("01_a", "small", "scale small\n")
        self.golden("01_a", "large", "scale WRONG\n")
        status, output = self.invoke("--no-gaps")
        self.assertEqual(status, 1)
        self.assertIn("line 1: got 'scale large', want 'scale WRONG'", output)

    def test_missing_golden_file_fails(self):
        self.program("01_a")
        status, output = self.invoke("--no-gaps", "--scale", "small")
        self.assertEqual(status, 1)
        self.assertIn("missing 01_a.small.txt", output)

    def test_nonzero_exit_fails_with_stderr(self):
        self.program("01_a", "CRASH")
        self.golden("01_a", "small", "")
        status, output = self.invoke("--no-gaps", "--scale", "small")
        self.assertEqual(status, 1)
        self.assertIn("boom happened", output)

    def test_known_gap_that_fails_as_recorded_is_xfail(self):
        self.program("01_a")
        self.golden("01_a", "small", "scale small\n")
        (self.root / "known_gaps" / "g.lua").write_text("-- KNOWN-GAP: boom happened\nCRASH")
        status, output = self.invoke("--scale", "small")
        self.assertEqual(status, 0, output)
        self.assertIn("XFAIL", output)

    def test_closed_gap_is_a_failure(self):
        self.program("01_a")
        self.golden("01_a", "small", "scale small\n")
        (self.root / "known_gaps" / "g.lua").write_text("-- KNOWN-GAP: boom\nSUCCEED")
        status, output = self.invoke("--scale", "small")
        self.assertEqual(status, 1)
        self.assertIn("XPASS", output)

    def test_gap_failing_for_another_reason_is_a_failure(self):
        self.program("01_a")
        self.golden("01_a", "small", "scale small\n")
        (self.root / "known_gaps" / "g.lua").write_text("-- KNOWN-GAP: something else\nCRASH")
        status, output = self.invoke("--scale", "small")
        self.assertEqual(status, 1)
        self.assertIn("not with 'something else'", output)


if __name__ == "__main__":
    unittest.main()
