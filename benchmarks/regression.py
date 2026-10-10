#!/usr/bin/env python3
"""Times the regression programs under C Lua and dlua and verifies, on every run, that both
produce identical output and the checksum recorded in tests/regression/expected.json.

A program fails the benchmark when the outputs differ, a checksum changes, a process fails, or
dlua needs more than --budget seconds (default 30) -- the programs must terminate in a
reasonable time. Ratios are reported per program; they are not enforced here (see
benchmarks/README.md)."""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGRESSION = ROOT / "tests/regression"
C_LUA = ROOT / "c-implementation/src/lua"
D_LUA = ROOT / "bin/dlua"


def timed(binary, program, timeout):
    start = time.perf_counter()
    proc = subprocess.run([str(binary), program.name], cwd=REGRESSION, capture_output=True,
                          timeout=timeout, stdin=subprocess.DEVNULL)
    return proc, time.perf_counter() - start


def checksum_line(output):
    for line in reversed(output.decode(errors="replace").splitlines()):
        if line.startswith("CHECKSUM "):
            return line
    return None


def measure(program, runs, timeout):
    """Returns (problem or None, c_seconds, dlua_seconds) using the best of `runs` runs."""
    expected = json.loads((REGRESSION / "expected.json").read_text()).get(program.stem)
    c_best = d_best = None
    c_out = d_out = None
    for _ in range(runs):
        c_proc, c_time = timed(C_LUA, program, timeout)
        d_proc, d_time = timed(D_LUA, program, timeout)
        if c_proc.returncode != 0:
            return f"C Lua exited with {c_proc.returncode}", None, None
        if d_proc.returncode != 0:
            return f"dlua exited with {d_proc.returncode}: {d_proc.stderr.decode(errors='replace')[-200:]}", None, None
        c_out, d_out = c_proc.stdout, d_proc.stdout
        if c_out != d_out:
            return "output differs between C Lua and dlua", c_time, d_time
        c_best = c_time if c_best is None else min(c_best, c_time)
        d_best = d_time if d_best is None else min(d_best, d_time)
    line = checksum_line(d_out)
    if expected is not None and line != expected:
        return f"checksum {line} != expected {expected}", c_best, d_best
    return None, c_best, d_best


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--budget", type=float, default=30.0, help="maximum dlua seconds per program")
    ap.add_argument("--timeout", type=float, default=120.0)
    args = ap.parse_args(argv)
    programs = sorted(p for p in REGRESSION.glob("*.lua") if p.name != "harness.lua")
    print("=" * 80)
    print(f"{'Regression programs (identical output + checksum, dlua vs C Lua)':^80}")
    print("=" * 80)
    print(f"{'Program':<22} | {'C Lua (s)':>10} | {'dlua (s)':>10} | {'Ratio':>8} | Result")
    print("-" * 80)
    failed = False
    for program in programs:
        problem, c_time, d_time = measure(program, args.runs, args.timeout)
        if problem is None and d_time > args.budget:
            problem = f"dlua took {d_time:.1f}s (budget {args.budget:.0f}s)"
        if c_time is None:
            print(f"{program.stem:<22} | {'-':>10} | {'-':>10} | {'-':>8} | FAIL: {problem}")
            failed = True
            continue
        ratio = d_time / c_time if c_time > 0 else float("inf")
        status = "ok" if problem is None else f"FAIL: {problem}"
        failed |= problem is not None
        print(f"{program.stem:<22} | {c_time:10.3f} | {d_time:10.3f} | {ratio:7.1f}x | {status}")
    print("-" * 80)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
