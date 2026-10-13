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
import tempfile
import shutil
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]


class WebSocketClient:
    """A minimal RFC 6455 client (masked text frames) over a raw socket."""

    def __init__(self, base, token, path="/ws"):
        import base64, os, socket
        host, port = base.replace("http://", "").split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET {path}?token={token} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(1)
            if not chunk:
                break
            data += chunk
        self.events = []
        self.status = data.split(b"\r\n")[0].decode()
        import hashlib
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.accepted = ("Sec-WebSocket-Accept: " + accept) in data.decode()

    def _exact(self, n):
        out = b""
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise EOFError
            out += chunk
        return out

    def send(self, obj, opcode=1):
        import os, struct
        payload = (obj if isinstance(obj, bytes) else json.dumps(obj).encode())
        head = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self):
        import struct
        while True:
            b0, b1 = self._exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._exact(8))[0]
            payload = self._exact(n)
            opcode = b0 & 0x0F
            if opcode == 1:
                return json.loads(payload.decode())
            if opcode == 8:
                return None
            if opcode == 10:
                return ("pong", payload)

    def request(self, id, path, query=None, body=None, method=None):
        message = {"id": id, "method": method or ("POST" if body is not None else "GET"), "path": path}
        if query:
            message["query"] = query
        if body is not None:
            message["body"] = body
        self.send(message)
        while True:
            reply = self.receive()
            if isinstance(reply, dict) and reply.get("id") == id:
                return reply
            if isinstance(reply, dict) and "event" in reply:
                self.events.append(reply)


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    scratch = tempfile.TemporaryDirectory(prefix="varis-workbench-")
    project_root = pathlib.Path(scratch.name) / "game"
    shutil.copytree(ROOT / "sample-game", project_root)
    server = subprocess.Popen([binary, "serve", "--port", "0", str(project_root)], stdout=subprocess.PIPE, text=True)
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

        # Editor services work before loading the game and include unsaved files.
        lamp = (ROOT / "sample-game/content/lamp.lua").read_text()

        def editor(operation, text=lamp, needle="at(:player, :lamp_room)", offset=0, **extra):
            at = text.index(needle) + offset
            before = text[:at]
            payload = dict(path="content/lamp.lua", text=text, line=before.count("\n") + 1,
                           column=len(before.rsplit("\n", 1)[-1].encode()) + 1, **extra)
            return call("/api/editor/" + operation, body=json.dumps(payload))

        assert "relation at(entity, room) key(entity)" in editor("hover")["text"]
        assert editor("definition")["definitions"][0]["file"] == "world.lua"
        draft = lamp + "\nwhen { new_"
        completion = editor("complete", draft, "new_", 4,
                            buffers={"draft.lua": "relation new_relation(x)\n"})
        assert "new_relation" in [i["label"] for i in completion["items"]], completion
        rename = editor("rename", needle="carries(:player, :matches)", newName="holds")
        assert rename["ok"] and {"world.lua", "content/lamp.lua", "content/explore.lua"} <= {e["file"] for e in rename["edits"]}, rename
        assert not editor("rename", needle="carries(:player, :matches)", newName="at")["ok"]
        catalog = '\n{"key":"lamp.light.title","owner":"choice lamp.light"}\n'
        choice_rename = editor("rename", needle="choice light", offset=8, newName="ignite",
                               buffers={"l10n/source.json": catalog})
        assert choice_rename["ok"]
        catalog_edits = [e for e in choice_rename["edits"] if e["file"] == "l10n/source.json"]
        assert len(catalog_edits) == 2 and all(e["range"]["line"] == 2 for e in catalog_edits), choice_rename
        assert not any(d["file"].endswith(".json") for d in editor("check", buffers={"l10n/source.json": catalog})["diagnostics"])
        # Rename only describes edits; neither disk nor the runtime changes.
        assert call("/api/file", {"path": "content/lamp.lua"}, raw=True) == lamp
        assert call("/api/workspace")["variables"] == [{"name": "x", "preview": "41", "type": "number", "world": False, "table": False, "session": False}]
        unicode_draft = lamp.replace("at(:player, :lamp_room)", 'at(:player, :lamp_room)', 1)
        unicode_draft += '\nlocal caption = "日本語 🐈"; local rows = query at(?who, ?where)\n'
        assert editor("hover", unicode_draft, "at(?who")["text"].startswith("relation at(")
        report = editor("check", buffers={"broken.lua": "local x = "})
        assert any(d["file"] == "broken.lua" and d["code"] == "syntax" for d in report["diagnostics"]), report
        assert call("/api/editor/hover", body=json.dumps({"path": "../README.md"}))["error"] == "bad path"

        # Load the sample game, register a session, browse its world.
        loaded = call("/api/eval", body='G = require("game"); s = story(G.new_session(42)); w = s:world()')
        assert loaded["ok"], loaded
        variables = {v["name"]: v for v in call("/api/workspace")["variables"]}
        assert variables["w"]["world"] and variables["w"]["type"] == "world"
        relations = {r["name"]: r for r in call("/api/relations", {"world": "w"})["relations"]}
        assert "at" in relations and relations["at"]["arity"] == 2
        facts = call("/api/facts", {"world": "w", "name": "at", "start": 0, "count": 5})
        assert facts["total"] >= 1 and len(facts["rows"][0]) == 2

        # Derived relation browsing uses snapshot queries and leaves saved state unchanged.
        before_inspection = call("/api/eval", body="s:save()")["output"]
        derived = call("/api/facts", {"world": "w", "name": "open_exit", "derived": "true"})
        assert derived["total"] > 0 and len(derived["rows"][0]) == 2, derived
        assert call("/api/facts", {"world": "w", "name": "open_exit"})["total"] == 0
        assert call("/api/eval", body="s:save()")["output"] == before_inspection
        summary = call("/api/session")
        assert summary["turn"] == 0 and summary["deck"] == "default" and summary["periods"], summary
        # Raw table browsing is paged and never invokes user-defined metamethods.
        assert call("/api/eval", body='inspect_table = setmetatable({child={value=7}, answer=42}, '
                    '{__pairs=function() error("pairs ran") end, __tostring=function() error("tostring ran") end})')["ok"]
        table_page = call("/api/table", {"name": "inspect_table", "count": 1})
        assert table_page["total"] == 2 and len(table_page["rows"]) == 1, table_page
        rows = call("/api/table", {"name": "inspect_table"})["rows"]
        child = next(r for r in rows if r["key"] == "child")
        assert call("/api/table", {"ref": child["ref"]})["rows"][0]["preview"] == "7"
        assert call("/api/workspace")["variables"]
        assert call("/api/table", {"ref": 999999})["error"]

        # Story panel: present, then choose the first choice; the turn advances.
        first = call("/api/present")
        assert first["session"] and first["storylets"], first
        second = call("/api/choose", {"s": 1, "c": 1}, body="")
        assert second["turn"] == first["turn"] + 1, (first["turn"], second["turn"])

        # Language is a view: a switch renders the same presentation again (no new draw).
        assert call("/api/language", {"lang": "no-such"}, body="")["error"]
        pseudo = call("/api/language", {"lang": "x-pseudo"}, body="")
        assert pseudo["language"] == "x-pseudo" and pseudo["turn"] == second["turn"], pseudo
        assert pseudo["storylets"][0]["title"].startswith("["), pseudo["storylets"][0]
        messages = call("/api/messages")["messages"]
        assert messages and messages[0]["key"].endswith(".title") and messages[0]["shown"] != messages[0]["source"], messages[0]
        back = call("/api/language", {"lang": ""}, body="")
        assert back["storylets"][0]["title"] == messages[0]["source"] or not back["storylets"][0]["title"].startswith("[")
        assert call("/api/translate", {"lang": "fr", "key": "walk.title"}, body="Aller {nope}")["ok"] is False

        # Plural and select branches are previewed with sample values, in the language's rules.
        ru = call("/api/branches", {"lang": "ru"}, body="{#plural n}{#one}{n} монета{#few}{n} монеты{#many}{n} монет{#other}{n} монеты{/plural}")
        rows = {r["category"]: r["text"] for r in ru["previews"][0]["rows"]}
        assert rows == {"one": "1 монета", "few": "2 монеты", "many": "0 монет", "other": "1.5 монеты"}, rows
        sel = call("/api/branches", {"lang": "fr"}, body="{#select k}{#case m}Il{#case f}Elle{#default}Iel{/select}")
        assert [r["text"] for r in sel["previews"][0]["rows"]] == ["Il", "Elle", "Iel"], sel
        assert call("/api/branches", {"lang": "fr"}, body="{#if broken")["error"]
        # The editor bundle is embedded: no CDN or separate installation is required.
        assert "VarisEditor" in page and "cm-breakpoints" in page
        assert 'id="edwrap"' in page and 'id="source"' not in page

        # Story-level debugging: what the turn changed, the storylet list, and "why".
        changes = call("/api/changes")["changes"]
        assert isinstance(changes, list)
        for change in changes:
            assert change["relation"] and (change["added"] or change["removed"])
        ids = call("/api/content")["storylets"]
        assert "lamp" in ids and "walk" in ids, ids
        why = call("/api/why", {"id": "lamp"})
        assert why["id"] == "lamp" and why["eligible"] is False and why["goals"], why
        walk_why = call("/api/why", {"id": "walk"})
        assert walk_why["eligible"] is True
        assert all(i["choices"][0]["id"] == ":go" and i["choices"][0]["eligible"] for i in walk_why["instances"]), walk_why
        before_tools = call("/api/eval", body="s:save()")["output"]
        bounded = call("/api/analyze", {"depth": 0, "max_nodes": 1}, body="")
        assert bounded["scope"] == "seeded_presentation_tree_without_external_inputs", bounded
        assert bounded["nodes"] == 1 and bounded["complete"] is False and bounded["frontier"], bounded
        assert bounded["frontier"][0]["reason"] == "depth_limit", bounded
        assert ":walk" not in bounded["reached_content"] and "walk" in bounded["reached_content"], bounded
        assert all(row["status"] == "not_reached_within_scope" for row in bounded["unreachable_content"])
        assert call("/api/eval", body="s:save()")["output"] == before_tools
        for params in ({"depth": -1}, {"depth": 33}, {"max_nodes": 0}, {"max_nodes": 10001},
                       {"max_steps": 0}, {"max_objects": 0}, {"depth": "1.5"}, {"max_nodes": "x"}):
            assert call("/api/analyze", params, body="")["error"], params

        # Source-level debugging: a breakpoint stops the evaluation with its frames alive.
        program = "local a = 1\nlocal b = a + 1\nc = a + b\nprint(c)\n"
        assert call("/api/breakpoints", body="command:3")["breakpoints"] == [{"file": "command", "line": 3}]
        stop = call("/api/eval", body=program)
        assert stop == {"stopped": True, "file": "command", "line": 3}, stop
        assert "resume" in call("/api/analyze", body="")["error"]
        local_values = {v["name"]: v["value"] for v in call("/api/locals")["locals"]}
        assert local_values == {"a": "1", "b": "2"}, local_values
        assert call("/api/inspect", body="a + b")["output"] == "3\n"
        assert not call("/api/inspect", body="a = 9")["ok"]
        assert not call("/api/inspect", body="error('must not run')")["ok"]
        assert call("/api/inspect", body="a")["output"] == "1\n"
        frames = call("/api/stack")
        assert frames["stopped"] and frames["frames"][0]["line"] == 3, frames
        # Evaluating while stopped works and does not disturb the stopped program.
        assert call("/api/eval", body="1 + 1")["output"] == "2\n"
        step = call("/api/step", {"mode": "over"}, body="")
        assert step == {"stopped": True, "file": "command", "line": 4}, step
        done = call("/api/continue", body="")
        assert done["ok"] and done["output"] == "3\n", done
        # Without breakpoints the same program runs straight through.
        assert call("/api/breakpoints", body="")["breakpoints"] == []
        assert call("/api/eval", body=program)["output"] == "3\n"
        assert call("/api/continue", body="")["error"] == "not stopped"

        # Select outer frames; reads resolve locals before captured values and globals.
        nested = ('local outside = 17\nlocal function child()\n'
                  '  local inside = 23\n  return outside + inside\nend\nprint(child())\n')
        call("/api/breakpoints", body="command:4")
        assert call("/api/eval", body=nested)["stopped"]
        nested_frames = call("/api/stack")["frames"]
        assert len(nested_frames) >= 2
        assert call("/api/inspect", {"frame": nested_frames[0]["frame"]}, body="inside + outside")["output"] == "40\n"
        assert call("/api/inspect", {"frame": nested_frames[1]["frame"]}, body="outside")["output"] == "17\n"
        assert call("/api/inspect", {"frame": 99999}, body="outside")["error"]
        assert call("/api/continue", body="")["output"] == "40\n"
        # Raw table inspection never invokes __index, __add or __tostring.
        dangerous = ('trap = setmetatable({}, {__index=function() error("index ran") end, '
                     '__add=function() error("add ran") end, __tostring=function() error("tostring ran") end})\n'
                     'local held = trap\nprint("done")\n')
        call("/api/breakpoints", body="command:3")
        assert call("/api/eval", body=dangerous)["stopped"]
        assert call("/api/inspect", body="held.missing")["output"] == "nil\n"
        assert not call("/api/inspect", body="held + 1")["ok"]
        assert call("/api/inspect", body="held")["ok"]
        assert call("/api/continue", body="")["output"] == "done\n"

        # Story-panel choices stop inside effects, exposing tentative writes. Continuing
        # produces the same world as a fresh playtest without a debugger.
        assert call("/api/breakpoints", body="")["breakpoints"] == []
        initial = call("/api/start", {"seed": 42}, body="")
        assert initial["session"] and initial["turn"] == 0, initial
        walk = next(i + 1 for i, st in enumerate(initial["storylets"]) if st["id"] == ":walk")
        effect = (project_root / "content/explore.lua").read_text().splitlines()
        effect_line = next(i + 1 for i, line in enumerate(effect) if "narrative.emit(:moved" in line)
        call("/api/breakpoints", body=f"content/explore.lua:{effect_line}")
        stop = call("/api/choose", {"s": walk, "c": 1}, body="")
        assert stop == {"stopped": True, "file": "content/explore.lua", "line": effect_line}, stop
        frames = call("/api/stack")["frames"]
        assert frames and call("/api/locals", {"frame": frames[0]["frame"]})["locals"]
        # Inspection sees the effect's tentative relocation before commit.
        during = call("/api/facts", {"world": "w", "name": "at"})
        player = next(row for row in during["rows"] if row[0] == ":player")
        assert player[1] != ":cottage", during
        assert "resume" in call("/api/present")["error"]
        assert "resume" in call("/api/reload", body="")["error"]
        continued = call("/api/continue", body="")
        assert continued["session"] and continued["turn"] == 1, continued
        call("/api/breakpoints", body="")
        save_with_debug = call("/api/eval", body="s:save()")["output"]
        history = call("/api/history")
        assert history["replayable"] and history["seed"] == 42
        assert [c["kind"] for c in history["commands"]] == ["present", "choose", "present"], history
        # Reload reconstructs and replays by stable instance keys, preserving RNG and saves.
        reloaded = call("/api/reload", body="")
        assert reloaded["turn"] == 1 and reloaded["storylets"] == continued["storylets"], reloaded
        saved_again = call("/api/eval", body="s:save()")["output"]
        assert saved_again == save_with_debug, [(k, json.loads(save_with_debug).get(k), json.loads(saved_again).get(k))
                                              for k in json.loads(save_with_debug) if json.loads(save_with_debug).get(k) != json.loads(saved_again).get(k)]
        rewind = call("/api/rewind", {"turn": 0}, body="")
        assert rewind["turn"] == 0 and rewind["storylets"] == initial["storylets"], rewind
        plain = call("/api/choose", {"s": walk, "c": 1}, body="")
        assert plain["storylets"] == continued["storylets"]
        saved_again = call("/api/eval", body="s:save()")["output"]
        assert saved_again == save_with_debug, [(k, json.loads(save_with_debug).get(k), json.loads(saved_again).get(k))
                                              for k in json.loads(save_with_debug) if json.loads(save_with_debug).get(k) != json.loads(saved_again).get(k)]
        # A failed reload keeps the current session usable.
        source = project_root / "content/explore.lua"
        original = source.read_text()
        source.write_text("local = broken")
        assert call("/api/reload", body="")["error"]
        assert call("/api/eval", body="s:turn()")["output"] == "1\n"
        source.write_text(original)
        assert call("/api/rewind", {"turn": -1}, body="")["error"]
        # Restore globals used by the existing completion assertions after fresh-state reload.
        assert call("/api/eval", body='G = require("game")')["ok"]

        # Completion: globals and keywords, table fields, and symbols (storylets and relations).
        def names(text):
            return [i["name"] for i in call("/api/complete", body=text)["items"]]
        assert "narrative" in names("narr") and "string" in names("local x = str")
        assert names("string.for") == ["format"]
        assert "new_session" in names("s2 = G.new_")
        assert "lamp" in names("narrative.explain(s, :la") and "at" in names("query a")
        assert names("") == []

        # Go to definition reads the source files.
        found = call("/api/definition", {"name": "lamp"})["definitions"]
        assert any(d["file"] == "content/lamp.lua" and d["kind"] == "storylet" for d in found), found
        assert any(d["kind"] == "function" for d in call("/api/definition", {"name": "new_session"})["definitions"])
        assert call("/api/definition", {"name": "no_such_name_anywhere"})["definitions"] == []
        # Found through the AST: choices (with owner-less names) and qualities.
        assert any(d["kind"] == "choice" and d["file"] == "content/lamp.lua" for d in call("/api/definition", {"name": "light"})["definitions"])
        assert any(d["kind"] == "quality" and d["file"] == "qualities.lua" for d in call("/api/definition", {"name": "oil"})["definitions"])

        # The project manifest is read without executing it.
        project = call("/api/project")
        assert project["present"] and project["id"] == "saltmarsh" and project["entry"] == "game", project
        assert project["problems"] == [] and "content/*.lua" in project["content"], project

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

        # A fresh manifest-backed scene project exercises the same beat protocol as SceneHost.
        (project_root / "project.lua").write_text('return {id="scenes", entry="scene_game", session="scene_game.new_session", language="en", scripts={"scene_game.lua"}}')
        (project_root / "scene_game.lua").write_text("""
character mira {name="Mira", attributes={expression={:quiet,:smile}}, defaults={expression=:quiet}}
scene finish {{kind=:say, character=:mira, attributes={expression=:smile}, id="finish.hello", text="Hello {visitor}."},
              {kind=:hide, character=:mira}, {kind=:ended}}
scene start {
 {kind=:background,tag=:harbour},
 {kind=:show,character=:mira,slot=:left},
 {kind=:input,["local"]="visitor",text="Name?"},
 {kind=:menu,choices={{id=:yes,text="Continue",target=:finish}}}
}
relation open()
relation shut()
storylet hub()
 when { open() }
 title "Scene entrance"
 choice enter title "Enter" effect do narrative.play(:start) end end
 choice locked when { shut() } title "Locked" effect do end end
end
narrative.seal("workbench-scenes")
return {new_session=function(seed)
 local w = logic.emptyworld()
 logic (w) do
  relation open()
  relation shut()
  fact open()
 end
 local s = narrative.new(w)
 s:seed(seed)
 return s
end}
""")
        start_scene_project = call("/api/start", {"seed": 19}, body="")
        assert start_scene_project["session"]
        hub_why = call("/api/why", {"id": "hub"})
        choice_traces = {c["id"]: c for c in hub_why["instances"][0]["choices"]}
        assert choice_traces[":enter"]["eligible"] is True and choice_traces[":locked"]["eligible"] is False, choice_traces
        assert choice_traces[":locked"]["goals"][0]["outcome"] == "failure", choice_traces
        assert call("/api/content")["scenes"] == ["finish", "start"]
        scene = call("/api/choose", {"s": 1, "c": 1}, body="")["sceneView"]
        assert scene["scene"] == "start" and scene["beats"][0]["kind"] == "background", scene
        assert scene["stage"]["background"] == "harbour" and scene["token"] is None
        scene_saved = call("/api/eval", body="s:save()")["output"]
        assert call("/api/present")["sceneView"] == scene
        assert call("/api/eval", body="s:save()")["output"] == scene_saved
        assert call("/api/advance", body='"invalid on background"')["error"]
        assert call("/api/eval", body="s:save()")["output"] == scene_saved
        scene = call("/api/advance", body="")["sceneView"]
        assert scene["beats"][0]["kind"] == "show" and scene["stage"]["characters"]["mira"]["slot"] == "left", scene
        scene = call("/api/advance", body="")["sceneView"]
        assert scene["beats"][0]["kind"] == "input"
        for invalid in ('[]', '{"wrong":"shape"}', 'not JSON', '01', '1e', '1.2.3', '1e999', '--1'):
            assert call("/api/advance", body=invalid).get("error"), f"accepted invalid input {invalid!r}"
        scene = call("/api/advance", body=json.dumps("日本語 🐈"))["sceneView"]
        assert scene["beats"][0]["kind"] == "menu" and scene["locals"]["visitor"] == "日本語 🐈"
        menu_save = call("/api/eval", body="s:save()")["output"]
        assert call("/api/advance", {"choice": 2}, body="")["error"]
        assert call("/api/eval", body="s:save()")["output"] == menu_save
        scene = call("/api/advance", {"choice": 1}, body="")["sceneView"]
        assert scene["beats"][0]["text"] == "Hello 日本語 🐈." and scene["beats"][0]["speaker"]["name"] == "Mira", scene
        assert scene["stage"]["characters"]["mira"]["attributes"]["expression"] == "smile"
        saved_scene = call("/api/eval", body="s:save()")["output"]
        translated_response = call("/api/language", {"lang": "x-pseudo"}, body="")
        assert "sceneView" in translated_response, translated_response
        translated = translated_response["sceneView"]
        assert translated["beats"][0]["text"] != scene["beats"][0]["text"]
        assert call("/api/eval", body="s:save()")["output"] == saved_scene
        assert call("/api/messages")["messages"][0]["key"] == "scene.finish.hello.text"
        assert call("/api/reload", body="")["sceneView"] == translated
        assert call("/api/eval", body="s:save()")["output"] == saved_scene
        assert call("/api/language", {"lang": ""}, body="")["sceneView"] == scene
        history = call("/api/history")["commands"]
        before_input = next(i + 1 for i, row in enumerate(history)
                            if row["kind"] == "present" and i > 0 and history[i-1].get("beat") == 2)
        rewind_scene = call("/api/rewind", {"command": before_input}, body="")["sceneView"]
        assert rewind_scene["beats"][0]["kind"] == "input" and rewind_scene["locals"] == {}
        # Portable scalar inputs retain exact integers and symbols during reconstruction.
        for scalar in (" 9223372036854775807 ", '{"symbol":"guest"}', "false", "1.5", "null"):
            assert call("/api/play", {"id": "start"}, body="")["sceneView"]
            call("/api/advance", body="")
            call("/api/advance", body="")
            assert call("/api/advance", body=scalar)["sceneView"]["beats"][0]["kind"] == "menu"
            exact_save = call("/api/eval", body="s:save()")["output"]
            assert call("/api/reload", body="")["sceneView"]["beats"][0]["kind"] == "menu"
            assert call("/api/eval", body="s:save()")["output"] == exact_save
        assert call("/api/advance", {"choice": 1}, body="")["sceneView"]["beats"][0]["kind"] == "say"
        assert call("/api/advance", body="")["sceneView"]["beats"][0]["kind"] == "hide"
        assert call("/api/advance", body="")["sceneView"]["beats"][0]["kind"] == "ended"
        assert "sceneView" not in call("/api/advance", body="")
        assert call("/api/advance", body="")["error"]

        # Asynchronous Pause and Stop reach an interpreter that is busy running Lua.
        assert call("/api/pause", body="") == {"ok": False, "error": "nothing is running"}
        assert call("/api/interrupt", body="") == {"ok": False, "error": "nothing is running"}
        import threading
        import time

        def background(path, params, body):
            box = {}
            worker = threading.Thread(target=lambda: box.update(call(path, params, body=body)))
            worker.start()
            return worker, box

        def when_running(action):
            for _ in range(100):
                reply = action()
                if reply.get("ok"):
                    return reply
                time.sleep(0.05)
            raise AssertionError("nothing started running")

        # Pause stops a loop with its frames alive; Continue-style resumption goes through Stop.
        worker, box = background("/api/eval", {}, "local n = 0; while true do n = n + 1 end")
        time.sleep(0.5)  # inside the loop, where `n` is live
        assert call("/api/pause", body="")["ok"]
        worker.join(30)
        assert box.get("stopped") is True and box["line"] == 1, box
        assert call("/api/stack")["stopped"] is True
        paused_locals = call("/api/locals")["locals"]
        assert any(row["name"] == "n" for row in paused_locals), paused_locals
        assert call("/api/pause", body="") == {"ok": True, "stopped": True}
        stopped_worker, stopped_box = background("/api/interrupt", {}, "")
        stopped_worker.join(30)
        assert not stopped_box["ok"] and "interrupted" in stopped_box["error"], stopped_box
        assert call("/api/stack")["stopped"] is False


        # Stop on error: an uncaught error stops with its frames alive; a pcall'd one does not.
        assert call("/api/breakonerror", body="1") == {"breakOnError": True}
        boom = "local function f(x)\n  local y = x * 2\n  error('boom ' .. y)\nend\nf(21)\n"
        stop = call("/api/eval", body=boom)
        assert stop["stopped"] is True and stop["reason"] == "error" and "boom 42" in stop["message"], stop
        assert stop["line"] == 3 and stop["file"] == "command", stop
        locals_at_error = {v["name"]: v["value"] for v in call("/api/locals")["locals"]}
        assert locals_at_error == {"x": "21", "y": "42"}, locals_at_error
        assert call("/api/stack")["frames"][0]["line"] == 3
        failed = call("/api/continue", body="")
        assert not failed["ok"] and "boom 42" in failed["error"], failed
        caught = call("/api/eval", body="print(pcall(function() error('quiet') end))")
        assert caught["ok"] and "quiet" in caught["output"], caught
        assert call("/api/breakonerror", body="0") == {"breakOnError": False}
        plain = call("/api/eval", body="error('plain')")
        assert not plain["ok"] and "plain" in plain["error"], plain

        # WebSocket transport: same handlers as HTTP, pushed events, token required.
        try:
            WebSocketClient(base, "wrong")
            bad_ws = WebSocketClient(base, "wrong")
            assert "403" in bad_ws.status, bad_ws.status
        except (ConnectionError, EOFError):
            pass
        ws = WebSocketClient(base, token)
        assert ws.status.startswith("HTTP/1.1 101") and ws.accepted, (ws.status, ws.accepted)
        assert ws.receive() == {"event": "hello", "protocol": 1}
        reply = ws.request(1, "/api/eval", body="1 + 2")
        assert reply["status"] == 200 and reply["body"] == {"ok": True, "incomplete": False, "output": "3\n", "error": ""}, reply
        assert ws.request("a", "/api/workspace")["body"]["variables"] is not None
        assert ws.request(3, "/nope")["status"] in (200, 404)
        # Pushed events: output and workspaceChanged after a command; fileChanged and
        # publishDiagnostics after a save.
        ws.events.clear()
        ws.request(4, "/api/eval", body="print('pushed')")
        seen = {e["event"]: e.get("data") for e in ws.events}
        for _ in range(4):
            if "workspaceChanged" in seen:
                break
            event = ws.receive()
            seen[event["event"]] = event.get("data")
        assert seen.get("output") == {"text": "pushed\n"}, seen
        assert "workspaceChanged" in seen, seen
        ws.events.clear()
        ws.request(5, "/api/file", query={"path": "scratch_ws.lua"}, body="local x = = 1\n", method="POST")
        got = {}
        for _ in range(4):
            if {"fileChanged", "publishDiagnostics"} <= got.keys():
                break
            event = ws.receive()
            got[event["event"]] = event.get("data")
        for event in ws.events:
            got[event["event"]] = event.get("data")
        assert got["fileChanged"] == {"path": "scratch_ws.lua"}, got
        assert got["publishDiagnostics"]["path"] == "scratch_ws.lua" and got["publishDiagnostics"]["result"]["problems"], got
        ws.send(b"not json")
        assert ws.receive()["status"] == 400
        ws.send(b"\x01\x02", opcode=9)
        assert ws.receive() == ("pong", b"\x01\x02")
        # A stop is pushed as an event; the request that started it is answered, then resumed.
        assert call("/api/breakpoints", body="command:2")["breakpoints"] == [{"file": "command", "line": 2}]
        ws.send({"id": 11, "method": "POST", "path": "/api/eval", "body": "local a = 1\nlocal b = a + 1\nc = b\n"})
        seen = []
        while len(seen) < 2:
            seen.append(ws.receive())
        events = [m for m in seen if "event" in m]
        replies = [m for m in seen if m.get("id") == 11]
        assert events and events[0]["event"] == "stopped" and events[0]["data"]["line"] == 2, seen
        assert replies and replies[0]["body"] == {"stopped": True, "file": "command", "line": 2}, seen
        assert ws.request(12, "/api/stack")["body"]["stopped"] is True
        resumed = ws.request(13, "/api/continue", body="")
        assert resumed["body"]["ok"] is True, resumed
        assert call("/api/breakpoints", body="")["breakpoints"] == []
        ws.sock.close()

        # Stop aborts a running command without a pause; the next command runs normally.
        worker, box = background("/api/eval", {}, "while true do end")
        when_running(lambda: call("/api/interrupt", body=""))
        worker.join(30)
        assert not box["ok"] and "interrupted" in box["error"], box
        assert call("/api/eval", body="1 + 1")["output"] == "2\n"

        # A pause is still honoured when a breakpoint is set, and execution may resume after it.
        worker, box = background("/api/eval", {}, "local t = os.clock(); while os.clock() - t < 1.5 do end; print('done')")
        when_running(lambda: call("/api/pause", body=""))
        worker.join(30)
        assert box.get("stopped") is True, box
        resumed = call("/api/continue", body="")
        assert resumed["ok"] and resumed["output"] == "done\n", resumed
    finally:
        server.kill()
        server.wait()
        scratch.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
