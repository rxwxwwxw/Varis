#!/usr/bin/env python3
"""Repository source checks (used by the pre-commit hook and `make check-sources`).

* every source/**/*.d module is listed in the Makefile (AGENTS.md keeps that list explicit),
  except cli.d, which the Makefile appends to the executable build only;
* every .d file carries the PUC-Rio license header (AGENTS.md invariant 1).
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STANDALONE = {"source/varis/cli.d"}


def tracked_d_files():
    out = subprocess.run(["git", "ls-files", "*.d"], cwd=ROOT, capture_output=True, text=True, check=True)
    return [f for f in out.stdout.split() if not f.startswith("c-implementation/")]


def check(files=None):
    errors = []
    makefile = (ROOT / "Makefile").read_text()
    listed = set(re.findall(r"source/varis/[\w/]+\.d", makefile))
    for f in sorted(Path(ROOT / "source").rglob("*.d")):
        rel = str(f.relative_to(ROOT))
        if rel not in listed and rel not in STANDALONE:
            errors.append(f"{rel}: not listed in Makefile SRC_FILES")
    for rel in sorted(listed):
        if not (ROOT / rel).exists():
            errors.append(f"{rel}: listed in Makefile but missing")
    for rel in files if files is not None else tracked_d_files():
        head = (ROOT / rel).read_text(errors="replace")[:600]
        if "PUC-Rio" not in head:
            errors.append(f"{rel}: missing license header")
    return errors


def main(argv):
    errors = check(argv[1:] or None)
    for e in errors:
        print(e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
