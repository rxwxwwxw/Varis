#!/usr/bin/env python3
"""Reject staged build outputs and blobs over 1 MiB (c-implementation fixtures excepted)."""
import subprocess
import sys

LIMIT = 1 << 20
files = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
                       capture_output=True, text=True, check=True).stdout.split("\n")
bad = []
for f in filter(None, files):
    if f.startswith(("bin/", "build/", ".cache/")) or f.endswith((".o", ".a", ".dylib")):
        bad.append(f"{f}: build output must not be committed")
        continue
    if f.startswith("c-implementation/"):
        continue
    size = subprocess.run(["git", "cat-file", "-s", f":{f}"], capture_output=True, text=True).stdout.strip()
    if size.isdigit() and int(size) > LIMIT:
        bad.append(f"{f}: {int(size)} bytes exceeds 1 MiB")
for b in bad:
    print(b, file=sys.stderr)
raise SystemExit(1 if bad else 0)
