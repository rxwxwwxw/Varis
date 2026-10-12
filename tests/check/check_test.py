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

    # The project index of the sample game (AUTHORING_TOOLS_PLAN stage A1): a golden file.
    code, out = run(binary, ROOT / "sample-game", "--index")
    assert code == 0, out
    index_golden = HERE / "sample_game.index.expected.json"
    if update:
        index_golden.write_text(out)
    else:
        assert index_golden.read_text() == out, "index differs from tests/check/sample_game.index.expected.json"
    index = json.loads(out)
    kinds = {d["kind"] for d in index["declarations"]}
    assert {"storylet", "choice", "action", "deck", "relation", "rule", "quality", "function"} <= kinds, kinds
    # Every title, text and label has a key, except the one registered by a loop (qualities.lua:21).
    unkeyed = [m for m in index["messages"] if not m["key"]]
    assert len(unkeyed) == 1 and unkeyed[0]["computed"] and unkeyed[0]["file"] == "qualities.lua", unkeyed
    keys = [m["key"] for m in index["messages"] if m["key"]]
    assert len(keys) == len(set(keys)), "message keys are not unique"
    assert "lamp.light.title" in keys and "quality.oil.label" in keys
    lamp = [m for m in index["messages"] if m["key"] == "look.text"][0]
    assert lamp["placeholders"] == ["room"] and lamp["variantOptions"] == 3 and "outdoors" in lamp["conditionRelations"], lamp

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

    # One fixture holding each static check (stage A3), with the suggestion where there is one.
    code, out = run(binary, HERE / "fixtures" / "static", "--json")
    assert code == 1, out
    found = [(p["file"], p["line"], p["code"], p.get("suggestion", "")) for p in json.loads(out)["problems"]]
    assert found == [
        ("content.lua", 2, "relation-arity", ""),
        ("content.lua", 3, "unknown-deck", "market"),
        ("content.lua", 4, "unknown-placeholder", "room"),
        ("content.lua", 5, "unknown-placeholder", ""),
        ("content.lua", 7, "unknown-quality", "oil"),
        ("content.lua", 7, "unknown-relation", ""),
        ("content.lua", 11, "duplicate-id", ""),
        ("content.lua", 17, "duplicate-id", ""),
        ("world.lua", 6, "duplicate-id", ""),
    ], found
    again = [p for p in json.loads(out)["problems"] if p["code"] == "duplicate-id"][0]
    assert again["related"][0]["line"] == 6 and again["subject"] == "choice lamp.light", again

    # The load pass: what the engine's own validation says, at the definition's line (stage A4).
    code, out = run(binary, HERE / "fixtures" / "load_unbound", "--json")
    problem = json.loads(out)["problems"][0]
    assert code == 1 and (problem["code"], problem["file"], problem["line"]) == ("load", "game.lua", 4), out
    assert problem["subject"] == "storylet lamp" and "unbound storylet parameter" in problem["message"], problem
    code, out = run(binary, HERE / "fixtures" / "load_unstratified", "--json")
    problem = json.loads(out)["problems"][0]
    assert code == 1 and (problem["code"], problem["file"], problem["line"]) == ("load", "game.lua", 5), out
    code, out = run(binary, HERE / "fixtures" / "load_unbound", "--json", "--no-load")
    assert code == 0 and json.loads(out)["problems"] == [], out
    # The analysis pass reports what bounded exploration did not reach, and says it is bounded.
    code, out = run(binary, ROOT / "sample-game", "--json", "--analyze")
    unreached = [p for p in json.loads(out)["problems"] if p["code"] == "unreachable"]
    assert code == 0 and unreached and all(p["severity"] == "warning" and p["line"] > 0 for p in unreached), out
    assert any(p["subject"] == "storylet lamp" for p in unreached)

    # Parser recovery: four independent mistakes in one file are all reported, with no cascade.
    code, out = run(binary, HERE / "fixtures" / "recover", "--json")
    assert code == 1, out
    errors = [(p["line"], p["column"]) for p in json.loads(out)["problems"] if p["code"] == "syntax"]
    assert errors == [(2, 11), (11, 13), (17, 5), (22, 1)], errors

    # A storylet without a choice is an ordinary error, not a crash (it once was one).

    code, out = run(binary, HERE / "fixtures" / "nochoice", "--json")
    assert code == 1, out
    assert "requires at least one choice" in json.loads(out)["problems"][0]["message"], out

    # Human output keeps `file:line:column: severity: message [code]`.
    code, out = run(binary, HERE / "fixtures" / "broken")
    assert "bad_syntax.lua:2:11: error:" in out and "[syntax]" in out, out
    print("check tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
