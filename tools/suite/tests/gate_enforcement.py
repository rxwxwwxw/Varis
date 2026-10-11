#!/usr/bin/env python3
"""Release-tier acceptance check: the committed bench harness must fail a deliberately slowed candidate.

The candidate is a wrapper that burns CPU before exec'ing the real interpreter, so every process-kind
workload gets slower by a fixed amount. `suite bench --check` must then exit non-zero and name the
workload, which proves gates are enforced through the committed code path (not a scratch patch).
"""
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
real = os.environ.get("SUITE_BIN") or str(ROOT / "bin/varis")
with tempfile.TemporaryDirectory() as d:
    wrapper = Path(d) / "slow-varis"
    wrapper.write_text('#!/bin/sh\ni=0\nwhile [ $i -lt 30000 ]; do i=$((i+1)); done\nexec "%s" "$@"\n' % real)
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
    p = subprocess.run([sys.executable, str(ROOT / "tools/suite"), "bench", "--check", "--no-confirm", "--group",
                        "startup", "--filter", "startup.empty", "--runs", "3", "--candidate", str(wrapper)],
                       capture_output=True, text=True, cwd=ROOT)
print(p.stdout[-800:])
if p.returncode == 0 or "FAILED: startup.empty" not in p.stdout:
    sys.exit("slowed candidate was not rejected by bench --check")
print("gate enforcement ok: slowed candidate rejected")
