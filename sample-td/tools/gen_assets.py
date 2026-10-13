#!/usr/bin/env python3
"""Generates the placeholder art and audio of Lanternfall and presentation.json.

    python3 tools/gen_assets.py          (from sample-td/)

Every asset is a stub: flat colours and synthesized tones, original to this repository. The battle
itself is drawn by the player from the simulation (polygons), so only the story scenes need
pictures. Replace a file in assets/ with finished art of the same name (SVG or PNG with alpha) and
nothing else changes.
"""
import json
import math
import pathlib
import struct
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
ASSETS.mkdir(exist_ok=True)

PLACES = {
    "terraces": ("#6b8a52", "#1c2b20", "The terraces"),
    "road": ("#8a8f6e", "#2a2e24", "The switchbacks"),
    "mill": ("#b09a6a", "#33291a", "The Mill"),
    "bellfrey": ("#a58a5a", "#2a2014", "The Bellfrey"),
    "valley": ("#4a5a7a", "#0b1020", "The valley"),
    "lantern": ("#f0c860", "#3a2a10", "The Lantern"),
    "title": ("#3b4f7a", "#0c1226", "Lanternfall"),
}
HEROES = {
    "ilse": ("#e0a96d", "Ilse"),
    "corvin": ("#5e86c9", "Corvin"),
    "wren": ("#d05080", "Wren"),
    "warden": ("#9aa7b8", "The Warden"),
}
EXPRESSIONS = ["calm", "worried", "fierce"]
MOUTH = {"calm": "M170 205 L230 205", "worried": "M165 215 Q200 192 235 215", "fierce": "M165 205 Q200 190 235 205"}


def write(name, text):
    (ASSETS / name).write_text(text)


def background(id, top, bottom, label):
    write(f"bg-{id}.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient></defs>
<rect width="1280" height="720" fill="url(#g)"/>
<polygon points="0,520 320,430 640,500 960,410 1280,480 1280,720 0,720" fill="#000" opacity="0.28"/>
<text x="640" y="300" text-anchor="middle" font-family="sans-serif" font-size="54" fill="#fff" opacity="0.55">{label}</text>
<text x="640" y="350" text-anchor="middle" font-family="sans-serif" font-size="22" fill="#fff" opacity="0.4">placeholder background</text>
</svg>''')


def figure(id, expression, body, label, portrait=False):
    mouth = MOUTH[expression]
    name = f"{'portrait' if portrait else 'sprite'}-{id}-{expression}"
    write(name + ".svg", f'''<svg xmlns="http://www.w3.org/2000/svg" width="400" height="{300 if portrait else 600}" viewBox="0 0 400 {300 if portrait else 600}">
<rect x="110" y="260" width="180" height="340" rx="40" fill="{body}"/>
<circle cx="200" cy="170" r="85" fill="#f1d3b0"/>
<circle cx="170" cy="150" r="9" fill="#222"/><circle cx="230" cy="150" r="9" fill="#222"/>
<path d="{mouth}" stroke="#222" stroke-width="7" fill="none" stroke-linecap="round"/>
<text x="200" y="420" text-anchor="middle" font-family="sans-serif" font-size="30" fill="#fff">{label}</text>
</svg>''')
    return name + ".svg"


def tone(name, seconds, notes, rate=11025, volume=0.3):
    frames = []
    for i in range(int(seconds * rate)):
        t = i / rate
        value = 0.0
        for freq, start, length in notes:
            if start <= t < start + length:
                phase = (t - start) / length
                value += math.sin(2 * math.pi * freq * t) * min(1.0, phase * 12) * min(1.0, (1 - phase) * 6)
        frames.append(int(max(-1, min(1, value * volume)) * 32767))
    with wave.open(str(ASSETS / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", f) for f in frames))


def melody(base, steps, length=0.5):
    scale = [1, 9 / 8, 5 / 4, 3 / 2, 5 / 3, 2]
    return [(base * scale[s % len(scale)], i * length, length * 0.9) for i, s in enumerate(steps)]


def main():
    manifest = {
        "title": "Lanternfall",
        "subtitle": "Four nights on Marrow Hill",
        "window": [1280, 720],
        "theme": {"font_size": 22, "padding": 12, "gap": 8,
                  "colors": {"accent": "#f0c860", "panel": "#12182aee", "row": "#1c2540ee", "row_hot": "#4a5a80ee",
                             "gold": "#ffe08a", "good": "#9fe0a0", "bad": "#e8847c"}},
        "project": ".",
        "scene": "prologue",
        "font_size": 22,
        "save": "quicksave.json",
        "autosave": "autosave.json",
        "settings": "settings.json",
        "languages": [{"tag": "", "name": "English"}, {"tag": "fr", "name": "Français"}],
        "choice_labels": ["look", "go"],
        "clock": ["Dusk", "Night", "Dawn", "Day"],
        "backgrounds": [], "sprites": [], "portraits": [],
        "slots": [{"id": "left", "x": 60, "y": 44, "width": 400, "height": 350},
                  {"id": "center", "x": 440, "y": 44, "width": 400, "height": 350},
                  {"id": "right", "x": 820, "y": 44, "width": 400, "height": 350}],
        "audio": [], "channels": [{"id": "music", "loop": 1}, {"id": "ambience", "loop": 1}, {"id": "sfx", "loop": 0}],
    }
    for id, (top, bottom, label) in PLACES.items():
        background(id, top, bottom, label)
        manifest["backgrounds"].append({"id": id, "file": f"assets/bg-{id}.svg"})
    for id, (color, label) in HEROES.items():
        for expression in EXPRESSIONS:
            f = figure(id, expression, color, label)
            manifest["sprites"].append({"character": id, "attributes": {"expression": expression}, "file": "assets/" + f})
            f = figure(id, expression, color, label, portrait=True)
            manifest["portraits"].append({"character": id, "attributes": {"expression": expression}, "file": "assets/" + f})
    music = {"title_theme": (196, [0, 2, 3, 2, 4, 3, 2, 0]), "night_theme": (147, [0, 0, 2, 3, 2, 0, 1, 0])}
    for id, (base, steps) in music.items():
        tone(id + ".wav", len(steps) * 0.5, melody(base, steps))
        manifest["audio"].append({"id": id, "file": f"assets/{id}.wav"})
    tone("stat_up.wav", 0.3, [(660, 0, 0.12), (880, 0.12, 0.18)])
    tone("click.wav", 0.08, [(440, 0, 0.07)])
    tone("fail.wav", 0.35, [(220, 0, 0.17), (165, 0.17, 0.18)])
    tone("moment.wav", 0.4, [(330, 0, 0.1), (495, 0.1, 0.1), (660, 0.2, 0.2)])
    for id in ("stat_up", "click", "fail", "moment"):
        manifest["audio"].append({"id": id, "file": f"assets/{id}.wav"})
    (ROOT / "presentation.json").write_text(json.dumps(manifest, indent=1) + "\n")


main()
