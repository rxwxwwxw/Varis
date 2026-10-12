#!/usr/bin/env python3
"""Generates the placeholder art and audio of The Hollowbrook Summer and presentation.json.

    python3 tools/gen_assets.py          (from sample-rpg/)

Every asset is a stub: flat colours and synthesized tones, original to this repository. Replace a
file in assets/ with finished art of the same name (SVG or PNG with alpha) and nothing else
changes; presentation.json is only regenerated when the list of ids does.
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
    "house": ("#c98f5a", "#4a2e1c", "Aunt Odile's house"),
    "square": ("#9aa7b8", "#38465a", "The town square"),
    "market": ("#d9a441", "#5a3d12", "The market"),
    "forge": ("#c4553a", "#2b1510", "Mara's forge"),
    "archive": ("#8c7ab5", "#2a2342", "The archive"),
    "tavern": ("#b3733b", "#2e1c0c", "The Gilded Heron"),
    "docks": ("#5f9bb0", "#14323f", "The docks"),
    "quarry": ("#bfb7a5", "#4a463c", "The old quarry"),
    "green": ("#7bb86f", "#1f4a24", "The Festival Green"),
    "road": ("#a7b88a", "#3c4a2b", "The cart road"),
    "title": ("#3b4f7a", "#0c1226", "The Hollowbrook Summer"),
}
NPCS = {
    "odile": ("#e0a96d", "Odile"), "mara": ("#d0603f", "Mara"), "pell": ("#8d83c9", "Pell"),
    "tilly": ("#e0c25e", "Tilly"), "hask": ("#5e86c9", "Hask"), "dane": ("#59b08a", "Dane"),
}
EXPRESSIONS = ["neutral", "happy", "worried"]
OUTFITS = {"casual": "#cfcfcf", "sporty": "#e06a6a", "scholarly": "#6a8ae0"}
MOUTH = {"neutral": "M170 205 L230 205", "happy": "M165 198 Q200 228 235 198", "worried": "M165 215 Q200 192 235 215"}


def write(name, text):
    (ASSETS / name).write_text(text)


def background(id, top, bottom, label):
    write(f"bg-{id}.svg", f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720" viewBox="0 0 1280 720">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient></defs>
<rect width="1280" height="720" fill="url(#g)"/>
<rect y="470" width="1280" height="250" fill="#000" opacity="0.25"/>
<text x="640" y="300" text-anchor="middle" font-family="sans-serif" font-size="54" fill="#fff" opacity="0.55">{label}</text>
<text x="640" y="350" text-anchor="middle" font-family="sans-serif" font-size="22" fill="#fff" opacity="0.4">placeholder background</text>
</svg>''')


def figure(id, expression, body, accent, label, portrait=False):
    mouth = MOUTH[expression]
    name = f"{'portrait' if portrait else 'sprite'}-{id}-{expression}"
    write(name + ".svg", f'''<svg xmlns="http://www.w3.org/2000/svg" width="400" height="{300 if portrait else 600}" viewBox="0 0 400 {300 if portrait else 600}">
<rect x="110" y="260" width="180" height="340" rx="40" fill="{body}"/>
<circle cx="200" cy="170" r="85" fill="{accent}"/>
<circle cx="170" cy="150" r="9" fill="#222"/><circle cx="230" cy="150" r="9" fill="#222"/>
<path d="{mouth}" stroke="#222" stroke-width="7" fill="none" stroke-linecap="round"/>
<text x="200" y="420" text-anchor="middle" font-family="sans-serif" font-size="30" fill="#fff">{label}</text>
</svg>''')
    return name + ".svg"


def tone(name, seconds, notes, rate=11025, volume=0.3, noise=False):
    frames = []
    total = int(seconds * rate)
    for i in range(total):
        t = i / rate
        value = 0.0
        for freq, start, length in notes:
            if start <= t < start + length:
                phase = (t - start) / length
                envelope = min(1.0, phase * 12) * min(1.0, (1 - phase) * 6)
                value += math.sin(2 * math.pi * freq * t) * envelope
        if noise:
            value += (((i * 1103515245 + 12345) >> 8) & 255) / 255.0 - 0.5
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
        "title": "The Hollowbrook Summer",
        "subtitle": "A summer of small decisions",
        "window": [1280, 720],
        # The look of the interface. Every key is optional; these are the defaults, written out.
        "theme": {
            "font_size": 22,
            "padding": 12,
            "gap": 8,
            "colors": {"accent": "#9bdbd9", "panel": "#101a2eee", "row": "#1a2740ee", "row_hot": "#356b80ee",
                       "gold": "#ffe08a", "good": "#9fe0a0", "bad": "#e8847c"},
        },
        "project": ".",
        "scene": "prologue",
        "font_size": 22,
        "save": "quicksave.json",
        "autosave": "autosave.json",
        "settings": "settings.json",
        "languages": [{"tag": "", "name": "English"}, {"tag": "fr", "name": "Français"}],
        "choice_labels": ["look"],
        "clock": ["Morning", "Afternoon", "Evening", "Night"],
        "backgrounds": [], "sprites": [], "portraits": [],
        "slots": [
            {"id": "left", "x": 60, "y": 44, "width": 400, "height": 350},
            {"id": "center", "x": 440, "y": 44, "width": 400, "height": 350},
            {"id": "right", "x": 820, "y": 44, "width": 400, "height": 350},
        ],
        "audio": [], "channels": [
            {"id": "music", "loop": 1}, {"id": "ambience", "loop": 1}, {"id": "sfx", "loop": 0}
        ],
        "map": {
            "places": [
                {"id": "house", "x": 90, "y": 400}, {"id": "square", "x": 330, "y": 330},
                {"id": "market", "x": 560, "y": 330}, {"id": "forge", "x": 330, "y": 150},
                {"id": "archive", "x": 150, "y": 190}, {"id": "tavern", "x": 440, "y": 480},
                {"id": "docks", "x": 760, "y": 330}, {"id": "quarry", "x": 880, "y": 160},
                {"id": "green", "x": 600, "y": 130},
            ],
            "roads": [["house", "square"], ["square", "market"], ["square", "forge"], ["square", "archive"],
                      ["square", "tavern"], ["market", "docks"], ["docks", "quarry"], ["square", "green"]],
        },
    }
    for id, (top, bottom, label) in PLACES.items():
        background(id, top, bottom, label)
        manifest["backgrounds"].append({"id": id, "file": f"assets/bg-{id}.svg"})
    for id, (color, label) in NPCS.items():
        for expression in EXPRESSIONS:
            f = figure(id, expression, color, "#f1d3b0", label)
            manifest["sprites"].append({"character": id, "attributes": {"expression": expression}, "file": "assets/" + f})
            f = figure(id, expression, color, "#f1d3b0", label, portrait=True)
            manifest["portraits"].append({"character": id, "attributes": {"expression": expression}, "file": "assets/" + f})
    for outfit, color in OUTFITS.items():
        for expression in EXPRESSIONS:
            f = figure(f"player-{outfit}", expression, color, "#f1d3b0", "You")
            manifest["sprites"].append({"character": "player", "attributes": {"outfit": outfit, "expression": expression},
                                        "file": "assets/" + f})
            f = figure(f"player-{outfit}", expression, color, "#f1d3b0", "You", portrait=True)
            manifest["portraits"].append({"character": "player", "attributes": {"outfit": outfit, "expression": expression},
                                          "file": "assets/" + f})
    music = {
        "title_theme": (196, [0, 2, 3, 2, 4, 3, 2, 0]),
        "day_theme": (262, [0, 1, 2, 3, 2, 1, 2, 4]),
        "trial_theme": (220, [0, 0, 3, 3, 4, 3, 2, 3]),
        "ending_theme": (175, [3, 2, 1, 0, 1, 2, 3, 4]),
    }
    for id, (base, steps) in music.items():
        tone(id + ".wav", len(steps) * 0.5, melody(base, steps))
        manifest["audio"].append({"id": id, "file": f"assets/{id}.wav"})
    tone("stat_up.wav", 0.3, [(660, 0, 0.12), (880, 0.12, 0.18)])
    tone("click.wav", 0.08, [(440, 0, 0.07)])
    tone("fail.wav", 0.35, [(220, 0, 0.17), (165, 0.17, 0.18)])
    for id in ("stat_up", "click", "fail"):
        manifest["audio"].append({"id": id, "file": f"assets/{id}.wav"})
    (ROOT / "presentation.json").write_text(json.dumps(manifest, indent=1) + "\n")


main()
