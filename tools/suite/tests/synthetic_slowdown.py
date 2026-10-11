#!/usr/bin/env python3
"""Release-tier acceptance check (plan Phase 3): a synthetic slowdown must trip exactly the expected gates.

Builds a scratch worktree of HEAD in which the interpreter's numeric `for` handler does extra work
(a few atomic additions, enough to cost the `for`-loop workloads well over 20 %), then runs the committed
`bench --check` against that build for a fixed set of core workloads. Exactly the `for`-loop-bound
workloads must fail a gate or floor; the others must pass. The worktree is removed afterwards.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / ".cache/src/synthetic-slowdown"
SELECT = ["core.numeric_loop", "core.array_access", "core.sieve", "core.fib", "core.closures",
          "core.hash_access", "core.string_manip", "core.coroutine_switch"]
EXPECT_FAIL = {"core.numeric_loop", "core.array_access", "core.sieve"}
INJECT = ('                        { import core.atomic : atomicOp; '
          'atomicOp!"+="(syntheticSink, 1); atomicOp!"+="(syntheticSink, 2); }\n')


def sh(*cmd, cwd=ROOT, check=True):
    return subprocess.run([str(c) for c in cmd], cwd=cwd, capture_output=True, text=True, check=check)


def main():
    if WORK.exists():
        sh("git", "worktree", "remove", "--force", WORK)
    sh("git", "worktree", "add", "--detach", WORK, "HEAD")
    try:
        vm = WORK / "source/varis/vm.d"
        text = vm.read_text()
        marker = "                case OpCode.ForLoop: {\n"
        if text.count(marker) < 1:
            raise SystemExit("anchor for the ForLoop handler not found; update synthetic_slowdown.py")
        text = text.replace(marker, marker + INJECT, 1)
        text = text.replace("\nmodule varis.vm;\n", "\nmodule varis.vm;\n\nshared long syntheticSink;\n", 1)
        vm.write_text(text)
        build = sh("make", "varis", cwd=WORK, check=False)
        slow = WORK / "bin/varis"
        if build.returncode or not slow.exists():
            raise SystemExit("scratch build failed:\n" + build.stderr[-1500:])
        cmd = [sys.executable, ROOT / "tools/suite", "bench", "--check", "--no-confirm", "--candidate", slow]
        for w in SELECT:
            cmd += ["--filter", w]
        run = sh(*cmd, check=False)
    finally:
        sh("git", "worktree", "remove", "--force", WORK, check=False)
    print(run.stdout[-2500:])
    failed = set(re.findall(r"FAILED: (.*)", run.stdout)[0].split(", ")) if "FAILED:" in run.stdout else set()
    if run.returncode == 0 or failed != EXPECT_FAIL:
        sys.exit(f"expected exactly {sorted(EXPECT_FAIL)} to fail, got {sorted(failed)} (rc {run.returncode})")
    print("synthetic slowdown rejected on exactly the expected workloads:", sorted(failed))


if __name__ == "__main__":
    main()
