#!/usr/bin/env python3
"""Fresh-process scene saves: portable locals/return stack/stage, wording and rejection checks."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BINARY = str(Path(sys.argv[1]).resolve())
CONTENT = (ROOT / "sample-vn/content.varis").read_text()


def run(directory, source, success=True):
    path = directory / "driver.lua"
    path.write_text(source)
    result = subprocess.run([BINARY, str(path)], cwd=directory, text=True, capture_output=True, timeout=30)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    (directory / "content.varis").write_text(CONTENT)
    prelude = 'dofile("content.varis")\nlocal function factory() return logic.emptyworld() end\n'
    run(directory, prelude + '''
local s = narrative.new(factory()); s:play(:harbour)
for i=1,3 do s:advance(s:present().token) end
s:advance(s:present().token, "Rowan")
s:advance(s:present().token)
assert(s:present().scene == :farewell)
local f=assert(io.open("scene.json", "w")); f:write(s:save()); f:close()
''')
    saved = (directory / "scene.json").read_text()
    assert "Then I will" not in saved and "Welcome back" not in saved
    load = prelude + '''
local f=assert(io.open("scene.json")); local saved=f:read("a"); f:close()
local s=narrative.load(saved, factory)
local p=s:present()
assert(p.scene == :farewell and p.locals.visitor == "Rowan")
assert(p.stage.characters.mira.attributes.expression == :smile)
assert(p.stage.characters.mira.slot == :left)
assert(p.stage.background == :harbour_evening and p.stage.audio.music == :evening_theme)
print(p.beats[1].text)
s:advance(p.token)
assert(s:present().scene == :harbour and s:present().beat_index == 7)
'''
    assert "tomorrow" in run(directory, load).stdout
    (directory / "content.varis").write_text(CONTENT.replace("Then I will see you tomorrow.", "See you at dawn."))
    assert "at dawn" in run(directory, load).stdout
    (directory / "content.varis").write_text(CONTENT.replace("at :left", "at :right"))
    assert "incompatible" in run(directory, load, False).stderr
    (directory / "content.varis").write_text(CONTENT)
    value = json.loads(saved)
    assert value["format"] == "varis-session-3"
    def key(name): return name.encode().hex()
    frames = value["scene"]["record"][key("frames")]["sequence"]
    frames[-1]["record"][key("pc")] = "i999999"
    (directory / "scene.json").write_text(json.dumps(value))
    assert "invalid saved scene" in run(directory, load, False).stderr
    (directory / "scene.json").write_text(saved)
    value = json.loads(saved)
    value["scene"]["record"][key("stage")]["record"][key("characters")]["record"][key("mira")]["record"][key("attributes")]["record"][key("expression")] = "y626164"
    (directory / "scene.json").write_text(json.dumps(value))
    assert "invalid saved scene" in run(directory, load, False).stderr
    # Static checks reject unknown characters/attributes without executing project code.
    bad = directory / "bad.lua"
    bad.write_text(CONTENT.replace("show mira at", "show mria at", 1).replace("expression = :smile", "expression = :wrong"))
    result = subprocess.run([BINARY, "check", "--no-load", "--json", str(bad)], cwd=directory,
                            text=True, capture_output=True, timeout=30)
    report = json.loads(result.stdout)
    codes = {problem["code"] for problem in report["problems"]}
    assert {"unknown-character", "unknown-character-attribute"} <= codes, report
    invalid = [
        ('scene x {{kind=:say,character=:missing,text="Hi"}}', "unknown character"),
        ('character c {attributes={face={:calm}}} scene x {{kind=:say,character=:c,attributes={face=:bad},text="Hi"}}', "unknown attribute"),
        ('scene x {{kind=:jump,target=:absent}}', "unknown scene"),
        ('scene x {{kind=:audio,channel=:music,tag=false}}', "audio tag"),
        ('scene x {{kind=:narration,id="line",text="One"},{kind=:narration,id="line",text="Two"}}', "duplicate scene line id"),
        ('scene x {{kind=:set,["local"]="bad",value={nested=1}}}', "portable scalars"),
        ('narrative.scene(:x, {{kind=:pause, value=function() end}})', "portable scalar"),
    ]
    for content, diagnostic in invalid:
        result = run(directory, content + "\nnarrative.seal()", False)
        assert diagnostic in result.stderr, result.stderr
    print("fresh-process scene saves, wording compatibility, corruption and validation checks passed")
