#!/usr/bin/env python3
"""Time the real Datalog acceptance, extension and scenario suites and enforce a baseline."""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = Path(__file__).with_name("datalog-baseline.json")


def regression_limit(seconds, tolerance, slack):
    return seconds * (1 + tolerance) + slack


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "bin/dlua")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--record", action="store_true",
                        help="explicitly replace the baseline after successful tests")
    parser.add_argument("--record-suite", action="append", default=[], metavar="NAME",
                        choices=["acceptance", "extensions", "scenarios"],
                        help="replace (or add) only this suite's baseline entry after a "
                             "successful run; other entries are compared, never rewritten")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--tolerance", type=float, default=0.25,
                        help="allowed fractional slowdown (default: 0.25)")
    parser.add_argument("--slack", type=float, default=0.1,
                        help="additional noise allowance in seconds (default: 0.1)")
    parser.add_argument("--timeout", type=float, default=300,
                        help="hard timeout per complete suite")
    args = parser.parse_args()
    if (args.runs < 1 or not all(math.isfinite(v) for v in
                               (args.tolerance, args.slack, args.timeout))
            or args.tolerance < 0 or args.slack < 0 or args.timeout <= 0):
        parser.error("runs/timeout must be positive; tolerance/slack must be nonnegative")
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"not an executable: {binary}")
    baseline = None
    if not args.record:
        try:
            baseline = json.loads(args.baseline.read_text())
        except (OSError, ValueError) as error:
            parser.error(f"cannot read baseline: {error}; use --record to calibrate")
    suites = {
        "acceptance": ["sh", "lua54_datalog_tests/run-tests.sh", str(binary)],
        "extensions": [sys.executable, "tests/extensions/run-tests.py", str(binary)],
        # The 19 scenario programs at benchmark scale (golden output checked).
        "scenarios": [sys.executable, "tests/datalog/run.py", "--binary", str(binary),
                      "--scale", "large", "--no-gaps"],
    }
    measured = {}
    for name, command in suites.items():
        samples = []
        for run in range(args.runs):
            started = time.perf_counter()
            try:
                with subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True,
                                      start_new_session=True) as process:
                    try:
                        stdout, stderr = process.communicate(timeout=args.timeout)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.communicate(timeout=2)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.communicate()
                        raise
                    result = subprocess.CompletedProcess(command, process.returncode,
                                                         stdout, stderr)
            except subprocess.TimeoutExpired:
                print(f"FAIL {name}: suite exceeded {args.timeout:g}s", file=sys.stderr)
                return 1
            elapsed = time.perf_counter() - started
            if result.returncode != 0:
                print(result.stdout + result.stderr, file=sys.stderr)
                print(f"FAIL {name}: functional tests failed", file=sys.stderr)
                return 1
            samples.append(elapsed)
            print(f"{name} run {run + 1}: {elapsed:.4f}s", flush=True)
            if name == "scenarios" and run == 0:
                print(result.stdout, end="", flush=True)   # per-program timings
        measured[name] = {"median_seconds": statistics.median(samples),
                          "samples_seconds": samples}
    if args.record:
        args.baseline.write_text(json.dumps({
            "schema": 1, "platform": platform.platform(),
            "machine": platform.machine(), "runs": args.runs,
            "suites": measured,
        }, indent=2) + "\n")
        print(f"Recorded baseline: {args.baseline}")
        return 0
    failed = False
    recording = set(args.record_suite)
    missing = [name for name in measured
               if name not in baseline["suites"] and name not in recording]
    if missing:
        print(f"FAIL: baseline has no entry for {', '.join(missing)}; calibrate "
              "with --record-suite NAME (or everything with --record)", file=sys.stderr)
        return 1
    for name, measurement in measured.items():
        if name in recording:
            continue
        previous = baseline["suites"][name]["median_seconds"]
        limit = regression_limit(previous, args.tolerance, args.slack)
        current = measurement["median_seconds"]
        passed = current <= limit
        failed |= not passed
        print(f"{'PASS' if passed else 'REGRESSION'} {name}: median {current:.4f}s; "
              f"baseline {previous:.4f}s; limit {limit:.4f}s")
    if recording:
        for name in sorted(recording):
            baseline["suites"][name] = measured[name]
            print(f"Recorded suite {name}: median {measured[name]['median_seconds']:.4f}s")
        args.baseline.write_text(json.dumps(baseline, indent=2) + "\n")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
