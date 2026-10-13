#!/usr/bin/env python3
"""Wording is not gameplay (localization plan stage T2): saves survive a wording edit, a save of the
first format is still read and written back as the second, and a gameplay edit is still refused.

    python3 tests/sample_game/wording_test.py <varis binary>
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent

SAVE = r'''package.path = "./?.varis;./?.lua;" .. package.path
local G = require("game")
local s = G.new_session(42)
local p = s:present()
s:choose(p.storylets[1].choices[1].token)
local f = assert(io.open(arg[1], "w")); f:write(s:save()); f:close()
'''
LOAD = r'''package.path = "./?.varis;./?.lua;" .. package.path
local G = require("game")
local f = assert(io.open(arg[1], "r")); local text = f:read("a"); f:close()
local ok, s = pcall(G.load, text)
if not ok then print("REFUSED " .. tostring(s)); os.exit(3) end
local out = assert(io.open(arg[2], "w")); out:write(s:save()); out:close()
print("LOADED")
'''


def run(binary, cwd, script, *args):
    path = cwd / "_script.lua"
    path.write_text(script)
    return subprocess.run([binary, str(path), *args], cwd=cwd, capture_output=True, text=True, timeout=60)


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    work = pathlib.Path(tempfile.mkdtemp(prefix="varis-wording-"))
    try:
        game = work / "game"
        shutil.copytree(ROOT / "sample-game", game)

        # A first-format save is read, and written back in the second format with the same state.
        done = run(binary, game, LOAD, str(HERE / "save_format1.json"), "upgraded.json")
        assert done.returncode == 0 and "LOADED" in done.stdout, done.stdout + done.stderr
        old = json.loads((HERE / "save_format1.json").read_text())
        new = json.loads((game / "upgraded.json").read_text())
        assert old["format"] == "varis-session-1" and new["format"] == "varis-session-2"
        for key in old:
            if key not in ("format", "content_fingerprint"):
                assert old[key] == new[key], key
        assert (HERE / "golden.expected").read_text().splitlines()[252] == (game / "upgraded.json").read_text().strip()

        # A new save survives a wording edit, and says the presentation changed.
        done = run(binary, game, SAVE, "saved.json")
        assert done.returncode == 0, done.stderr
        lamp_path = game / "content" / ("lamp.varis" if (game / "content" / "lamp.varis").exists() else "lamp.lua")
        lamp = lamp_path.read_text()
        lamp_path.write_text(lamp.replace('title "The great lamp"', 'title "The enormous lamp"'))
        qual_path = game / ("qualities.varis" if (game / "qualities.varis").exists() else "qualities.lua")
        qual_path.write_text(qual_path.read_text().replace('label = "Lamp oil"', 'label = "Oil for the lamp"'))
        done = run(binary, game, LOAD, "saved.json", "again.json")
        assert done.returncode == 0 and "LOADED" in done.stdout, done.stdout + done.stderr
        before = json.loads((game / "saved.json").read_text())
        after = json.loads((game / "again.json").read_text())
        assert before["content_fingerprint"] == after["content_fingerprint"]
        assert before["presentation"] != after["presentation"], "the presentation revision did not move"

        # A gameplay edit is refused, never silently accepted: here a priority.
        lamp_path.write_text(lamp.replace("priority 60", "priority 61"))
        done = run(binary, game, LOAD, "saved.json", "refused.json")
        assert done.returncode == 3 and "incompatible narrative content" in done.stdout, done.stdout + done.stderr
        # So is an edit to a condition embedded in a text.
        lamp_path.write_text(lamp.replace("{#if query lit(:lamp)}", "{#if query told(:lamp)}"))
        done = run(binary, game, LOAD, "saved.json", "refused.json")
        assert done.returncode == 3 and "incompatible narrative content" in done.stdout, done.stdout + done.stderr
        print("wording tests passed")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
