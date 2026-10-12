#!/usr/bin/env python3
"""Parser recovery terminates and never crashes on damaged files (AUTHORING_TOOLS_PLAN stage A2).

    python3 tests/check/fuzz_recovery.py <varis binary>

Takes the sample game's source files, damages them deterministically (deleted and inserted
bytes, truncation) and checks that `varis check` and `varis check --index` finish with status 0
or 1: no hang, no crash.
"""
import pathlib
import random
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
JUNK = ['"', "'", "[[", "]]", "{", "}", "(", ")", "end", "do", ":-", "?", "--[[", "\\", "storylet", "choice ", "when {", "\x01", "=", ",", "{#if"]


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    rng = random.Random(20261012)
    sources = sorted((ROOT / "sample-game").rglob("*.lua"))
    runs = 0
    with tempfile.TemporaryDirectory(prefix="varis-fuzz-") as work:
        work = pathlib.Path(work)
        for source in sources:
            text = source.read_text()
            for round_ in range(6):
                damaged = text
                for _ in range(rng.randint(1, 4)):
                    kind = rng.randint(0, 2)
                    at = rng.randrange(len(damaged) + 1)
                    if kind == 0:
                        damaged = damaged[:at] + damaged[at + rng.randint(1, 12):]
                    elif kind == 1:
                        damaged = damaged[:at] + rng.choice(JUNK) + damaged[at:]
                    else:
                        damaged = damaged[:at]
                target = work / "damaged.lua"
                target.write_text(damaged)
                for args in (["check", "damaged.lua"], ["check", "--index", "damaged.lua"]):
                    done = subprocess.run([binary, *args], cwd=work, capture_output=True, timeout=20)
                    if done.returncode not in (0, 1):
                        keep = pathlib.Path(tempfile.gettempdir()) / "varis-fuzz-failure.lua"
                        keep.write_text(damaged)
                        raise AssertionError((source.name, round_, args, done.returncode, done.stderr[-300:], str(keep)))
                    runs += 1
    print(f"recovery fuzz passed ({runs} runs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
