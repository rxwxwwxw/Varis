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


def main():
    rpg()
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
    original["content"] = str(ROOT / "sample-vn/content.lua")
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
        # Rendering text longer than a box and scripts without spaces must not crash.
        # Smoke captures a spoken beat; use a character-free say through a declaration.
        content.write_text('character narrator {name="Narrator"}\nscene menu {{kind=:say,character=:narrator,text="'
                           + '海港の灯り欢迎回来 ' * 80 + '"},{kind=:ended}}')
        run(manifest, directory / "unicode.bmp", message="checks passed")
    print("SDL rendering, scene flow, menu, Unicode and missing-asset diagnostics passed")


if __name__ == "__main__":
    main()
