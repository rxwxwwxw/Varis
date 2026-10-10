#!/usr/bin/env python3
"""Differential regression suite: every program must produce byte-identical output
(including its CHECKSUM line) under the C Lua reference and varis, and must match the
checksum recorded in expected.json when present."""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
C_LUA = ROOT / "c-implementation/src/lua"
D_LUA = ROOT / "bin/varis"


def programs(selection=None):
    names = sorted(p for p in HERE.glob("*.lua") if p.name != "harness.lua")
    if selection:
        names = [p for p in names if p.stem in selection]
    return names


def run(binary, program, timeout):
    start = time.perf_counter()
    proc = subprocess.run([str(binary), program.name], cwd=HERE, capture_output=True, timeout=timeout,
                          stdin=subprocess.DEVNULL)
    return proc, time.perf_counter() - start


def checksum_of(output):
    for line in reversed(output.decode(errors="replace").splitlines()):
        if line.startswith("CHECKSUM "):
            return line
    return None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("programs", nargs="*", help="program names without .lua (default: all)")
    ap.add_argument("--timeout", type=float, default=60.0, help="seconds per program and interpreter")
    ap.add_argument("--record", action="store_true", help="write expected.json from the reference run")
    ap.add_argument("--no-reference", action="store_true", help="compare varis with expected.json only")
    args = ap.parse_args(argv)

    expected_path = HERE / "expected.json"
    expected = json.loads(expected_path.read_text()) if expected_path.exists() else {}
    recorded = {}
    failures = 0
    for program in programs(args.programs):
        problems = []
        d_proc, d_time = run(D_LUA, program, args.timeout)
        line = checksum_of(d_proc.stdout)
        if d_proc.returncode != 0 or line is None:
            problems.append(f"varis exit {d_proc.returncode}: {d_proc.stderr.decode(errors='replace')[-300:]}")
        c_time = None
        if not args.no_reference:
            c_proc, c_time = run(C_LUA, program, args.timeout)
            if c_proc.returncode != 0:
                problems.append(f"reference exit {c_proc.returncode}: {c_proc.stderr.decode(errors='replace')[-300:]}")
            elif c_proc.stdout != d_proc.stdout:
                c_lines = c_proc.stdout.decode(errors="replace").splitlines()
                d_lines = d_proc.stdout.decode(errors="replace").splitlines()
                for i, (a, b) in enumerate(zip(c_lines, d_lines)):
                    if a != b:
                        problems.append(f"line {i + 1} differs:\n    C Lua: {a}\n    varis : {b}")
                        break
                else:
                    problems.append(f"output length differs ({len(c_lines)} vs {len(d_lines)} lines)")
            line = line or checksum_of(c_proc.stdout)
        name = program.stem
        if line is not None:
            recorded[name] = line
            if name in expected and expected[name] != line and not args.record:
                problems.append(f"checksum {line} != expected {expected[name]}")
        status = "FAIL" if problems else "PASS"
        failures += bool(problems)
        timing = f"varis {d_time:6.2f}s" + (f"  C {c_time:6.2f}s" if c_time is not None else "")
        print(f"[{status}] {name:<22} {timing}  {line or ''}")
        for p in problems:
            print("    " + p)
    if args.record and not failures:
        merged = dict(expected)
        merged.update(recorded)
        expected_path.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(f"recorded {len(recorded)} checksums in {expected_path.name}")
    print(f"{len(recorded) - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
