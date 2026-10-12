#!/usr/bin/env python3
"""`varis l10n`: extraction, change detection, status and the CSV adapter (stage T1).

    python3 tests/l10n/l10n_test.py <varis binary> [--update]

Works on a scratch copy of the sample game so that nothing in the repository changes.
"""
import csv
import io
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent


def varis(binary, cwd, *args, expect=0):
    done = subprocess.run([binary, *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    assert done.returncode == expect, (args, done.returncode, done.stdout, done.stderr)
    return done.stdout


def main():
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    update = "--update" in sys.argv
    work = pathlib.Path(tempfile.mkdtemp(prefix="varis-l10n-"))
    try:
        game = work / "game"
        shutil.copytree(ROOT / "sample-game", game)
        manifest = (game / "project.lua").read_text().replace("locales  = {}", 'locales  = { "fr" }')
        (game / "project.lua").write_text(manifest)

        # Extraction is deterministic and golden.
        out = varis(binary, game, "l10n", "extract")
        assert "+65 -0 ~0" in out and "1 text(s) built by code" in out, out
        source = (game / "l10n" / "source.json").read_text()
        golden = HERE / "sample_game.source.expected.json"
        if update:
            golden.write_text(source)
        else:
            assert golden.read_text() == source, "source catalog differs from tests/l10n/sample_game.source.expected.json"
        catalog = json.loads(source)
        keys = {m["key"]: m for m in catalog["messages"]}
        assert len(keys) == len(catalog["messages"]) == 65
        assert keys["lamp.light.title"]["text"] == "Strike a match and light it"
        assert keys["look.text"]["arguments"] == ["room"]
        assert keys["quality.oil.label"]["text"] == "Lamp oil"
        assert "(up to date)" in varis(binary, game, "l10n", "extract", "--check")

        # Every title, text and label has a key or a computed-text diagnostic.
        check = json.loads(varis(binary, game, "check", "--json"))
        computed = [p for p in check["problems"] if p["code"] == "computed-text"]
        assert [(p["file"], p["line"]) for p in computed] == [("qualities.lua", 21)], computed

        # CSV round trip: export, translate three rows, import.
        out = varis(binary, game, "l10n", "export", "--locale", "fr", "--out", "fr.csv")
        rows = list(csv.reader(io.StringIO((game / "fr.csv").read_text(encoding="utf-8-sig"))))
        assert rows[0][:3] == ["key", "source", "translation"] and len(rows) == 66, len(rows)
        wanted = {"lamp.light.title": "Craquer une allumette et l'allumer",
                  "lamp.title": "La grande lampe",
                  "quality.oil.label": "Huile de lampe"}
        for row in rows[1:]:
            if row[0] in wanted:
                row[2] = wanted[row[0]]
        buffer = io.StringIO()
        csv.writer(buffer).writerows(rows)
        (game / "fr.csv").write_text(buffer.getvalue(), encoding="utf-8")
        out = varis(binary, game, "l10n", "import", "fr.csv", "--locale", "fr")
        assert "3 draft" in out and "nothing written" in out, out
        assert not (game / "l10n" / "fr.json").exists()
        varis(binary, game, "l10n", "import", "fr.csv", "--locale", "fr", "--apply")
        fr = json.loads((game / "l10n" / "fr.json").read_text())
        assert {e["key"]: e["status"] for e in fr["entries"]} == {k: "draft" for k in wanted}
        status = varis(binary, game, "l10n", "status")
        assert "fr: 0 reviewed, 3 draft, 0 stale, 62 untranslated" in status, status

        # Translated rendering: play in the translation, the key overlay, the pseudo-locale.
        play = subprocess.run([binary, "play", "--locale", "fr", "--seed", "7", "--keys"], cwd=game, input="quit\n",
                              capture_output=True, text=True, timeout=60).stdout
        assert "[look.title] Look around" in play  # no French for that one: the source text is the fallback
        pseudo = subprocess.run([binary, "play", "--locale", "x-pseudo", "--seed", "7"], cwd=game, input="quit\n",
                                capture_output=True, text=True, timeout=60).stdout
        assert "[Lóók áróúñd" in pseudo and "~~~]" in pseudo, pseudo

        # Checking a locale: placeholders, conditions and variants must come from the source.
        check = subprocess.run([binary, "check", "--locale", "fr", "--json"], cwd=game, capture_output=True, text=True)
        assert [p for p in json.loads(check.stdout)["problems"] if p["code"].startswith("translation-")] == []
        fr_path = game / "l10n" / "fr.json"
        fr = json.loads(fr_path.read_text())
        fr["entries"].append({"key": "look.title", "text": "Regarder {inconnu}", "status": "draft",
                              "revision": keys["look.title"]["revision"]})
        fr["entries"].append({"key": "look.text", "text": "{#if query lampe()}x{/if}{#variant}a{/variant}",
                              "status": "draft", "revision": keys["look.text"]["revision"]})
        fr["entries"].append({"key": "walk.title", "text": "{#if broken", "status": "draft",
                              "revision": keys["walk.title"]["revision"]})
        fr_path.write_text(json.dumps(fr))
        check = subprocess.run([binary, "check", "--locale", "fr", "--json"], cwd=game, capture_output=True, text=True)
        codes = sorted(p["code"] for p in json.loads(check.stdout)["problems"] if p["code"].startswith("translation-"))
        assert codes == ["translation-condition", "translation-placeholder", "translation-syntax", "translation-variants"], codes
        assert check.returncode == 1
        # The release gate: everything reviewed, or it does not pass.
        gate = subprocess.run([binary, "l10n", "check", "--locale", "fr", "--require", "reviewed"], cwd=game,
                              capture_output=True, text=True)
        assert gate.returncode == 1 and "release gate" in gate.stdout
        fr["entries"] = fr["entries"][:3]
        fr_path.write_text(json.dumps(fr))

        # An unknown placeholder is rejected and nothing is written for it.
        bad = list(csv.reader(io.StringIO((game / "fr.csv").read_text())))
        for row in bad[1:]:
            if row[0] == "lamp.title":
                row[2] = "La lampe de {inconnu}"
        buffer = io.StringIO()
        csv.writer(buffer).writerows(bad)
        (game / "bad.csv").write_text(buffer.getvalue())
        out = varis(binary, game, "l10n", "import", "bad.csv", "--locale", "fr", "--apply", expect=1)
        assert "unknown placeholder {inconnu}" in out and "1 rejected" in out, out

        # A cosmetic edit (case, punctuation) keeps the translation; a substantive one stales it.
        lamp = game / "content" / "lamp.lua"
        text = lamp.read_text()
        lamp.write_text(text.replace('title "The great lamp"', 'title "The Great Lamp!"'))
        out = varis(binary, game, "l10n", "extract")
        assert "changed (cosmetic): lamp.title" in out, out
        fr = json.loads((game / "l10n" / "fr.json").read_text())
        assert {e["key"]: e["status"] for e in fr["entries"]}["lamp.title"] == "draft"
        lamp.write_text(text.replace('title "The great lamp"', 'title "The enormous lamp"'))
        out = varis(binary, game, "l10n", "extract")
        assert "changed (substantive): lamp.title" in out, out
        fr = json.loads((game / "l10n" / "fr.json").read_text())
        states = {e["key"]: e["status"] for e in fr["entries"]}
        assert states == {"lamp.light.title": "draft", "lamp.title": "stale", "quality.oil.label": "draft"}, states
        # With the source changed and not extracted, --check fails.
        lamp.write_text(text.replace('title "The great lamp"', 'title "A third lamp"'))
        out = varis(binary, game, "l10n", "extract", "--check", expect=1)
        assert "out of date" in out, out

        # Handoff (stage T4): a kit with XLIFF, the publisher's checks, import, a delta kit, packs.
        lamp.write_text(text)
        varis(binary, game, "l10n", "extract")
        out = varis(binary, game, "l10n", "export", "--locale", "ja,ko", "--format", "xliff", "--kit", "kit")
        kit = json.loads((game / "kit" / "kit.json").read_text())
        assert kit["locales"] == ["ja", "ko"] and len(kit["kit"]) == 16, kit
        assert (game / "kit" / "ja.xlf").exists() and (game / "kit" / "glossary.json").exists()
        charset = json.loads((game / "kit" / "charset.json").read_text())
        assert "A" in charset["source"] and charset["ja"] == "", charset
        xlf = (game / "kit" / "ja.xlf").read_text()
        assert '<trans-unit id="lamp.title"' in xlf and "arguments:" in xlf and "shown when:" in xlf
        # The translator fills in targets (here: Japanese for two messages, one with a bad placeholder).
        filled = xlf.replace('<source xml:lang="en">The great lamp</source>\n    <target xml:lang="ja" state="new"></target>',
                             '<source xml:lang="en">The great lamp</source>\n    <target xml:lang="ja" state="translated">大きなランプ</target>', 1)
        filled = filled.replace('<source xml:lang="en">Wait a while</source>\n    <target xml:lang="ja" state="new"></target>',
                                '<source xml:lang="en">Wait a while</source>\n    <target xml:lang="ja" state="translated">{nope}しばらく待つ</target>', 1)
        assert filled != xlf
        (game / "ja.xlf").write_text(filled)
        out = varis(binary, game, "l10n", "check", "--kit", "kit", "ja.xlf", expect=1)
        assert "translation-placeholder" in out and "{nope}" in out, out
        out = varis(binary, game, "l10n", "import", "ja.xlf", "--locale", "ja", "--kit", "kit", "--apply", expect=1)
        assert "1 draft" in out and "1 rejected" in out, out
        ja = json.loads((game / "l10n" / "ja.json").read_text())
        assert [e["text"] for e in ja["entries"]] == ["大きなランプ"], ja
        # Review is the only way to `reviewed`.
        out = varis(binary, game, "l10n", "review", "--locale", "ja")
        assert "1 marked reviewed" in out, out
        # The source changes after the handoff: a delta kit holds only what changed, with old English.
        old_kit = kit["kit"]
        lamp.write_text(text.replace('title "The great lamp"', 'title "The huge lamp"'))
        varis(binary, game, "l10n", "extract")
        varis(binary, game, "l10n", "export", "--locale", "ja", "--format", "xliff", "--kit", "kit-delta", "--changed-since", old_kit)
        delta = (game / "kit-delta" / "ja.xlf").read_text()
        assert delta.count("<trans-unit") == 1 and "The huge lamp" in delta, delta.count("<trans-unit")
        assert "<note from=\"varis-previous-source\">The great lamp</note>" in delta and "大きなランプ" in delta
        # The previous translation is now stale; a pack leaves it out, so the source text shows.
        status = varis(binary, game, "l10n", "check", "--locale", "ja")
        assert "ja: 0 reviewed, 0 draft, 1 stale" in status, status
        lamp.write_text(text)
        varis(binary, game, "l10n", "extract")
        # Packs: built only from a catalog that passes; loaded whole, or rejected whole by key.
        manifest_text = (game / "project.lua").read_text().replace('locales  = { "fr" }', 'locales  = { "fr", "ja" }')
        (game / "project.lua").write_text(manifest_text)
        out = varis(binary, game, "l10n", "build", "--out", "packs")
        assert "ja: pack of 1 message(s)" in out, out
        pack = json.loads((game / "packs" / "ja" / "pack.json").read_text())
        assert pack["locale"] == "ja" and pack["messages"] == {"lamp.title": "大きなランプ"} and "大" in pack["charset"]
        play_pack = subprocess.run([binary, "play", "--pack", "packs/ja", "--seed", "7", "--keys"], cwd=game, input="quit\n",
                                   capture_output=True, text=True, timeout=60).stdout
        assert "Look around" in play_pack  # the pack loaded; look.title is untranslated and falls back
        (game / "packs" / "ja" / "pack.json").write_text(json.dumps({"format": 1, "locale": "ja",
                                                                      "messages": {"lamp.title": "{#if broken"}}))
        rejected = subprocess.run([binary, "play", "--pack", "packs/ja", "--seed", "7"], cwd=game, input="quit\n",
                                  capture_output=True, text=True, timeout=60).stdout
        assert "language pack rejected" in rejected and "ja lamp.title" in rejected, rejected

        # A renamed choice is reported as a probable rename and its translation can be carried.
        lamp.write_text(text)
        varis(binary, game, "l10n", "extract")
        lamp.write_text(text.replace("choice light\n", "choice ignite\n"))
        out = varis(binary, game, "l10n", "extract", "--carry-renames")
        assert "probable rename: lamp.light.title -> lamp.ignite.title" in out, out
        fr = json.loads((game / "l10n" / "fr.json").read_text())
        assert "lamp.ignite.title" in {e["key"] for e in fr["entries"]}
        print("l10n tests passed")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
