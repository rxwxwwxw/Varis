#!/usr/bin/env python3
"""Run extension cases in isolated processes, each with a hard five-minute limit."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
# Negative cases must fail for their intended reason, never for a timeout/crash.
REJECTIONS = {
    "negative_unsafe_head": r"variable '\?y' in rule head is not bound",
    "negative_unsafe_negation": r"variable '\?y' in negated atom is not bound",
    "negative_unsafe_guard": r"variable '\?y'.*(?:not bound|positive relation atom)",
    "negative_unsafe_comparison": r"variable '\?y' in comparison is not bound",
    "negative_query_safety": r"variable '\?x' in negated atom is not bound",
    "negative_self_negation": r"negation cycle",
    "negative_anonymous_head": r"anonymous variable.*rule head",
    "negative_anonymous_guard": r"anonymous variable.*procedural guard",
}


def run_case(binary, case, timeout):
    expected = REJECTIONS.get(case.stem)
    source = (ROOT / "helpers.lua").read_text() + "\n" + case.read_text()
    if expected is None:
        source += '\nprint("EXTENSION_CASE_COMPLETE")\n'
    else:
        source += '\nerror("UNEXPECTED SUCCESS")\n'
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="dlua-extensions-") as directory:
        script = Path(directory) / case.name
        script.write_text(source)
        # A process group also allows killing descendants of a hung guard.
        with tempfile.TemporaryFile() as log:
            proc = subprocess.Popen([binary, str(script)], stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            except BaseException:
                # Also clean up a case when a supervising benchmark stops us.
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                raise
            log.seek(0)
            output = log.read().decode("utf-8", errors="replace")
    elapsed = time.monotonic() - started
    if timed_out:
        return False, elapsed, f"timed out after {timeout:g}s\n{output}"
    if expected is None:
        passed = proc.returncode == 0 and "EXTENSION_CASE_COMPLETE" in output
    else:
        passed = (proc.returncode > 0 and "UNEXPECTED SUCCESS" not in output
                  and re.search(expected, output) is not None)
    return passed, elapsed, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda p: str(Path(p).resolve()))
    parser.add_argument("--timeout", type=float, default=300,
                        help="per-case seconds, greater than zero and at most 300")
    parser.add_argument("--filter", default="", help="run names containing this substring")
    args = parser.parse_args()
    if not 0 < args.timeout <= 300:
        parser.error("timeout must be greater than zero and at most 300 seconds")
    if not Path(args.binary).is_file() or not os.access(args.binary, os.X_OK):
        parser.error("binary must be an existing executable")
    cases = sorted(p for p in (ROOT / "cases").glob("*.lua") if args.filter in p.stem)
    if not cases:
        parser.error("no cases matched")
    failed = 0
    for case in cases:
        passed, elapsed, output = run_case(args.binary, case, args.timeout)
        print(f"[{'PASS' if passed else 'FAIL'}] {case.stem} ({elapsed:.2f}s)", flush=True)
        if not passed:
            failed += 1
            print(output.rstrip() or "process exited without diagnostics", flush=True)
        else:
            for line in output.splitlines():
                if line.startswith("[SKIP]"):
                    print(line, flush=True)
    print(f"\nResult: {len(cases) - failed} passed, {failed} failed", flush=True)
    return int(failed != 0)


if __name__ == "__main__":
    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    raise SystemExit(main())
