#!/usr/bin/env python3
"""Compares dlua with C Lua on the small application-style programs in benchmarks/workloads/.

Unlike bench.py (execution-only, assertion-checked core loops) these are whole-process timings:
each program runs in a fresh interpreter, the best of --runs is kept, and the printed output
must be identical. Ratios are informational; there is no failure threshold.
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def best_time(command, runs, timeout):
    best, output = None, None
    for _ in range(runs):
        start = time.perf_counter()
        proc = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
        elapsed = time.perf_counter() - start
        if proc.returncode:
            raise RuntimeError(f"{command[0]} exited {proc.returncode}: {proc.stderr[-500:]}")
        output = proc.stdout
        best = elapsed if best is None else min(best, elapsed)
    return best, output


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--c-lua", default="c-implementation/src/lua")
    ap.add_argument("--dlua", default="bin/dlua")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("names", nargs="*", help="workload names (default: all)")
    args = ap.parse_args(argv)
    programs = sorted((ROOT / "workloads").glob("*.lua"))
    if args.names:
        programs = [p for p in programs if p.stem in args.names]
    failed = False
    print(f"{'workload':<12} {'C Lua (s)':>10} {'dlua (s)':>10} {'ratio':>7}")
    for program in programs:
        try:
            c_time, c_out = best_time([args.c_lua, str(program)], args.runs, args.timeout)
            d_time, d_out = best_time([args.dlua, str(program)], args.runs, args.timeout)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"{program.stem:<12} FAIL {error}", file=sys.stderr)
            failed = True
            continue
        status = "" if c_out == d_out else "  OUTPUT DIFFERS"
        failed = failed or bool(status)
        print(f"{program.stem:<12} {c_time:>10.4f} {d_time:>10.4f} {d_time / c_time:>6.2f}x{status}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
