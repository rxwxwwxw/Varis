"""Behavioural tests of the case executors, using throwaway fake interpreters.

These pin the semantics inherited from the old runners (run-tests.sh, datalog/run.py,
extensions/run-tests.py, regression/run.py): rejection diagnostics, fallback markers, crash and timeout
handling, golden diffs, XFAIL/XPASS and ledger accounting.
"""
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from suite import kinds, model as M, runner  # noqa: E402


def fake(dirpath, body, name="fake"):
    p = Path(dirpath) / name
    p.write_text("#!/usr/bin/env python3\nimport sys, os, time\n" + textwrap.dedent(body))
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return p


class KindTests(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.d = Path(self._t.name)

    def tearDown(self):
        self._t.cleanup()

    def ctx(self, interp, ref=None):
        return kinds.Ctx(self.d, interp, ref)

    def case(self, kind, rel="p.lua", timeout=5, **params):
        return M.Case(id=f"s.{Path(rel).stem}", suite="s", kind=kind, timeout=timeout, params=dict(params, path=rel))

    def prog(self, rel="p.lua", content="x"):
        p = self.d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return rel

    def status(self, kind, case, interp, ref=None):
        return kinds.KINDS[kind](case, self.ctx(interp, ref))[0]

    # --- lua-ok / lua-reject
    def test_ok_exit_zero_passes_and_nonzero_fails(self):
        self.prog()
        self.assertEqual(self.status("lua-ok", self.case("lua-ok"), fake(self.d, "sys.exit(0)")).status, M.PASS)
        self.assertEqual(self.status("lua-ok", self.case("lua-ok"), fake(self.d, "sys.exit(1)", "f2")).status, M.FAIL)

    def test_timeout_is_not_a_pass(self):
        self.prog()
        r = self.status("lua-ok", self.case("lua-ok", timeout=0.3), fake(self.d, "time.sleep(10)"))
        self.assertEqual(r.status, M.TIMEOUT)

    def test_reject_requires_intended_diagnostic(self):
        self.prog()
        c = self.case("lua-reject", expect="negation cycle")
        good = fake(self.d, "sys.stderr.write('error: negation cycle in rules'); sys.exit(1)", "g")
        wrong = fake(self.d, "sys.stderr.write('error: something else'); sys.exit(1)", "w")
        fallback = fake(self.d, "sys.stderr.write('UNEXPECTED SUCCESS negation cycle'); sys.exit(1)", "u")
        succeeds = fake(self.d, "sys.exit(0)", "s")
        crash = fake(self.d, "os.kill(os.getpid(), 11)", "c")
        self.assertEqual(self.status("lua-reject", c, good).status, M.PASS)
        for bad in (wrong, fallback, succeeds, crash):
            self.assertEqual(self.status("lua-reject", c, bad).status, M.FAIL, bad.name)

    # --- golden
    def test_golden_compares_output_exactly(self):
        self.prog("t/01_x.lua")
        (self.d / "t/expected").mkdir()
        (self.d / "t/expected/01_x.small.txt").write_text("a\nb\n")
        c = self.case("golden", "t/01_x.lua", scale="small")
        self.assertEqual(self.status("golden", c, fake(self.d, "print('a'); print('b')")).status, M.PASS)
        r = self.status("golden", c, fake(self.d, "print('a'); print('c')", "f2"))
        self.assertEqual(r.status, M.FAIL)
        self.assertIn("line 2", r.detail)

    # --- known gaps
    def test_known_gap_xfail_xpass_and_wrong_reason(self):
        self.prog("g.lua", "-- KNOWN-GAP: not supported yet\n")
        c = self.case("known-gap", "g.lua")
        xfail = fake(self.d, "sys.stderr.write('x: not supported yet'); sys.exit(1)", "a")
        xpass = fake(self.d, "sys.exit(0)", "b")
        other = fake(self.d, "sys.stderr.write('boom'); sys.exit(1)", "c")
        self.assertEqual(self.status("known-gap", c, xfail).status, M.XFAIL)
        self.assertEqual(self.status("known-gap", c, xpass).status, M.XPASS)
        self.assertEqual(self.status("known-gap", c, other).status, M.FAIL)

    # --- extension cases
    def test_extension_marker_and_rejection(self):
        self.prog("c.lua", "-- body\n")
        self.prog("helpers.lua", "-- helpers\n")
        ok = fake(self.d, "print(open(sys.argv[1]).read().count('EXTENSION_CASE_COMPLETE') and 'EXTENSION_CASE_COMPLETE')", "ok")
        c = self.case("extension", "c.lua", helpers="helpers.lua")
        self.assertEqual(self.status("extension", c, ok).status, M.PASS)
        silent = fake(self.d, "pass", "silent")  # exit 0 but never reaches the completion marker
        self.assertEqual(self.status("extension", c, silent).status, M.FAIL)
        rej = self.case("extension", "c.lua", helpers="helpers.lua", expect="negation cycle")
        good = fake(self.d, "sys.stderr.write('negation cycle'); sys.exit(1)", "g")
        self.assertEqual(self.status("extension", rej, good).status, M.PASS)
        self.assertEqual(self.status("extension", rej, silent).status, M.FAIL)

    # --- differential
    def test_differential_output_and_checksum(self):
        self.prog("r/p.lua")
        (self.d / "r/expected.json").write_text(json.dumps({"p": "CHECKSUM 1 lines 1"}))
        c = self.case("differential", "r/p.lua", expected="r/expected.json")
        same = fake(self.d, "print('CHECKSUM 1 lines 1')", "same")
        diff = fake(self.d, "print('CHECKSUM 2 lines 1')", "diff")
        self.assertEqual(self.status("differential", c, same, same).status, M.PASS)
        self.assertEqual(self.status("differential", c, diff, same).status, M.FAIL)   # differs from reference
        self.assertEqual(self.status("differential", c, diff, diff).status, M.FAIL)   # wrong checksum


class LedgerTests(unittest.TestCase):
    def r(self, status, id="a.b"):
        return M.Result(id, "a", status)

    def test_unledgered_skip_and_partial_and_gap_fail(self):
        for s in (M.SKIP, M.PARTIAL, M.XFAIL):
            out = runner.apply_ledger([self.r(s)], {})
            self.assertEqual(out[0].status, M.FAIL)

    def test_ledgered_status_must_match(self):
        led = {"a.b": {"id": "a.b", "status": "skip"}}
        self.assertEqual(runner.apply_ledger([self.r(M.SKIP)], led)[0].status, M.SKIP)
        self.assertEqual(runner.apply_ledger([self.r(M.PARTIAL)], led)[0].status, M.FAIL)

    def test_stale_entry_is_reported(self):
        led = {"a.b": {"id": "a.b", "status": "skip"}}
        self.assertEqual(runner.apply_ledger([self.r(M.PASS)], led)[0].status, M.XPASS)


if __name__ == "__main__":
    unittest.main()
