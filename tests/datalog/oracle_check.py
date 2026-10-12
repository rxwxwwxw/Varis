#!/usr/bin/env python3
"""Run relational programs with the naive evaluator checking every query.

    python3 tests/datalog/oracle_check.py <varis binary>

With VARIS_LOGIC_ORACLE=1 the runtime answers each query twice, once with the evaluator in
source/varis/logic/evaluate.d and once with the reference in source/varis/logic/naive.d, and
raises "logic oracle mismatch" when the result sets differ (benchmarks/PERFORMANCE_PLAN.md §7).
Programs whose guards have side effects are not suitable: guards run twice under the oracle.
"""
import glob
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    env = dict(os.environ, VARIS_LOGIC_ORACLE="1")
    runs = []
    for path in sorted(glob.glob(str(ROOT / "tests/datalog/[0-9][0-9]_*.lua"))):
        runs.append(([binary, path, "small"], pathlib.Path(path).parent))
    for path in sorted(glob.glob(str(ROOT / "tests/datalog/acceptance/positive/*.lua"))):
        runs.append(([binary, path], ROOT))
    runs.append(([binary, "tools/check.lua"], ROOT / "sample-game"))
    runs.append(([binary, "tools/golden.lua"], ROOT / "sample-game"))
    runs.append(([binary, "benchmarks/experiments/synthetic_game.lua", "5", "60", "1", "6", "10"], ROOT))
    failed = 0
    for cmd, cwd in runs:
        proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, timeout=300)
        if proc.returncode != 0:
            failed += 1
            sys.stderr.write(f"FAILED {' '.join(cmd[1:])}\n{proc.stderr.decode('utf-8', 'replace')[-600:]}\n")
    if len(runs) < 30:
        sys.stderr.write(f"only {len(runs)} programs found\n")
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
