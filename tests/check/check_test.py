#!/usr/bin/env python3
"""`varis check` output: the sample game's golden file, and fixtures for the diagnostic record.

    python3 tests/check/check_test.py <varis binary> [--update]
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
FIVE = ["file", "line", "severity", "code", "message"]


def run(binary, cwd, *args):
    done = subprocess.run([binary, "check", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    return done.returncode, done.stdout


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    update = "--update" in sys.argv

    # The sample game, through its manifest: a golden file.
    code, out = run(binary, ROOT / "sample-game", "--json")
    assert code == 0, out
    golden = HERE / "sample_game.expected.json"
    pretty = json.dumps(json.loads(out), indent=1, sort_keys=False) + "\n"
    if update:
        golden.write_text(pretty)
    else:
        assert golden.read_text() == pretty, "check output differs from tests/check/sample_game.expected.json"
    problems = json.loads(out)["problems"]
    # The five fields consumers have always had come first and keep their meaning.
    for problem in problems:
        assert list(problem)[:5] == FIVE, list(problem)
        assert problem["line"] > 0 and problem["column"] > 0 and problem["endColumn"] > problem["column"]

    # A broken project: a manifest with an unknown field, a syntax error with a range, a clean file.
    code, out = run(binary, HERE / "fixtures" / "broken", "--json")
    assert code == 1, out
    found = {(p["file"], p["code"]): p for p in json.loads(out)["problems"]}
    key = found[("project.lua", "manifest-key")]
    assert key["severity"] == "warning" and key["line"] == 4 and "colour" in key["message"], key
    syntax = found[("bad_syntax.lua", "syntax")]
    assert syntax["severity"] == "error" and syntax["line"] == 2, syntax
    assert (syntax["column"], syntax["endLine"], syntax["endColumn"]) == (11, 2, 12), syntax
    assert ("fine.lua", "symbol-once") not in found  # :alpha appears twice

    # Human output keeps `file:line:column: severity: message [code]`.
    code, out = run(binary, HERE / "fixtures" / "broken")
    assert "bad_syntax.lua:2:11: error:" in out and "[syntax]" in out, out
    print("check tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
