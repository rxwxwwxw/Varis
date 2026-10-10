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


if __name__ == "__main__":
    unittest.main()
