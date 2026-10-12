#!/usr/bin/env python3
"""Drive `varis serve` over HTTP without a browser (WORKBENCH_PLAN.md §7).

    python3 tests/workbench/protocol_test.py <varis binary>

Starts the server on a free loopback port in sample-game/, then checks the token, the command
window, the workspace, the relation browser, the story panel and file access.
"""
import json
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    server = subprocess.Popen([binary, "serve", "--port", "0", str(ROOT / "sample-game")], stdout=subprocess.PIPE, text=True)
    try:
        line = server.stdout.readline()
        match = re.search(r"(http://127\.0\.0\.1:\d+)/\?token=([0-9a-f]+)", line)
        assert match, f"no address in {line!r}"
        base, token = match.groups()

        def call(path, params=None, body=None, tok=token, raw=False):
            query = urllib.parse.urlencode(dict(params or {}, token=tok))
            data = body.encode() if body is not None else None
            with urllib.request.urlopen(urllib.request.Request(f"{base}{path}?{query}", data=data), timeout=30) as response:
                text = response.read().decode()
            return text if raw else json.loads(text)

        # The token is required.
        try:
            call("/api/workspace", tok="wrong")
            raise AssertionError("request without the token was accepted")
        except urllib.error.HTTPError as error:
            assert error.code == 403

        page = call("/", raw=True)
        assert "Command window" in page and "Workspace" in page and "Editor" in page

        # Command window: expressions print, statements run, errors and incomplete input are reported.
        assert call("/api/eval", body="1 + 2") == {"ok": True, "incomplete": False, "output": "3\n", "error": ""}
        assert call("/api/eval", body="x = 41; print(x + 1)")["output"] == "42\n"
        bad = call("/api/eval", body="error('boom')")
        assert not bad["ok"] and "boom" in bad["error"]
        assert call("/api/eval", body="for i = 1, 2 do")["incomplete"]

        # Workspace lists user globals only.
        names = [v["name"] for v in call("/api/workspace")["variables"]]
        assert names == ["x"], names

        # Load the sample game, register a session, browse its world.
        loaded = call("/api/eval", body='G = require("game"); s = story(G.new_session(42)); w = s:world()')
        assert loaded["ok"], loaded
        variables = {v["name"]: v for v in call("/api/workspace")["variables"]}
        assert variables["w"]["world"] and variables["w"]["type"] == "world"
        relations = {r["name"]: r for r in call("/api/relations", {"world": "w"})["relations"]}
        assert "at" in relations and relations["at"]["arity"] == 2
        facts = call("/api/facts", {"world": "w", "name": "at", "start": 0, "count": 5})
        assert facts["total"] >= 1 and len(facts["rows"][0]) == 2

        # Story panel: present, then choose the first choice; the turn advances.
        first = call("/api/present")
        assert first["session"] and first["storylets"], first
        second = call("/api/choose", {"s": 1, "c": 1}, body="")
        assert second["turn"] == first["turn"] + 1, (first["turn"], second["turn"])

        # Files: listing, reading, the syntax check, and path safety.
        files = call("/api/files")["files"]
        assert "game.lua" in files and "content/lamp.lua" in files
        assert "narrative.seal" in call("/api/file", {"path": "game.lua"}, raw=True)
        assert call("/api/check", {"path": "scratch.lua"}, body="local x = ")["problems"]
        assert call("/api/check", {"path": "scratch.lua"}, body="local x = 1")["problems"] == []
        try:
            call("/api/file", {"path": "../README.md"}, raw=True)
            raise AssertionError("path outside the project was served")
        except urllib.error.HTTPError as error:
            assert error.code == 400
    finally:
        server.kill()
        server.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main())
