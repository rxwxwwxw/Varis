"""Tests of target evaluation, derivation and the trailer hook (no interpreters needed)."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))

from suite import bench as B  # noqa: E402


def rec(group="core", **ratios):
    return {"id": f"{group}.x", "group": group, "ratios": {k: {"median": v, "rss": 1.0} for k, v in ratios.items()},
            "binaries": {}}


class Evaluate(unittest.TestCase):
    def test_goal_miss_is_not_a_hard_failure(self):
        f = B.evaluate(rec(clua=2.5), {"goal": {"clua": 2.0}})
        self.assertFalse(f[0]["ok"])
        self.assertFalse(B.hard_failed(f))

    def test_gate_exceeded_is_hard(self):
        f = B.evaluate(rec(clua=2.5), {"gate": {"clua": 2.2}})
        self.assertTrue(B.hard_failed(f))
        self.assertFalse(B.hard_failed(B.evaluate(rec(clua=2.1), {"gate": {"clua": 2.2}})))

    def test_floor_is_a_minimum_speedup(self):
        t = {"floor": {"v0-snapshot": 15.0}}
        self.assertTrue(B.hard_failed(B.evaluate(rec(**{"v0-snapshot": 1 / 10}), t)))     # only 10x faster
        self.assertFalse(B.hard_failed(B.evaluate(rec(**{"v0-snapshot": 1 / 20}), t)))    # 20x faster

    def test_missing_comparator_is_unknown_not_pass_or_fail(self):
        f = B.evaluate(rec(), {"gate": {"clua": 2.0}})
        self.assertIsNone(f[0]["ok"])
        self.assertFalse(B.hard_failed(f))


class Loaded(unittest.TestCase):
    def test_clua_gate_failure_is_inconclusive_under_load(self):
        r = rec(clua=3.0, **{"v1-perf-final": 1.5})
        r["loaded"] = True
        f = B.evaluate(r, {"gate": {"clua": 2.2, "v1-perf-final": 1.2}})
        by = {x["label"]: x for x in f}
        self.assertIsNone(by["clua"]["ok"])
        self.assertFalse(by["v1-perf-final"]["ok"])      # same-toolchain ratios are still enforced
        self.assertTrue(B.hard_failed(f))
        r["ratios"]["v1-perf-final"]["median"] = 1.0
        self.assertFalse(B.hard_failed(B.evaluate(r, {"gate": {"clua": 2.2, "v1-perf-final": 1.2}})))

    def test_unloaded_clua_gate_still_fails(self):
        r = rec(clua=3.0)
        self.assertTrue(B.hard_failed(B.evaluate(r, {"gate": {"clua": 2.2}})))


class Derive(unittest.TestCase):
    def test_core_headroom_and_goal(self):
        t = B.derive(rec(clua=1.9))
        self.assertEqual(t["goal"]["clua"], 2.0)
        self.assertAlmostEqual(t["gate"]["clua"], 2.19, places=2)  # 1.9*1.10 + 0.10 slack

    def test_non_core_gets_larger_headroom(self):
        t = B.derive(rec(group="programs", clua=1.0))
        self.assertAlmostEqual(t["gate"]["clua"], 1.3, places=2)

    def test_floor_is_sixty_percent_of_measured_speedup(self):
        t = B.derive(rec(**{"v0-snapshot": 1 / 25}))
        self.assertEqual(t["floor"]["v0-snapshot"], 15.0)


class Trailer(unittest.TestCase):
    def test_loosening_rules(self):
        sys.path.insert(0, str(ROOT / "tools/hooks"))
        import trailer_check as T
        old = {"workload": {"a": {"gate": {"clua": 2.0}, "floor": {"v0": 10.0}}}}
        self.assertFalse(T.targets_loosened(old, {"workload": {"a": {"gate": {"clua": 1.8}, "floor": {"v0": 12.0}}}}))
        self.assertTrue(T.targets_loosened(old, {"workload": {"a": {"gate": {"clua": 2.3}, "floor": {"v0": 10.0}}}}))
        self.assertTrue(T.targets_loosened(old, {"workload": {"a": {"gate": {"clua": 2.0}, "floor": {"v0": 5.0}}}}))
        self.assertTrue(T.targets_loosened(old, {"workload": {"a": {"gate": {}, "floor": {"v0": 10.0}}}}))


class Report(unittest.TestCase):
    def test_report_renders_counts_ledger_and_status(self):
        import json
        from suite import cli
        with tempfile.TemporaryDirectory() as d:
            tests = Path(d) / "t.json"
            tests.write_text(json.dumps({"tier": "full", "commit": "abc", "machine": "m", "wall_seconds": 1,
                                         "counts": {"pass": 1, "skip": 1},
                                         "results": [{"id": "unit.a", "status": "pass", "detail": ""},
                                                     {"id": "official.gc", "status": "skip", "detail": "excluded"}]}))
            bench = Path(d) / "b.json"
            bench.write_text(json.dumps({"commit": "abc", "machine": "m", "toolchain": "ldc", "records": [
                {"id": "core.fib", "group": "core", "binaries": {"candidate": {"median": 0.1}},
                 "ratios": {"clua": {"median": 2.5, "rss": 1.0}}}]}))
            out = Path(d) / "S.md"
            rc = cli.main(["report", "--tests", str(tests), "--bench", str(bench), "--out", str(out)])
            text = out.read_text()
        self.assertEqual(rc, 0)
        self.assertIn("official.gc", text)
        self.assertIn("`core.fib`", text)
        self.assertIn("2.50×", text)


if __name__ == "__main__":
    unittest.main()
