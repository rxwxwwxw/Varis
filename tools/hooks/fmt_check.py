#!/usr/bin/env python3
"""Verify D files are dfmt-clean. dfmt has no check mode, so compare its output with the file.

With --staged, checks the staged blobs of the staged .d files (pre-commit); otherwise the
paths given (default: all tracked .d files outside c-implementation).
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def dfmt(text):
    p = subprocess.run(["dfmt", f"--config={ROOT}"], input=text, capture_output=True, text=True, cwd=ROOT)
    if p.returncode:
        raise SystemExit(f"dfmt failed: {p.stderr.strip()}")
    return p.stdout


def main(argv):
    staged = "--staged" in argv
    paths = [a for a in argv[1:] if not a.startswith("--")]
    if staged:
        out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACM", "--", "*.d"],
                             cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
        paths = [p for p in out if not p.startswith("c-implementation/")]
    elif not paths:
        out = subprocess.run(["git", "ls-files", "*.d"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
        paths = [p for p in out if not p.startswith("c-implementation/")]
    bad = []
    for p in paths:
        if staged:
            text = subprocess.run(["git", "show", f":{p}"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        else:
            text = (ROOT / p).read_text()
        if dfmt(text) != text:
            bad.append(p)
    for p in bad:
        print(f"not dfmt-clean: {p}", file=sys.stderr)
    if bad:
        print("run `make fmt` and re-stage", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
