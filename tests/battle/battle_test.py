#!/usr/bin/env python3
"""`varis battle`: a headless battle from a setup file (milestone 48)."""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "bin/varis")
SETUP = str(ROOT / "tests/battle/corridor.varis" if (ROOT / "tests/battle/corridor.varis").exists() else ROOT / "tests/battle/corridor.lua")


def run(*args, expected=0):
    result = subprocess.run([BINARY, "battle", *args], cwd=ROOT, capture_output=True, text=True, timeout=60)
    assert result.returncode == expected, (args, result.returncode, result.stdout + result.stderr)
    return result


text = run(SETUP).stdout
assert "result  won" in text and "leaks   0" in text, text
# Verify that requesting the alternative extension resolves too:
alt = str(ROOT / "tests/battle/corridor.lua" if (ROOT / "tests/battle/corridor.varis").exists() else ROOT / "tests/battle/corridor.varis")
assert "result  won" in run(alt).stdout
digest = int(re.search(r"digest  (-?\d+)", text).group(1))

# the same file and seed give the same battle, in both output forms
as_json = json.loads(run(SETUP, "--json").stdout)
assert as_json["result"] == "won" and as_json["digest"] == digest and as_json["kills"] == 6, as_json
assert run(SETUP).stdout == text

# a different seed is a different battle only where the seed matters; the command still succeeds
run(SETUP, "--seed", "9")

# --digest is a golden check: right digest passes, wrong digest exits 1
run(SETUP, "--digest", str(digest))
bad = run(SETUP, "--digest", "1", expected=1)
assert "not the expected" in bad.stderr, bad.stderr

# --steps stops a battle early and reports what was reached
early = json.loads(run(SETUP, "--json", "--steps", "10").stdout)
assert early["steps"] == 10 and early["result"] == "running", early

# a bad setup is refused with the field named, exit status 2
broken = ROOT / "build/battle_broken.lua"
broken.parent.mkdir(exist_ok=True)
broken.write_text("return {width = 8, height = 8, sinks = {{q = 99, r = 0}}}\n")
refused = run(str(broken), expected=2)
assert "setup refused" in refused.stderr, refused.stderr
missing = run(str(ROOT / "tests/battle/none.lua"), expected=2)
run(expected=2)
print("varis battle: output, determinism, --digest, --steps and refusals checked")
