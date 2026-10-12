#!/usr/bin/env python3
"""The language server (`varis lsp`, stage A5), driven with scripted requests and no editor.

    python3 tests/lsp/lsp_test.py <varis binary>

Works on a scratch copy of the sample game. Checks diagnostics, definition, references, hover,
completion, outline, and that a rename of a relation leaves the project passing `varis check`.
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]


class Client:
    def __init__(self, binary, root):
        self.root = pathlib.Path(root)
        self.proc = subprocess.Popen([binary, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=root)
        self.next_id = 1
        self.notifications = []

    def send(self, message):
        body = json.dumps(message).encode()
        self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.proc.stdin.flush()

    def read(self):
        length = None
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise EOFError("server closed")
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        return json.loads(self.proc.stdout.read(length))

    def request(self, method, params):
        ident = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            message = self.read()
            if message.get("id") == ident:
                return message
            self.notifications.append(message)

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def uri(self, path):
        return "file://" + str(self.root / path)

    def drain(self, wanted_uri=None, timeout=5):
        """Read notifications until diagnostics for `wanted_uri` arrive."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for note in self.notifications:
                if note.get("method") == "textDocument/publishDiagnostics" and (
                        wanted_uri is None or note["params"]["uri"] == wanted_uri):
                    self.notifications.remove(note)
                    return note["params"]["diagnostics"]
            self.notifications.append(self.read())
        raise TimeoutError(wanted_uri)

    def latest(self, uri):
        """The newest diagnostics pushed for `uri`, after every earlier message was handled."""
        self.request("textDocument/documentSymbol", {"textDocument": {"uri": uri}})
        found = None
        for note in self.notifications:
            if note.get("method") == "textDocument/publishDiagnostics" and note["params"]["uri"] == uri:
                found = note["params"]["diagnostics"]
        self.notifications = [n for n in self.notifications if n.get("method") != "textDocument/publishDiagnostics"
                              or n["params"]["uri"] != uri]
        return found

    def close(self):
        try:
            self.request("shutdown", None)
            self.notify("exit", None)
        except Exception:
            pass
        self.proc.kill()
        self.proc.wait()


def position(text, needle, occurrence=0, offset=0):
    at = -1
    for _ in range(occurrence + 1):
        at = text.index(needle, at + 1)
    at += offset
    line = text.count("\n", 0, at)
    return {"line": line, "character": at - (text.rfind("\n", 0, at) + 1)}


def apply(root, changes):
    for uri, edits in changes.items():
        path = pathlib.Path(uri[len("file://"):])
        text = path.read_text()
        starts = [0]
        for i, c in enumerate(text):
            if c == "\n":
                starts.append(i + 1)
        spans = []
        for edit in edits:
            a, b = edit["range"]["start"], edit["range"]["end"]
            spans.append((starts[a["line"]] + a["character"], starts[b["line"]] + b["character"], edit["newText"]))
        for a, b, new in sorted(spans, reverse=True):
            text = text[:a] + new + text[b:]
        path.write_text(text)


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    work = pathlib.Path(tempfile.mkdtemp(prefix="varis-lsp-"))
    try:
        game = work / "game"
        shutil.copytree(ROOT / "sample-game", game)
        (game / "project.lua").write_text((game / "project.lua").read_text().replace("locales  = {}", 'locales  = { "fr" }'))
        # A catalog, so that a rename can be seen to rewrite keys.
        subprocess.run([binary, "l10n", "extract"], cwd=game, check=True, capture_output=True)
        client = Client(binary, game)
        try:
            init = client.request("initialize", {"rootUri": client.uri(""), "capabilities": {}})
            caps = init["result"]["capabilities"]
            assert caps["renameProvider"] and caps["definitionProvider"] and caps["hoverProvider"], caps
            client.notify("initialized", {})
            first = client.drain(client.uri("content/events.lua"))
            assert {d["code"] for d in first} == {"symbol-once"}, first
            assert all(d["source"] == "varis" and d["severity"] == 2 for d in first)

            lamp = (game / "content" / "lamp.lua").read_text()
            lamp_uri = client.uri("content/lamp.lua")
            client.notify("textDocument/didOpen", {"textDocument": {"uri": lamp_uri, "languageId": "varis", "version": 1, "text": lamp}})

            # Definition of a relation written in a `when` clause: its declaration in world.lua.
            at = position(lamp, "at(:player, :lamp_room)")
            result = client.request("textDocument/definition", {"textDocument": {"uri": lamp_uri}, "position": at})["result"]
            assert result and result[0]["uri"].endswith("world.lua"), result
            # Hover shows the columns and the key.
            hover = client.request("textDocument/hover", {"textDocument": {"uri": lamp_uri}, "position": at})["result"]
            assert "relation at(entity, room) key(entity)" in hover["contents"]["value"], hover
            # Hover on a quality shows its bounds.
            oil = position(lamp, ":oil", 0, 1)
            hover = client.request("textDocument/hover", {"textDocument": {"uri": lamp_uri}, "position": oil})["result"]
            assert "quality :oil" in hover["contents"]["value"] and "maximum = 6" in hover["contents"]["value"], hover
            # Definition of a quality symbol: the quality.define call.
            result = client.request("textDocument/definition", {"textDocument": {"uri": lamp_uri}, "position": oil})["result"]
            assert result and result[0]["uri"].endswith("qualities.lua"), result

            # Completion: relations in a goal, qualities inside quality(...), decks after `deck`.
            def complete(text, needle, offset):
                client.notify("textDocument/didChange", {"textDocument": {"uri": lamp_uri, "version": 2},
                                                         "contentChanges": [{"text": text}]})
                items = client.request("textDocument/completion", {"textDocument": {"uri": lamp_uri},
                                                                   "position": position(text, needle, 0, offset)})["result"]
                return [i["label"] for i in items]
            assert "carries" in complete(lamp + "\n    when { car", "when { car", 11)
            assert "oil" in complete(lamp + "\nx = quality(:player, :o", "quality(:player, :o", 20)
            assert "market" in complete(lamp + "\n    deck :ma", "deck :ma", 8)
            client.notify("textDocument/didChange", {"textDocument": {"uri": lamp_uri, "version": 3}, "contentChanges": [{"text": lamp}]})

            # Outline of a file.
            symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": lamp_uri}})["result"]
            assert [s["name"] for s in symbols][:2] == ["lamp", "light"], symbols

            # A syntax error is pushed, and goes away when it is fixed.
            broken = lamp.replace('title "The great lamp"', 'title = "The great lamp"', 1)
            client.notify("textDocument/didChange", {"textDocument": {"uri": lamp_uri, "version": 4}, "contentChanges": [{"text": broken}]})
            problems = client.latest(lamp_uri)
            assert any(d["code"] == "syntax" and d["severity"] == 1 for d in problems), problems
            client.notify("textDocument/didChange", {"textDocument": {"uri": lamp_uri, "version": 5}, "contentChanges": [{"text": lamp}]})
            assert client.latest(lamp_uri) in ([], None), "diagnostics did not clear"

            # Re-indexing one edited file and re-checking the project is fast.
            started = time.time()
            for n in range(10):
                client.notify("textDocument/didChange", {"textDocument": {"uri": lamp_uri, "version": 6 + n},
                                                         "contentChanges": [{"text": lamp + "\n-- " + "x" * n}]})
            client.request("textDocument/documentSymbol", {"textDocument": {"uri": lamp_uri}})
            per_edit = (time.time() - started) / 10
            assert per_edit < 0.5, per_edit
            client.notify("textDocument/didChange", {"textDocument": {"uri": lamp_uri, "version": 30}, "contentChanges": [{"text": lamp}]})

            # References of a relation, across files.
            refs = client.request("textDocument/references", {"textDocument": {"uri": lamp_uri}, "position": position(lamp, "carries(:player, :matches)"),
                                                              "context": {"includeDeclaration": True}})["result"]
            files = {r["uri"].rsplit("/", 1)[1] for r in refs}
            assert {"world.lua", "lamp.lua", "explore.lua"} <= files, files

            # Rename a relation: every file, and the project still checks clean.
            rename = client.request("textDocument/rename", {"textDocument": {"uri": lamp_uri}, "position": position(lamp, "carries(:player, :matches)"),
                                                            "newName": "holds"})
            changes = rename["result"]["changes"]
            assert len(changes) >= 3, list(changes)
            # A name that is taken is refused with a message.
            refused = client.request("textDocument/rename", {"textDocument": {"uri": lamp_uri}, "position": position(lamp, "carries(:player, :matches)"),
                                                             "newName": "at"})
            assert "error" in refused and "already exists" in refused["error"]["message"], refused
            apply(game, changes)
        finally:
            client.close()
        done = subprocess.run([binary, "check", "--json"], cwd=game, capture_output=True, text=True)
        report = json.loads(done.stdout)
        assert done.returncode == 0, done.stdout
        bad = [p for p in report["problems"] if p["code"] in ("unknown-relation", "relation-arity", "load", "syntax")]
        assert bad == [], bad
        assert "carries" not in (game / "content" / "lamp.lua").read_text().replace("carries_", "")

        # Rename a choice: the source catalog's keys change in the same edit, and stay current.
        # (Renaming a relation changes the `when` text and conditions the catalog quotes, so the
        # catalog is extracted again first.)
        subprocess.run([binary, "l10n", "extract"], cwd=game, check=True, capture_output=True)
        client = Client(binary, game)
        try:
            client.request("initialize", {"rootUri": client.uri(""), "capabilities": {}})
            client.notify("initialized", {})
            lamp = (game / "content" / "lamp.lua").read_text()
            lamp_uri = client.uri("content/lamp.lua")
            client.notify("textDocument/didOpen", {"textDocument": {"uri": lamp_uri, "languageId": "varis", "version": 1, "text": lamp}})
            rename = client.request("textDocument/rename", {"textDocument": {"uri": lamp_uri}, "position": position(lamp, "choice light", 0, 8),
                                                            "newName": "ignite"})
            changes = rename["result"]["changes"]
            assert any(uri.endswith("l10n/source.json") for uri in changes), list(changes)
            apply(game, changes)
        finally:
            client.close()
        assert "lamp.ignite.title" in (game / "l10n" / "source.json").read_text()
        done = subprocess.run([binary, "l10n", "extract", "--check"], cwd=game, capture_output=True, text=True)
        assert done.returncode == 0, done.stdout + done.stderr
        print("lsp tests passed")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
