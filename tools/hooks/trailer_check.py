#!/usr/bin/env python3
"""commit-msg check: loosened gates/ledger entries must carry an acceptance trailer.

benchmarks/targets.toml: a gate.* or floor.* value moved in the permissive direction
(gate up, floor down) needs `Perf-Regression-Accepted: <reason>`.
tests/manifest.toml: a [[ledger]] entry added needs `Skip-Accepted: <reason>`.
"""
import re
import subprocess
import sys

msg = open(sys.argv[1]).read()


def staged_diff(path):
    return subprocess.run(["git", "diff", "--cached", "-U0", "--", path], capture_output=True, text=True).stdout


def num(line):
    m = re.match(r"[-+]\s*((?:gate|floor)\.[\w.-]+)\s*=\s*([0-9.]+)", line)
    return (m.group(1), float(m.group(2))) if m else None


def loosened(diff):
    old, new = {}, {}
    for line in diff.splitlines():
        r = num(line)
        if r:
            (old if line.startswith("-") else new)[r[0]] = r[1]
    for k, v in new.items():
        if k in old and ((k.startswith("gate.") and v > old[k]) or (k.startswith("floor.") and v < old[k])):
            return True
    return False


problems = []
if loosened(staged_diff("benchmarks/targets.toml")) and "Perf-Regression-Accepted:" not in msg:
    problems.append("benchmarks/targets.toml loosened: add a 'Perf-Regression-Accepted: <reason>' trailer")
ledger = staged_diff("tests/manifest.toml")
if re.search(r"^\+\[\[ledger\]\]", ledger, re.M) and "Skip-Accepted:" not in msg:
    problems.append("tests/manifest.toml ledger entry added: add a 'Skip-Accepted: <reason>' trailer")
for p in problems:
    print(p, file=sys.stderr)
raise SystemExit(1 if problems else 0)
