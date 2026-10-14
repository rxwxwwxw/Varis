#!/usr/bin/env python3
"""Optional SDL integration tests. Uses SDL's dummy video/audio and software renderer."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "bin/varis-sdl"
ENV = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", SDL_AUDIODRIVER="dummy")


def run(manifest, screenshot, expected=0, message=""):
    result = subprocess.run([str(BINARY), str(manifest), "--smoke", str(screenshot)],
                            cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=30)
    assert result.returncode == expected, result.stdout + result.stderr
    assert message in result.stdout + result.stderr, result.stdout + result.stderr


def rpg():
    """The whole-game player: title-less smoke of the hub, overlays, input and save/load."""
    output = ROOT / "build/sdl/hollowbrook.bmp"
    run(ROOT / "sample-rpg/presentation.json", output, message="checks passed")
    data = output.read_bytes()
    assert data[:2] == b"BM" and struct.unpack_from("<ii", data, 18) == (1280, 720)
    offset = struct.unpack_from("<I", data, 10)[0]
    assert len(set(data[offset:])) > 40
    # The interface adapts to the window: a phone-sized window, a large one, and a large text size
    # all render without a diagnostic (the layout is chosen by size, see tools/sdl/ui.d).
    for name, extra in (("compact", dict(VARIS_SMOKE_SIZE="420x800")),
                        ("wide", dict(VARIS_SMOKE_SIZE="1920x1080")),
                        ("large-text", dict(VARIS_SMOKE_SIZE="1280x720", VARIS_SMOKE_SCALE="6")),
                        ("forced-compact", dict(VARIS_SMOKE_SIZE="1000x700", VARIS_SMOKE_LAYOUT="compact")),
                        ("journal", dict(VARIS_SMOKE_OVERLAY="journal")),
                        ("drawer", dict(VARIS_SMOKE_SIZE="420x800", VARIS_SMOKE_DRAWER="1"))):
        out = ROOT / f"build/sdl/hollowbrook-{name}.bmp"
        result = subprocess.run([str(BINARY), str(ROOT / "sample-rpg/presentation.json"), "--smoke", str(out)],
                                cwd=ROOT, env=dict(ENV, **extra), capture_output=True, text=True, timeout=60)
        assert result.returncode == 0 and "checks passed" in result.stdout, (name, result.stdout + result.stderr)
        assert len(set(out.read_bytes()[offset:])) > 30, name
    # Played by clicks alone, through the same widget tree the window shows: every click must
    # change the game (a click that lands on the wrong row is a soft lock), for each build, on a
    # large and on a small window.
    for build, size in (("strength", "1920x1080"), ("wits", "1280x720"), ("charm", "420x800")):
        out = ROOT / f"build/sdl/hollowbrook-play-{build}.bmp"
        result = subprocess.run([str(BINARY), str(ROOT / "sample-rpg/presentation.json"), "--smoke", str(out)],
                                cwd=ROOT, env=dict(ENV, VARIS_SMOKE_PLAY="ui", VARIS_SMOKE_BUILD=build,
                                                   VARIS_SMOKE_SIZE=size),
                                capture_output=True, text=True, timeout=120)
        assert result.returncode == 0 and "ui play: finished" in result.stdout, (build, result.stdout + result.stderr)
    for leftover in ("autosave.json", "settings.json", "quicksave.json"):
        (ROOT / "sample-rpg" / leftover).unlink(missing_ok=True)


def lanternfall():
    """The battle view: the first night built and played through the player's own widgets, one frame
    per zoom band, and the same night played headless gives the same digest (SAMPLE_TD_PLAN.md §7)."""
    import re
    out = ROOT / "build/sdl/lanternfall.bmp"
    out.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run([str(BINARY), str(ROOT / "sample-td/presentation.json"), "--smoke", str(out)],
                            cwd=ROOT, env=dict(ENV, VARIS_SMOKE_PLAY="battle", VARIS_SMOKE_SIZE="1280x720"),
                            capture_output=True, text=True, timeout=120)
    text = result.stdout + result.stderr
    assert result.returncode == 0 and "checks passed" in text, text
    placements = [tuple(int(v) for v in m.groups()) for m in re.finditer(r"^place (\d+) (-?\d+) (-?\d+)$", text, re.M)]
    digest = int(re.search(r"digest (-?\d+)", text).group(1))
    worst = int(re.search(r"worst frame (\d+) ms", text).group(1))
    assert len(placements) >= 4, text
    # a frame of the whole map at software rendering stays well inside a generous budget
    assert worst < 250, f"a frame took {worst} ms"
    # one capture per zoom band, each a real picture
    sizes = set()
    for band in ("build", "overview", "tactical", "standard", "close", "night", "over"):
        data = (ROOT / f"build/sdl/lanternfall-{band}.bmp").read_bytes()
        assert data[:2] == b"BM" and struct.unpack_from("<ii", data, 18) == (1280, 720), band
        offset = struct.unpack_from("<I", data, 10)[0]
        assert len(set(data[offset:])) > 30, band
        sizes.add(hash(data[offset:]))
    assert len(sizes) == 7, "the zoom bands should look different"
    # the same night, played headless with the same commands
    script = """
package.path = "./?.lua;" .. package.path
local G = require("game")
local s = G.new_session(1)
G.settle(s)
assert(G.choose(s, "go_up", "go"))
local placements = {%s}
local o = G.run_night(s, {every = 10, build = function(night)
    for _, p in ipairs(placements) do assert(night.handle:place(p[1], p[2], p[3])) end
end})
print("digest " .. o.digest)
""" % ", ".join("{%d, %d, %d}" % p for p in placements)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "headless.lua"
        path.write_text(script)
        run_lua = subprocess.run([str(ROOT / "bin/varis"), str(path)], cwd=ROOT / "sample-td",
                                 capture_output=True, text=True, timeout=60)
    assert run_lua.returncode == 0, run_lua.stdout + run_lua.stderr
    headless = int(re.search(r"digest (-?\d+)", run_lua.stdout).group(1))
    assert headless == digest, f"the window played a different night: {digest} vs headless {headless}"
    # the same night in a phone-sized and a large window: the layout adapts, the battle does not
    for size in ("420x800", "1920x1080"):
        out = ROOT / f"build/sdl/lanternfall-{size}.bmp"
        again = subprocess.run([str(BINARY), str(ROOT / "sample-td/presentation.json"), "--smoke", str(out)],
                               cwd=ROOT, env=dict(ENV, VARIS_SMOKE_PLAY="battle", VARIS_SMOKE_SIZE=size),
                               capture_output=True, text=True, timeout=120)
        assert again.returncode == 0 and f"digest {digest}" in again.stdout, (size, again.stdout + again.stderr)
    for leftover in ("autosave.json", "settings.json", "quicksave.json"):
        (ROOT / "sample-td" / leftover).unlink(missing_ok=True)
    print(f"Lanternfall battle view: {len(placements)} towers, digest {digest} equals the headless night")


def lanternfall_scale():
    """The largest map (880 x 495 = 435,600 tiles, every sector revealed): the overview texture is
    built once, every band's steady frame stays inside the budget of plan section 9 (generous here:
    the software renderer is slower than a GPU), and the night still plays to its end."""
    import re
    out = ROOT / "build/sdl/lanternfall-scale.bmp"
    result = subprocess.run([str(BINARY), str(ROOT / "sample-td/presentation.json"), "--smoke", str(out)],
                            cwd=ROOT, env=dict(ENV, VARIS_SMOKE_PLAY="battle", VARIS_SMOKE_SIZE="1280x720",
                                               LANTERNFALL_MAP="880x495"),
                            capture_output=True, text=True, timeout=300)
    text = result.stdout + result.stderr
    assert result.returncode == 0 and "checks passed" in text, text
    bands = re.findall(r"^band (\w+): first (\d+) ms, steady (\d+) ms, overview builds (\d+)$", text, re.M)
    assert [b[0] for b in bands] == ["overview", "tactical", "standard", "close"], text
    for name, first, steady, builds in bands:
        assert int(steady) < 60, f"{name}: a steady frame took {steady} ms"
        assert int(builds) == 1, f"{name}: the overview texture was built {builds} times"
    worst = int(re.search(r"worst frame (\d+) ms", text).group(1))
    assert worst < 250, f"a frame took {worst} ms"
    for leftover in ("autosave.json", "settings.json", "quicksave.json"):
        (ROOT / "sample-td" / leftover).unlink(missing_ok=True)
    print("Lanternfall at 435,600 tiles: steady frames " + ", ".join(f"{b[0]} {b[2]} ms" for b in bands))


def sample_vn():
    output = ROOT / "build/sdl/harbour.bmp"
    run(ROOT / "sample-vn/presentation.json", output, message="checks passed")
    data = output.read_bytes()
    assert data[:2] == b"BM"
    assert struct.unpack_from("<ii", data, 18) == (1280, 720)
    # Detect a blank framebuffer without a fragile machine/font-specific golden image.
    offset = struct.unpack_from("<I", data, 10)[0]
    assert len(set(data[offset:])) > 80
    original = json.loads((ROOT / "sample-vn/presentation.json").read_text())
    for group in ("backgrounds", "sprites", "portraits", "audio"):
        for asset in original[group]:
            asset["file"] = str(ROOT / "sample-vn" / asset["file"])
    original["content"] = str(ROOT / "sample-vn/content.varis")
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        manifest = directory / "presentation.json"
        bad = dict(original, backgrounds=[])
        manifest.write_text(json.dumps(bad))
        run(manifest, output, 1, "unmapped background")
        bad = dict(original, sprites=[])
        manifest.write_text(json.dumps(bad))
        run(manifest, output, 1, "no matching sprite")
        bad = dict(original, channels=[])
        manifest.write_text(json.dumps(bad))
        run(manifest, output, 1, "unmapped audio channel")
        content = directory / "menu.lua"
        content.write_text('''
character mira {name="Mira", attributes={expression={:quiet,:smile},outfit={:coat}},
 defaults={expression=:quiet,outfit=:coat}}
scene result {{kind=:say,character=:mira,text="Selected."},{kind=:ended}}
scene menu {{kind=:background,tag=:harbour_evening},
 {kind=:show,character=:mira,slot=:left}, {kind=:transition},
 {kind=:menu,choices={{id=:next,text="Continue",target=:result}}}}
''')
        manifest.write_text(json.dumps(dict(original, content=str(content), scene="menu")))
        run(manifest, directory / "menu.bmp", message="checks passed")
        # Stage presentation features: pictures, screen effects, richer transitions, ruby, pauses
        pic_file = str(ROOT / "sample-vn/assets/harbour.svg")
        content.write_text(f'''
character mira {{name="Mira", attributes={{expression={{:quiet,:smile}},outfit={{:coat}}}},
 defaults={{expression=:quiet,outfit=:coat}}}}
scene stage_test {{
    {{kind=:background,tag=:harbour_evening}},
    {{kind=:show,character=:mira,slot=:left}},
    {{kind=:transition,type=:fade,duration=200}},
    {{kind=:picture,id=:harbour_pic,file="{pic_file}",x=0.05,y=0.05,width=0.4,height=0.4,alpha=0.8}},
    {{kind=:screen,effect=:flash,duration=150,color=0xffffff}},
    {{kind=:screen,effect=:shake,duration=150,intensity=6}},
    {{kind=:screen,effect=:tint,duration=150,color="#44ff0000"}},
    {{kind=:pause,duration=100}},
    {{kind=:transition,type=:slide,duration=200}},
    {{kind=:transition,type=:wipe,duration=200}},
    {{kind=:say,character=:mira,text="明日は｜港《みなと》に行きます。それでは、また｜明日《あした》。"}},
    {{kind=:picture,id=:harbour_pic,action=:hide}},
    {{kind=:ended}}
}}
''')
        manifest.write_text(json.dumps(dict(original, content=str(content), scene="stage_test")))
        stage_out = directory / "stage.bmp"
        run(manifest, stage_out, message="checks passed")
        stage_data = stage_out.read_bytes()
        assert len(set(stage_data[offset:])) > 80

        # CJK line-breaking (JIS X 4051) preventing prohibited start/end punctuation
        content.write_text('character narrator {name="Narrator"}\nscene menu {{kind=:say,character=:narrator,text="'
                           + '桜の花びらが風に舞い落ちる季節、港の灯りは静かに波を照らしていた。「どこへ行くの？」と彼女は尋ねた。' * 10
                           + '"},{kind=:ended}}')
        manifest.write_text(json.dumps(dict(original, content=str(content), scene="menu")))
        run(manifest, directory / "cjk_wrapping.bmp", message="checks passed")
    print("SDL rendering, scene flow, menu, Unicode and missing-asset diagnostics passed")


def localization():
    """Milestone 39 localization validation:
    - Release policy enforcement via varis check --locale and varis l10n check.
    - TrueType publisher font subsetting and glyph coverage checks.
    - Korean particle formatting and Japanese ruby in localized scenes."""
    # 1. Project check with locale policy
    res = subprocess.run([str(ROOT / "bin/varis"), "check", "--locale", "all", "--require", "reviewed", "sample-vn"],
                         cwd=ROOT, capture_output=True, text=True)
    assert res.returncode == 0, res.stdout + res.stderr

    # 2. l10n check with locale policy
    res = subprocess.run([str(ROOT / "bin/varis"), "l10n", "check", "--locale", "all", "--require", "reviewed"],
                         cwd=ROOT / "sample-vn", capture_output=True, text=True)
    assert res.returncode == 0 and "5 reviewed" in res.stdout, res.stdout + res.stderr

    # 3. Policy failure check when unreviewed draft exists
    ja_orig = (ROOT / "sample-vn/l10n/ja.json").read_text()
    try:
        ja_draft = ja_orig.replace('"status":"reviewed"', '"status":"draft"', 1)
        (ROOT / "sample-vn/l10n/ja.json").write_text(ja_draft)
        bad_check = subprocess.run([str(ROOT / "bin/varis"), "l10n", "check", "--locale", "ja", "--require", "reviewed"],
                                   cwd=ROOT / "sample-vn", capture_output=True, text=True)
        assert bad_check.returncode == 1, "Expected release policy failure for draft message"
        assert "release gate" in bad_check.stdout
    finally:
        (ROOT / "sample-vn/l10n/ja.json").write_text(ja_orig)

    # 4. TrueType font subsetting
    arial = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    if arial.exists():
        subset_out = ROOT / "sample-vn/assets/Arial_fr.ttf"
        res = subprocess.run([str(ROOT / "bin/varis"), "l10n", "subset", "--locale", "fr",
                              "--font", str(arial), "--out", "assets"],
                             cwd=ROOT / "sample-vn", capture_output=True, text=True)
        assert res.returncode == 0, res.stdout + res.stderr
        assert subset_out.exists()
        font_chk = subprocess.run([str(ROOT / "bin/varis"), "l10n", "fonts", "--font", f"fr={subset_out}"],
                                  cwd=ROOT / "sample-vn", capture_output=True, text=True)
        assert "covers all" in font_chk.stdout, font_chk.stdout + font_chk.stderr
        subset_out.unlink(missing_ok=True)
        (ROOT / "sample-vn/assets/Arial_subset.ttf").unlink(missing_ok=True)

    # 5. Scene translation execution: Japanese ruby, Korean particle formatter, speaker name translation
    script = """
require("sample-vn.content")
local function factory() return logic.emptyworld() end

-- Japanese: speaker name "ミラ", ruby "｜明日《あした》"
local s_ja = narrative.new(factory())
s_ja:set_language("ja")
s_ja:play(:harbour)
for _=1,3 do s_ja:advance(s_ja:present().token) end
local p = s_ja:present()
assert(p.beats[1].text == "お名前は何ですか？")
s_ja:advance(p.token, "ローワン")
p = s_ja:present()
assert(p.beats[1].speaker.name == "ミラ")
assert(p.beats[1].text == "おかえりなさい、ローワン。")
s_ja:advance(p.token)
p = s_ja:present()
assert(p.beats[1].speaker.name == "ミラ")
assert(p.beats[1].text == "それでは、また｜明日《あした》。")

-- Korean: speaker name "미라", particle "{visitor:은/는}"
local s_ko = narrative.new(factory())
s_ko:set_language("ko")
s_ko:play(:harbour)
for _=1,3 do s_ko:advance(s_ko:present().token) end
p = s_ko:present()
assert(p.beats[1].text == "당신의 이름은 무엇입니까?")
s_ko:advance(p.token, "로완") -- ends in final consonant (ㄴ) -> 은
p = s_ko:present()
assert(p.beats[1].speaker.name == "미라")
assert(p.beats[1].text == "어서 오세요, 로완은.")

local s_ko2 = narrative.new(factory())
s_ko2:set_language("ko")
s_ko2:play(:harbour)
for _=1,3 do s_ko2:advance(s_ko2:present().token) end
s_ko2:advance(s_ko2:present().token, "미라") -- ends in vowel (ㅏ) -> 는
p = s_ko2:present()
assert(p.beats[1].text == "어서 오세요, 미라는.")

print("Localization integration tests passed")
"""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "test_l10n.lua"
        p.write_text(script)
        res = subprocess.run([str(ROOT / "bin/varis"), str(p)], cwd=ROOT, capture_output=True, text=True)
        assert res.returncode == 0 and "Localization integration tests passed" in res.stdout, res.stdout + res.stderr
    print("Localization release policies, font subsetting, and CJK translations passed")


def main():
    lanternfall()
    lanternfall_scale()
    rpg()
    sample_vn()
    localization()


if __name__ == "__main__":
    main()
