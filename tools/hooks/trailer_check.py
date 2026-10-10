#!/usr/bin/env python3
"""commit-msg check: loosened gates/ledger entries must carry an acceptance trailer.

benchmarks/targets.toml: a gate/memory value raised, a floor lowered, or a gate/floor removed needs
`Perf-Regression-Accepted: <reason>`.
tests/manifest.toml: a ledger entry added or changed needs `Skip-Accepted: <reason>`.
Compares the staged file with HEAD by parsing both as TOML.
"""
import subprocess
import sys
import tomllib


def blob(spec):
    p = subprocess.run(["git", "show", spec], capture_output=True, text=True)
    return tomllib.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else {}


def targets_loosened(old, new):
    ow, nw = old.get("workload", {}), new.get("workload", {})
    for wid, ot in ow.items():
        nt = nw.get(wid, {})
        for kind in ("gate", "memory", "floor"):
            for label, ov in ot.get(kind, {}).items():
                nv = nt.get(kind, {}).get(label)
                if nv is None:
                    return True
                if kind != "floor" and nv > ov:
                    return True
                if kind == "floor" and nv < ov:
                    return True
    return False


def ledger_changed(old, new):
    o = {e["id"]: e for e in old.get("ledger", [])}
    n = {e["id"]: e for e in new.get("ledger", [])}
    return any(k not in o or o[k] != v for k, v in n.items())


def main(msg_path):
    msg = open(msg_path).read()
    problems = []
    if targets_loosened(blob("HEAD:benchmarks/targets.toml"), blob(":benchmarks/targets.toml")) \
            and "Perf-Regression-Accepted:" not in msg:
        problems.append("benchmarks/targets.toml loosened: add a 'Perf-Regression-Accepted: <reason>' trailer")
    if ledger_changed(blob("HEAD:tests/manifest.toml"), blob(":tests/manifest.toml")) and "Skip-Accepted:" not in msg:
        problems.append("tests/manifest.toml ledger changed: add a 'Skip-Accepted: <reason>' trailer")
    for p in problems:
        print(p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
