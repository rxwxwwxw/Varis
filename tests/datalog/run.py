#!/usr/bin/env python3
"""Run the Datalog scenario programs and compare their output with the golden files.

Every program NN_name.lua is run as `dlua NN_name.lua <scale>` for scale `small`
(hand-checkable sizes) and `large` (benchmark sizes), in a fresh process.  Its
stdout must equal expected/NN_name.<scale>.txt exactly and the exit status must
be zero.  Programs in known_gaps/ document spec features the interpreter does
not yet provide: they are expected to fail with the diagnostic named in their
`-- KNOWN-GAP:` line, are reported as XFAIL, and turn into a failure (XPASS)
as soon as they succeed, so the gap cannot silently close or silently change.

    python3 tests/datalog/run.py                     # everything
    python3 tests/datalog/run.py --scale large 03    # name filter + one scale
    python3 tests/datalog/run.py --record            # rewrite golden files
"""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SCALES = ("small", "large")


def programs(filters):
    found = sorted(p for p in ROOT.glob("[0-9][0-9]_*.lua"))
    if filters:
        found = [p for p in found if any(f in p.name for f in filters)]
    return found


def known_gaps(filters):
    found = sorted((ROOT / "known_gaps").glob("*.lua"))
    if filters:
        found = [p for p in found if any(f in p.name for f in filters)]
    return found


def execute(binary, program, scale, timeout):
    """Returns (returncode or None on timeout, combined stdout, stderr, seconds)."""
    command = [str(binary), str(program)] + ([scale] if scale else [])
    started = time.perf_counter()
    with subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True) as proc:
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            return None, b"", b"", time.perf_counter() - started
    return proc.returncode, out, err, time.perf_counter() - started


def first_difference(got, want):
    got_lines, want_lines = got.splitlines(), want.splitlines()
    for number, (g, w) in enumerate(zip(got_lines, want_lines), 1):
        if g != w:
            return f"line {number}: got {g!r}, want {w!r}"
    return f"got {len(got_lines)} lines, want {len(want_lines)}"


def run_program(binary, program, scale, timeout, record):
    golden = ROOT / "expected" / f"{program.stem}.{scale}.txt"
    code, out, err, seconds = execute(binary, program, scale, timeout)
    if code is None:
        return False, seconds, f"timed out after {timeout:g}s"
    if code != 0:
        return False, seconds, "exit status %d: %s" % (
            code, err.decode(errors="replace").strip().splitlines()[0] if err.strip() else "")
    text = out.decode(errors="replace")
    if record:
        golden.parent.mkdir(exist_ok=True)
        golden.write_text(text)
        return True, seconds, "recorded"
    if not golden.exists():
        return False, seconds, f"missing {golden.name} (use --record)"
    want = golden.read_text()
    if text != want:
        return False, seconds, first_difference(text, want)
    return True, seconds, ""


def run_gap(binary, program, timeout):
    """Returns (status, detail) with status XFAIL (good), XPASS or FAIL."""
    marker = re.search(r"^-- KNOWN-GAP: (.+)$", program.read_text(), re.M)
    if not marker:
        return "FAIL", "no '-- KNOWN-GAP:' line"
    fragment = marker.group(1).strip()
    code, out, err, _ = execute(binary, program, None, timeout)
    text = (out + err).decode(errors="replace")
    if code is None:
        return "FAIL", "timed out"
    if code == 0:
        return "XPASS", "gap closed: move this program into the main suite"
    if code < 0:
        return "FAIL", f"crashed with signal {-code}"
    if fragment not in text:
        return "FAIL", f"failed, but not with '{fragment}': {text.strip()[:200]}"
    return "XFAIL", fragment


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filters", nargs="*", help="substrings of program names")
    parser.add_argument("--binary", type=Path, default=REPO / "bin/dlua")
    parser.add_argument("--scale", choices=SCALES + ("all",), default="all")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--record", action="store_true",
                        help="rewrite the golden files from the current outputs")
    parser.add_argument("--no-gaps", action="store_true", help="skip known_gaps/")
    args = parser.parse_args(argv)
    binary = args.binary.resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"not an executable: {binary}")
    scales = SCALES if args.scale == "all" else (args.scale,)
    selected = programs(args.filters)
    if not selected:
        parser.error("no program matches")

    failures = 0
    print(f"{'program':<34} {'scale':<6} {'seconds':>8}  result")
    for program in selected:
        for scale in scales:
            ok, seconds, detail = run_program(binary, program, scale, args.timeout, args.record)
            failures += not ok
            if not ok:
                status = "FAIL: " + detail
            else:
                status = detail or "ok"
            print(f"{program.stem:<34} {scale:<6} {seconds:8.2f}  {status}", flush=True)
    if not args.no_gaps and not args.record:
        for program in known_gaps(args.filters):
            status, detail = run_gap(binary, program, args.timeout)
            failures += status != "XFAIL"
            print(f"{'known_gaps/' + program.stem:<34} {'-':<6} {'':>8}  {status}: {detail}")
    print(f"\n{failures} failure(s)" if failures else "\nall scenario programs passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
