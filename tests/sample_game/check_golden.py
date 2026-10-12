#!/usr/bin/env python3
"""Compare the sample game's golden transcript byte for byte (ROADMAP decision D12).

    python3 tests/sample_game/check_golden.py <varis binary> [--update]

The transcript (sample-game/tools/golden.lua) contains every presentation of a fixed seeded
playthrough and the final save text, so a change in behaviour, content fingerprints or the
save format fails here. Regenerate with --update only for an intended, reviewed change.
"""
import difflib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
EXPECTED = pathlib.Path(__file__).with_name("golden.expected")


def main():
    binary = pathlib.Path(sys.argv[1]).resolve()
    proc = subprocess.run([str(binary), "tools/golden.lua"], cwd=ROOT / "sample-game", capture_output=True, timeout=120)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        return 1
    if "--update" in sys.argv:
        EXPECTED.write_bytes(proc.stdout)
        return 0
    expected = EXPECTED.read_bytes()
    if proc.stdout == expected:
        return 0
    diff = difflib.unified_diff(expected.decode("utf-8", "replace").splitlines(), proc.stdout.decode("utf-8", "replace").splitlines(),
                                "golden.expected", "actual", lineterm="", n=1)
    sys.stderr.write("\n".join(list(diff)[:40]) + "\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
