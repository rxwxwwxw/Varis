/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The SDL3 front end for whole games (a manifest with a `project`): title screen, the storylet
/// hub with a status panel, scenes, overlays (character sheet, journal, map, help, history),
/// a pause menu with settings, toasts and an ending screen. It draws from `GameHost.view` only;
/// the engine runs once per player action.
module tools.sdl.gameplayer;

import tools.sdl.native;
import varis.services.gamehost;
import varis.services.presentation : SceneView, StageCharacter;
import varis.services.json;
import varis.narrative.scenes : field, nameOf;
import varis.types;
import std.file : readText, write, exists;
import std.path : buildPath, dirName, isAbsolute;
import std.string : toStringz, fromStringz;
import std.stdio : stderr, writeln;
import std.conv : to;
import std.format : format;

private enum uint panelColor = 0x101a2eee, accentColor = 0x9bdbd9ff, textColor = 0xffffffff, dimColor = 0x9aa7bbff,
    lockedColor = 0x6b7587ff, badColor = 0xe8847cff, goodColor = 0x9fe0a0ff, barBack = 0x243049ff, rowColor = 0x1a2740ee,
    rowSelected = 0x356b80ee;

private struct Image {
    string id, character;
    JsonValue match;
    void* texture;
}

private struct Slot {
    string id;
    float x, y, width, height;
}

private struct Sound {
    string id;
    void* sound;
}

private struct Channel {
    string id, playing;
    bool loop;
    void* track;
}

private struct Language {
    string tag, name;
}

private struct Node {
    string id;
    float x, y;
}

private struct Row {
    size_t story, choice;
    string label;
    bool enabled;
}

private struct ToastView {
    string text;
    bool good;
    ulong born;
}

enum Mode {
    title,
    play,
    over
}

enum Overlay {
    none,
    pause,
    sheet,
    journal,
    map,
    help,
    history,
    language
}

class GamePlayer {
    GameHost host;
    Image[] backgrounds, sprites, portraits;
    Slot[] slots;
    Sound[] sounds;
    Channel[] channels;
    Language[] languages;
    Node[] nodes;
    string[][string] roads;
    string[] clock;
    string[] choiceLabels; // storylets whose rows are labelled by the choice, not the storylet
    string root, savePath, autosavePath, settingsPath, title, seedText;
    string[] history;
    void*[string] cache;
    void* fontSmall, fontBig, fontHuge;
    Mode mode;
    Overlay overlay;
    Row[] rows;
    int selected, scroll, menuIndex;
    float mouseX, mouseY;
    ToastView[] toasts;
    string notice, input;
    ulong entered, noticeAt;
    long seed;
    int volume = 8;
    bool fullscreen, failed, sawEnding;
    string fontPath;
    float fontSize = 22;

    string path(string value) {
        return isAbsolute(value) ? value : buildPath(root, value);
    }

    bool fail(string message) {
        failed = true;
        stderr.writeln(message);
        return false;
    }

    bool images(const JsonValue* config, ref Image[] list) {
        if (config is null)
            return true;
        if (config.kind != JsonValue.Kind.array)
            return fail("image groups must be arrays");
        foreach (ref item; config.items) {
            auto file = item.stringOr("file");
            if (!file.length)
                return fail("image requires file");
            Image image;
            image.id = item.stringOr("id");
            image.character = item.stringOr("character");
            if (auto m = item.get("attributes")) {
                if (m.kind != JsonValue.Kind.object)
                    return fail("sprite attributes must be an object");
                image.match = *cast(JsonValue*) m;
            }
            image.texture = v_image(path(file).toStringz);
            if (!image.texture)
                return fail("image " ~ file ~ ": " ~ fromStringz(v_error()).idup);
            list ~= image;
        }
        return true;
    }

    bool load(string manifest, bool hidden) {
        root = dirName(manifest);
        JsonValue config;
        string error;
        if (!parseJson(readText(manifest), config, error))
            return fail(error);
        auto project = config.stringOr("project", ".");
        title = config.stringOr("title", "Varis");
        host = new GameHost;
        if (!host.loadProject(path(project), config.stringOr("scene")))
            return fail(host.error);
        auto font = config.stringOr("font");
        if (font.length)
            font = path(font);
        else {
            foreach (candidate; [
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "C:/Windows/Fonts/arial.ttf"
            ])
                if (!font.length && exists(candidate))
                    font = candidate;
        }
        if (!font.length)
            return fail("manifest requires a font file on this platform");
        fontPath = font;
        fontSize = config.integerOr("font_size", 22);
        if (fontSize < 8 || fontSize > 96)
            return fail("font_size must be between 8 and 96");
        if (!v_open(title.toStringz, font.toStringz, fontSize, hidden))
            return fail(fromStringz(v_error()).idup);
        fontSmall = v_font(font.toStringz, fontSize * 0.8f);
        fontBig = v_font(font.toStringz, fontSize * 1.5f);
        fontHuge = v_font(font.toStringz, fontSize * 2.4f);
        savePath = path(config.stringOr("save", "quicksave.json"));
        autosavePath = path(config.stringOr("autosave", "autosave.json"));
        settingsPath = path(config.stringOr("settings", "settings.json"));
        seed = config.integerOr("seed", 0);
        if (!images(config.get("backgrounds"), backgrounds) || !images(config.get("sprites"), sprites) ||
                !images(config.get("portraits"), portraits))
            return false;
        if (auto values = config.get("slots"))
            foreach (ref s; values.items)
                slots ~= Slot(s.stringOr("id"), s.integerOr("x"), s.integerOr("y"), s.integerOr("width", 400),
                        s.integerOr("height", 650));
        if (!slots.length)
            slots = [
            Slot("left", 80, 40, 400, 400), Slot("center", 440, 40, 400, 400),
            Slot("right", 800, 40, 400, 400)
        ];
        if (auto values = config.get("audio"))
            foreach (ref s; values.items) {
                auto file = s.stringOr("file");
                auto sound = v_sound(path(file).toStringz);
                if (!sound)
                    return fail("audio " ~ file ~ ": " ~ fromStringz(v_error()).idup);
                sounds ~= Sound(s.stringOr("id"), sound);
            }
        if (auto values = config.get("channels"))
            foreach (ref s; values.items) {
                auto track = v_channel();
                if (!track)
                    return fail(fromStringz(v_error()).idup);
                channels ~= Channel(s.stringOr("id"), "", s.integerOr("loop", 1) != 0, track);
            }
        languages = [Language("", "English")];
        if (auto values = config.get("languages")) {
            languages = null;
            foreach (ref l; values.items)
                languages ~= Language(l.stringOr("tag"), l.stringOr("name", l.stringOr("tag")));
        }
        if (auto values = config.get("map")) {
            if (auto list = values.get("places"))
                foreach (ref n; list.items)
                    nodes ~= Node(n.stringOr("id"), n.integerOr("x"), n.integerOr("y"));
            if (auto list = values.get("roads"))
                foreach (ref r; list.items)
                    if (r.items.length == 2)
                        roads[r.items[0].text] ~= r.items[1].text;
        }
        if (auto values = config.get("choice_labels"))
            foreach (ref c; values.items)
                choiceLabels ~= c.text;
        clock = ["Morning", "Afternoon", "Evening", "Night"];
        if (auto values = config.get("clock")) {
            clock = null;
            foreach (ref c; values.items)
                clock ~= c.text;
        }
        loadSettings();
        v_volume(volume / 10.0f);
        return true;
    }

    // ---- settings ------------------------------------------------------------------

    void loadSettings() {
        if (!exists(settingsPath))
            return;
        JsonValue v;
        string error;
        if (!parseJson(readText(settingsPath), v, error))
            return;
        volume = cast(int) v.integerOr("volume", volume);
        if (volume < 0 || volume > 10)
            volume = 8;
        fullscreen = v.integerOr("fullscreen", 0) != 0;
        auto tag = v.stringOr("language");
        foreach (ref l; languages)
            if (l.tag == tag)
                host.language = tag;
        if (fullscreen)
            v_fullscreen(1);
    }

    void saveSettings() {
        write(settingsPath, format(`{"volume":%d,"fullscreen":%d,"language":"%s"}`, volume, fullscreen ? 1 : 0,
                host.language));
    }

    // ---- text ----------------------------------------------------------------------

    void* textureFor(void* font, string value, int wrap, uint color) {
        if (!value.length)
            return null;
        auto key = format("%x|%d|%x|", cast(size_t) font, wrap, color) ~ value;
        if (auto found = key in cache)
            return *found;
        if (cache.length > 600) {
            foreach (texture; cache)
                v_free(texture);
            cache = null;
        }
        auto texture = font is null ? v_text(value.toStringz, wrap, color) : v_text_font(font, value.toStringz, wrap, color);
        cache[key] = texture;
        return texture;
    }

    /// Draws text at (x, y); wrap 0 does not wrap. Returns the rendered height.
    float label(void* font, string value, float x, float y, int wrap = 0, uint color = textColor) {
        auto texture = textureFor(font, value, wrap, color);
        if (texture is null)
            return 0;
        float w, h;
        v_text_size(texture, &w, &h);
        v_draw(texture, x, y, 0, 0, 2, 1);
        return h;
    }

    float labelRight(void* font, string value, float right, float y, uint color = textColor) {
        auto texture = textureFor(font, value, 0, color);
        if (texture is null)
            return 0;
        float w, h;
        v_text_size(texture, &w, &h);
        v_draw(texture, right - w, y, 0, 0, 2, 1);
        return h;
    }

    float labelCentre(void* font, string value, float centre, float y, uint color = textColor) {
        auto texture = textureFor(font, value, 0, color);
        if (texture is null)
            return 0;
        float w, h;
        v_text_size(texture, &w, &h);
        v_draw(texture, centre - w / 2, y, 0, 0, 2, 1);
        return h;
    }

    // ---- images and audio ----------------------------------------------------------

    void* characterImage(Image[] list, string character, LuaValue attributes) {
        void* found;
        size_t best;
        bool matched;
        foreach (ref image; list) {
            if (image.character != character)
                continue;
            bool matches = true;
            foreach (i, key; image.match.keys)
                if (nameOf(field(attributes, key)) != image.match.items[i].text)
                    matches = false;
            if (matches && (!matched || image.match.keys.length > best)) {
                found = image.texture;
                best = image.match.keys.length;
                matched = true;
            }
        }
        return found;
    }

    void syncAudio() {
        auto audio = host.view.beat.audio;
        foreach (ref c; channels) {
            auto tag = nameOf(field(audio, c.id));
            if (tag == c.playing)
                continue;
            void* sound;
            foreach (ref a; sounds)
                if (a.id == tag)
                    sound = a.sound;
            if (tag.length && sound is null)
                continue; // an unmapped tag is silent, not fatal
            v_play(c.track, sound, c.loop);
            c.playing = tag;
        }
    }

    // ---- flow ----------------------------------------------------------------------

    bool newGame() {
        if (!seed)
            seed = cast(long)(v_ticks() & 0x7fffffff) + 1;
        history = null;
        if (!host.newGame(seed))
            return fail(host.error);
        mode = Mode.play;
        overlay = Overlay.none;
        sawEnding = false;
        return afterBoundary();
    }

    bool continueGame() {
        if (!exists(autosavePath))
            return newGame();
        history = null;
        if (!host.restore(readText(autosavePath))) {
            notice = host.error;
            noticeAt = v_ticks();
            return true;
        }
        mode = Mode.play;
        overlay = Overlay.none;
        return afterBoundary();
    }

    /// After every boundary: acknowledge media beats, rebuild rows, queue toasts, sync audio.
    bool afterBoundary() {
        for (size_t guard; guard < 200; ++guard) {
            auto v = host.view;
            if (!v.inScene)
                break;
            auto kind = v.beat.kind;
            bool media = kind == "background" || kind == "show" || kind == "hide" || kind == "audio" ||
                kind == "transition" || kind == "pause" || kind == "ended";
            if (!media)
                break;
            if (!host.advance())
                return fail(host.error);
        }
        entered = v_ticks();
        selected = scroll = 0;
        input = "";
        rows = null;
        auto v = host.view;
        if (!v.inScene)
            foreach (i, ref story; v.stories)
                foreach (j, ref choice; story.choices) {
                    Row row;
                    row.story = i;
                    row.choice = j;
                    row.enabled = choice.enabled;
                    bool byChoice;
                    foreach (id; choiceLabels)
                        byChoice = byChoice || id == story.id;
                    row.label = byChoice ? choice.title : story.choices.length == 1 ? story.title
                        : story.title ~ ": " ~ choice.title;
                    rows ~= row;
                } else if (v.beat.kind == "say" || v.beat.kind == "narration")
            history ~= (v.beat.speaker.length ? v.beat.speaker ~ ": " : "") ~ v.beat.text;
        foreach (t; host.takeToasts())
            toasts ~= ToastView(t.text, t.good, v_ticks());
        syncAudio();
        if (v.over && !v.inScene)
            mode = Mode.over;
        return true;
    }

    bool choose(size_t row) {
        if (row >= rows.length)
            return true;
        auto r = rows[row];
        if (!r.enabled) {
            notice = host.view.stories[r.story].choices[r.choice].because;
            noticeAt = v_ticks();
            return true;
        }
        if (!host.choose(r.story, r.choice))
            return fail(host.error);
        autosave();
        return afterBoundary();
    }

    void autosave() {
        string bytes;
        if (host.save(bytes))
            write(autosavePath, bytes);
    }

    bool advance(LuaValue value = LuaValue.init) {
        if (!host.advance(value))
            return fail(host.error);
        return afterBoundary();
    }

    // ---- drawing -------------------------------------------------------------------

    void drawStage() {
        auto v = host.view.beat;
        foreach (ref image; backgrounds)
            if (image.id == v.background)
                v_draw(image.texture, 0, 0, 1280, 720, 0, 1);
        foreach (ref slot; slots)
            foreach (ref c; v.characters)
                if (c.slot == slot.id)
                    v_draw(characterImage(sprites, c.id, c.attributes), slot.x, slot.y, slot.width, slot.height, 1, 1);
        // Time of day is a tint, not a different set of backgrounds.
        auto slotValue = host.view.values.get("slot", 1);
        if (slotValue >= 3)
            v_rect(0, 0, 1280, 720, slotValue >= 4 ? 0x0a0a3a88 : 0x2a124a44);
    }

    void drawBar(float x, float y, float w, float fraction, uint color) {
        v_rect(x, y, w, 10, barBack);
        if (fraction < 0)
            fraction = 0;
        if (fraction > 1)
            fraction = 1;
        v_rect(x, y, w * fraction, 10, color);
    }

    void drawHud() {
        auto v = host.view;
        v_rect(0, 0, 1280, 40, panelColor);
        string place = host.display(v.beat.background);
        label(fontBig, place.length ? place : title, 16, 4);
        auto day = v.values.get("day", 1);
        auto time = cast(size_t) v.values.get("slot", 1);
        string timeLabel = time >= 1 && time <= clock.length ? clock[time - 1] : "";
        labelCentre(fontBig, format("Day %d, %s", cast(long) day, timeLabel), 640, 4);
        labelRight(fontBig, format("%d coins", cast(long) v.values.get("coins", 0)), 1264, 4, 0xffe08aff);
        // Stat panel
        float y = 52;
        size_t shown;
        foreach (ref stat; v.hud)
            if (stat.id != "coins" && stat.id != "day")
                ++shown;
        v_rect(8, y - 6, 250, 12 + 36 * cast(float) shown, panelColor);
        foreach (ref stat; v.hud) {
            if (stat.id == "coins" || stat.id == "day")
                continue;
            label(fontSmall, stat.label, 18, y);
            labelRight(fontSmall, format("%d", cast(long) stat.value), 246, y);
            float span = stat.hasMaximum ? stat.maximum - stat.minimum : 100;
            uint color = stat.id == "stamina" && stat.value <= 2 ? badColor : accentColor;
            drawBar(18, y + 24, 224, span > 0 ? (stat.value - stat.minimum) / span : 0, color);
            y += 36;
        }
    }

    void drawToasts() {
        float y = 52;
        auto now = v_ticks();
        ToastView[] alive;
        foreach (ref t; toasts) {
            auto age = now - t.born;
            if (age > 3600)
                continue;
            alive ~= t;
            float fade = age > 2800 ? 1.0f - (age - 2800) / 800.0f : 1.0f;
            auto texture = textureFor(fontSmall, t.text, 0, t.good ? goodColor : badColor);
            if (texture is null)
                continue;
            float w, h;
            v_text_size(texture, &w, &h);
            v_rect(1270 - w - 20, y, w + 16, h + 8, cast(uint)(0x101a2e00 | cast(uint)(220 * fade)));
            v_draw(texture, 1270 - w - 12, y + 4, 0, 0, 2, fade);
            y += h + 12;
        }
        toasts = alive;
    }

    void drawHub() {
        auto v = host.view;
        v_rect(0, 400, 1280, 320, panelColor);
        // Narrative panel: the ambient text, or the text of the row under the pointer.
        string text;
        string reason;
        if (selected >= 0 && selected < cast(int) rows.length) {
            auto r = rows[selected];
            auto story = v.stories[r.story];
            if (story.text.length && story.choices.length == 1 || !story.text.length)
                text = story.text;
            else
                text = story.text;
            if (!r.enabled)
                reason = story.choices[r.choice].because;
            else if (story.choices[r.choice].text.length)
                text ~= (text.length ? "\n\n" : "") ~ story.choices[r.choice].text;
        }
        string ambient;
        foreach (ref s; v.stories)
            if (s.text.length && s.id == "look") {
                ambient = s.text;
                break;
            }
        float ty = 412;
        ty += label(null, ambient, 24, ty, 560, textColor) + 8;
        if (text.length && text != ambient)
            ty += label(fontSmall, text, 24, ty + 4, 560, accentColor) + 8;
        if (reason.length)
            label(fontSmall, reason, 24, ty + 4, 560, badColor);
        if (notice.length && v_ticks() - noticeAt < 4000)
            label(fontSmall, notice, 24, 686, 560, badColor);
        // Choice list
        enum visible = 8;
        enum rowHeight = 36;
        if (selected < scroll)
            scroll = selected;
        if (selected >= scroll + visible)
            scroll = selected - visible + 1;
        float x = 610;
        for (int i = scroll; i < cast(int) rows.length && i < scroll + visible; ++i) {
            float ry = 408 + (i - scroll) * rowHeight;
            bool hot = i == selected;
            v_rect(x, ry, 650, rowHeight - 4, hot ? rowSelected : rowColor);
            auto r = rows[i];
            string tag = i < 9 ? format("%d  ", i + 1) : "    ";
            label(fontSmall, tag ~ r.label, x + 10, ry + 5, 0, r.enabled ? textColor : lockedColor);
            if (!r.enabled)
                labelRight(fontSmall, "locked", x + 640, ry + 5, lockedColor);
        }
        if (scroll > 0)
            labelRight(fontSmall, "^", 1262, 400, dimColor);
        if (scroll + visible < cast(int) rows.length)
            labelRight(fontSmall, "v", 1262, 690, dimColor);
        label(fontSmall, "Up/Down, 1-9, Enter: choose   C: sheet   J: journal   M: map   Esc: menu   F1: help", 24, 700, 0,
                dimColor);
    }

    void drawScene() {
        auto v = host.view.beat;
        if (v.kind == "menu") {
            v_rect(180, 60, 920, 40 + 72 * cast(float) v.choices.length, 0x101a2ecc);
            foreach (i, ref c; v.choices) {
                float y = 80 + i * 72;
                v_rect(190, y, 900, 64, cast(int) i == selected ? rowSelected : rowColor);
                label(null, c.text, 215, y + 14, 850, textColor);
            }
        } else {
            v_rect(24, 490, 1232, 200, panelColor);
            foreach (ref c; v.characters)
                if (c.id == v.character) {
                    auto portrait = characterImage(portraits, c.id, c.attributes);
                    if (portrait !is null)
                        v_draw(portrait, 34, 500, 140, 170, 1, 1);
                }
            label(fontBig, v.speaker, 190, 498, 0, accentColor);
            string body = v.kind == "input" ? v.text ~ "\n> " ~ input ~ "_" : v.text;
            label(null, body, 190, 540, 1030, textColor);
            label(fontSmall, v.kind == "input" ? "Type, then Enter" : "Enter or click to continue    H: history", 24, 694, 0,
                    dimColor);
        }
    }

    void drawPanel(string heading, float x = 140, float y = 60, float w = 1000, float h = 600) {
        v_rect(0, 0, 1280, 720, 0x000000a0);
        v_rect(x, y, w, h, 0x101a2efa);
        v_outline(x, y, w, h, accentColor);
        label(fontBig, heading, x + 24, y + 14, 0, accentColor);
    }

    void drawSheet() {
        drawPanel("Character");
        float y = 130;
        foreach (ref stat; host.view.hud) {
            if (stat.id == "day")
                continue;
            label(null, stat.label, 180, y);
            labelRight(null, format("%d", cast(long) stat.value), 480, y);
            float span = stat.hasMaximum ? stat.maximum - stat.minimum : 100;
            drawBar(500, y + 12, 300, span > 0 ? (stat.value - stat.minimum) / span : 0, accentColor);
            y += 44;
        }
        label(fontSmall, "Esc: close", 180, 628, 0, dimColor);
    }

    void drawJournal() {
        drawPanel("Journal");
        float y = 120;
        foreach (ref section; host.journal()) {
            y += label(fontBig, section.title, 180, y, 0, accentColor) + 4;
            foreach (ref line; section.lines)
                y += label(fontSmall, "  " ~ line, 190, y, 900, textColor) + 2;
            y += 8;
        }
        label(fontSmall, "Esc: close", 180, 628, 0, dimColor);
    }

    void drawMap() {
        drawPanel("Hollowbrook");
        auto state = host.mapState();
        float ox = 140, oy = 60;
        foreach (from, list; roads)
            foreach (to; list)
                foreach (ref a; nodes)
                    if (a.id == from)
                        foreach (ref b; nodes)
                            if (b.id == to) {
                                float dx = b.x - a.x, dy = b.y - a.y;
                                int steps = 24;
                                foreach (s; 0 .. steps)
                                    v_rect(ox + a.x + dx * s / steps, oy + a.y + dy * s / steps, 3, 3, dimColor);
                            }
        foreach (ref n; nodes) {
            bool here = n.id == state.at;
            bool open = (n.id in state.reachable) !is null;
            v_rect(ox + n.x - 10, oy + n.y - 10, 20, 20, here ? 0xffe08aff : open ? accentColor : lockedColor);
            labelCentre(fontSmall, host.display(n.id), ox + n.x, oy + n.y + 14, open ? textColor : lockedColor);
        }
        label(fontSmall, "Click a place you can reach to go there. Esc: close", 180, 628, 0, dimColor);
    }

    void drawHelp() {
        drawPanel("How to play");
        float y = 120;
        foreach (line; [
            "Spend ten days getting ready for the Midsummer Trials.", "",
            "Each activity uses a part of the day (morning, afternoon, evening).",
            "Stats rise by training. Many choices need a stat to be high enough:",
            "locked choices say what they want.", "",
            "Up/Down and Enter, a number key, or the mouse: choose.",
            "C character sheet   J journal   M map   H history   F5 save   F9 load",
            "Esc: menu (settings, language, quit)."
        ])
            y += label(null, line, 180, y, 900) + 6;
    }

    void drawHistory() {
        drawPanel("Recent lines");
        string log;
        auto start = history.length > 8 ? history.length - 8 : 0;
        foreach (line; history[start .. $])
            log ~= line ~ "\n\n";
        label(fontSmall, log, 180, 110, 900);
    }

    void drawPause() {
        drawPanel("Paused", 440, 120, 400, 440);
        string[] items = [
            "Resume", "Save (F5)", "Load (F9)", "Language: " ~ currentLanguage(),
            "Volume: " ~ to!string(volume),
            fullscreen ? "Fullscreen: on" : "Fullscreen: off", "Quit to title"
        ];
        foreach (i, item; items) {
            float y = 180 + i * 48;
            v_rect(460, y, 360, 40, cast(int) i == menuIndex ? rowSelected : rowColor);
            labelCentre(null, item, 640, y + 6);
        }
        if (notice.length && v_ticks() - noticeAt < 3000)
            labelCentre(fontSmall, notice, 640, 530, goodColor);
    }

    string currentLanguage() {
        foreach (ref l; languages)
            if (l.tag == host.language)
                return l.name;
        return "English";
    }

    void drawTitle() {
        v_rect(0, 0, 1280, 720, 0x0e1424ff);
        foreach (ref image; backgrounds)
            if (image.id == "title")
                v_draw(image.texture, 0, 0, 1280, 720, 0, 1);
        v_rect(0, 0, 1280, 720, 0x00000070);
        labelCentre(fontHuge, title, 640, 150);
        labelCentre(fontBig, "A summer of small decisions", 640, 240, accentColor);
        string[] items = [
            "New game", exists(autosavePath) ? "Continue" : "Continue (no save yet)",
            "Language: " ~ currentLanguage(),
            "Quit"
        ];
        foreach (i, item; items) {
            float y = 340 + i * 56;
            v_rect(490, y, 300, 46, cast(int) i == menuIndex ? rowSelected : rowColor);
            labelCentre(null, item, 640, y + 8);
        }
        if (notice.length && v_ticks() - noticeAt < 4000)
            labelCentre(fontSmall, notice, 640, 580, badColor);
    }

    void drawOver() {
        drawStage();
        v_rect(0, 0, 1280, 720, 0x000000b0);
        labelCentre(fontHuge, "The summer is over", 640, 90);
        float y = 200;
        auto v = host.view;
        label(null, "How it went", 380, y, 0, accentColor);
        y += 40;
        foreach (ref stat; v.hud) {
            if (stat.id == "day")
                continue;
            label(fontSmall, stat.label, 380, y);
            labelRight(fontSmall, format("%d", cast(long) stat.value), 900, y);
            y += 28;
        }
        y += 14;
        label(null, "Achievements", 380, y, 0, accentColor);
        y += 36;
        foreach (a; host.achievements()) {
            label(fontSmall, "  " ~ a, 380, y);
            y += 28;
        }
        labelCentre(fontSmall, "Enter: play again    Esc: title", 640, 680, dimColor);
    }

    void draw() {
        v_begin();
        final switch (mode) {
        case Mode.title:
            drawTitle();
            break;
        case Mode.over:
            drawOver();
            break;
        case Mode.play:
            drawStage();
            auto v = host.view;
            if (v.inScene)
                drawScene();
            else {
                drawHud();
                drawHub();
            }
            if (v.inScene && v.beat.kind != "menu")
                drawHud();
            drawToasts();
            final switch (overlay) {
            case Overlay.none:
                break;
            case Overlay.pause:
                drawPause();
                break;
            case Overlay.sheet:
                drawSheet();
                break;
            case Overlay.journal:
                drawJournal();
                break;
            case Overlay.map:
                drawMap();
                break;
            case Overlay.help:
                drawHelp();
                break;
            case Overlay.history:
                drawHistory();
                break;
            case Overlay.language:
                break;
            }
            break;
        }
    }

    // ---- input ---------------------------------------------------------------------

    enum KeyUp = 0x40000052, KeyDown = 0x40000051, KeyF1 = 0x4000003a, KeyF5 = 0x4000003e, KeyF9 = 0x40000042,
        KeyF11 = 0x40000044, KeyLeft = 0x40000050, KeyRight = 0x4000004f;

    void cycleLanguage(int direction) {
        size_t index;
        foreach (i, ref l; languages)
            if (l.tag == host.language)
                index = i;
        index = (index + languages.length + direction) % languages.length;
        host.setLanguage(languages[index].tag);
        afterBoundary();
        saveSettings();
    }

    bool quickSave() {
        string bytes;
        if (!host.save(bytes)) {
            notice = host.error;
        } else {
            write(savePath, bytes);
            notice = "Saved";
        }
        noticeAt = v_ticks();
        return true;
    }

    bool quickLoad() {
        if (!exists(savePath)) {
            notice = "No quicksave yet";
            noticeAt = v_ticks();
            return true;
        }
        if (!host.restore(readText(savePath))) {
            notice = host.error;
            noticeAt = v_ticks();
            return true;
        }
        mode = Mode.play;
        overlay = Overlay.none;
        afterBoundary();
        notice = "Loaded";
        noticeAt = v_ticks();
        return true;
    }

    /// Returns false to quit.
    bool event(int type, int key, float x, float y, string typed) {
        if (type == 1)
            return false;
        if (type == 7) {
            mouseX = x;
            mouseY = y;
            hover(x, y);
            return true;
        }
        final switch (mode) {
        case Mode.title:
            return titleEvent(type, key, x, y);
        case Mode.over:
            if (type == 2)
                return newGame() || true;
            if (type == 6 && key == 27) {
                mode = Mode.title;
                menuIndex = 0;
            }
            return true;
        case Mode.play:
            return playEvent(type, key, x, y, typed);
        }
    }

    void hover(float x, float y) {
        if (mode == Mode.play && overlay == Overlay.none && !host.view.inScene) {
            if (x >= 610 && y >= 408) {
                int row = scroll + cast(int)((y - 408) / 36);
                if (row >= 0 && row < cast(int) rows.length && row < scroll + 8)
                    selected = row;
            }
        } else if (mode == Mode.play && overlay == Overlay.none && host.view.inScene && host.view.beat.kind == "menu") {
            if (x >= 190 && x <= 1090 && y >= 80) {
                int row = cast(int)((y - 80) / 72);
                if (row >= 0 && row < cast(int) host.view.beat.choices.length)
                    selected = row;
            }
        }
    }

    bool titleEvent(int type, int key, float x, float y) {
        enum count = 4;
        if (type == 6 && key == KeyDown)
            menuIndex = (menuIndex + 1) % count;
        else if (type == 6 && key == KeyUp)
            menuIndex = (menuIndex + count - 1) % count;
        else if (type == 5 && x >= 490 && x <= 790 && y >= 340) {
            int row = cast(int)((y - 340) / 56);
            if (row >= 0 && row < count && y < 340 + row * 56 + 46) {
                menuIndex = row;
                return activateTitle();
            }
        } else if (type == 2)
            return activateTitle();
        else if (type == 6 && key == 27)
            return false;
        return true;
    }

    bool activateTitle() {
        switch (menuIndex) {
        case 0:
            if (!newGame())
                return false;
            break;
        case 1:
            if (!continueGame())
                return false;
            break;
        case 2:
            cycleLanguage(1);
            break;
        default:
            return false;
        }
        return true;
    }

    bool playEvent(int type, int key, float x, float y, string typed) {
        auto v = host.view;
        // Overlays first.
        if (overlay != Overlay.none) {
            if (type == 6 && key == 27) {
                overlay = Overlay.none;
                return true;
            }
            if (overlay == Overlay.map && type == 5) {
                foreach (ref n; nodes)
                    if (x >= 140 + n.x - 14 && x <= 140 + n.x + 14 && y >= 60 + n.y - 14 && y <= 60 + n.y + 14) {
                        foreach (i, ref r; rows)
                            if (host.view.stories[r.story].id == "walk" &&
                                    host.view.stories[r.story].bindings.get("to", "") == n.id) {
                                overlay = Overlay.none;
                                return choose(i);
                            }
                        notice = "You can't go there from here right now.";
                        noticeAt = v_ticks();
                    }
            }
            if (overlay == Overlay.pause)
                return pauseEvent(type, key, x, y);
            if (type == 6 && ((overlay == Overlay.sheet && key == 'c') || (overlay == Overlay.journal && key == 'j') ||
                    (overlay == Overlay.map && key == 'm') || (overlay == Overlay.history && key == 'h') ||
                    (overlay == Overlay.help && key == KeyF1)))
                overlay = Overlay.none;
            return true;
        }
        if (type == 6) {
            switch (key) {
            case 27:
                overlay = Overlay.pause;
                menuIndex = 0;
                return true;
            case KeyF1:
                overlay = Overlay.help;
                return true;
            case KeyF5:
                return quickSave();
            case KeyF9:
                return quickLoad();
            case KeyF11:
                fullscreen = !fullscreen;
                v_fullscreen(fullscreen ? 1 : 0);
                saveSettings();
                return true;
            case 'c':
                if (!(v.inScene && v.beat.kind == "input")) {
                    overlay = Overlay.sheet;
                    return true;
                }
                break;
            case 'j':
                if (!(v.inScene && v.beat.kind == "input")) {
                    overlay = Overlay.journal;
                    return true;
                }
                break;
            case 'm':
                if (!v.inScene) {
                    overlay = Overlay.map;
                    return true;
                }
                break;
            case 'h':
                if (!(v.inScene && v.beat.kind == "input")) {
                    overlay = Overlay.history;
                    return true;
                }
                break;
            default:
                break;
            }
        }
        if (v.inScene) {
            auto kind = v.beat.kind;
            if (kind == "input") {
                if (type == 4) {
                    if (input.length + typed.length <= 64)
                        input ~= typed;
                    return true;
                }
                if (type == 3 && input.length) {
                    auto last = input.length - 1;
                    while (last && (input[last] & 0xc0) == 0x80)
                        --last;
                    input = input[0 .. last];
                    return true;
                }
                if (type == 2 && input.length)
                    return advance(LuaValue(input)) || true;
                return true;
            }
            if (kind == "menu") {
                auto count = cast(int) v.beat.choices.length;
                if (type == 6 && key == KeyDown)
                    selected = (selected + 1) % count;
                else if (type == 6 && key == KeyUp)
                    selected = (selected + count - 1) % count;
                else if (type == 6 && key >= '1' && key <= '9' && key - '1' < count)
                    return advance(v.beat.choices[key - '1'].id) || true;
                else if (type == 2)
                    return advance(v.beat.choices[selected].id) || true;
                else if (type == 5 && x >= 190 && x <= 1090 && y >= 80) {
                    int row = cast(int)((y - 80) / 72);
                    if (row >= 0 && row < count)
                        return advance(v.beat.choices[row].id) || true;
                }
                return true;
            }
            if (type == 2 || type == 5)
                return advance() || true;
            return true;
        }
        // The hub.
        auto count = cast(int) rows.length;
        if (type == 8) {
            scroll -= key;
            if (scroll < 0)
                scroll = 0;
            if (scroll > count - 8)
                scroll = count > 8 ? count - 8 : 0;
            return true;
        }
        if (type == 6 && key == KeyDown && count)
            selected = (selected + 1) % count;
        else if (type == 6 && key == KeyUp && count)
            selected = (selected + count - 1) % count;
        else if (type == 6 && key >= '1' && key <= '9') {
            int row = cast(int)(key - '1');
            if (row < count)
                return choose(row) || true;
        } else if (type == 2 && count)
            return choose(selected) || true;
        else if (type == 5 && x >= 610 && y >= 408) {
            int row = scroll + cast(int)((y - 408) / 36);
            if (row >= 0 && row < count && row < scroll + 8)
                return choose(row) || true;
        }
        return true;
    }

    bool pauseEvent(int type, int key, float x, float y) {
        enum count = 7;
        int activate = -1;
        if (type == 6 && key == KeyDown)
            menuIndex = (menuIndex + 1) % count;
        else if (type == 6 && key == KeyUp)
            menuIndex = (menuIndex + count - 1) % count;
        else if (type == 6 && key == KeyLeft && menuIndex == 4)
            adjustVolume(-1);
        else if (type == 6 && key == KeyRight && menuIndex == 4)
            adjustVolume(1);
        else if (type == 2)
            activate = menuIndex;
        else if (type == 5 && x >= 460 && x <= 820 && y >= 180) {
            int row = cast(int)((y - 180) / 48);
            if (row >= 0 && row < count) {
                menuIndex = row;
                activate = row;
            }
        }
        switch (activate) {
        case 0:
            overlay = Overlay.none;
            break;
        case 1:
            quickSave();
            break;
        case 2:
            quickLoad();
            break;
        case 3:
            cycleLanguage(1);
            break;
        case 4:
            adjustVolume(1);
            break;
        case 5:
            fullscreen = !fullscreen;
            v_fullscreen(fullscreen ? 1 : 0);
            saveSettings();
            break;
        case 6:
            autosave();
            mode = Mode.title;
            menuIndex = 0;
            overlay = Overlay.none;
            break;
        default:
            break;
        }
        return true;
    }

    void adjustVolume(int delta) {
        volume += delta;
        if (volume > 10)
            volume = 0;
        if (volume < 0)
            volume = 10;
        v_volume(volume / 10.0f);
        saveSettings();
    }

    void close() {
        foreach (texture; cache)
            v_free(texture);
        v_font_free(fontSmall);
        v_font_free(fontBig);
        v_font_free(fontHuge);
        foreach (ref c; channels)
            v_channel_free(c.track);
        foreach (ref a; sounds)
            v_sound_free(a.sound);
        foreach (list; [backgrounds, sprites, portraits])
            foreach (ref image; list)
                v_free(image.texture);
        v_close();
    }
}

/// Runs the game window until the player quits. Returns the process exit code.
int runGame(string manifest, string screenshot) {
    bool smoke = screenshot.length != 0;
    auto player = new GamePlayer;
    scope (exit)
        player.close();
    if (!player.load(manifest, smoke))
        return 1;
    if (smoke)
        return smokeGame(player, screenshot);
    player.mode = Mode.title;
    for (;;) {
        player.draw();
        v_end();
        int key;
        float x, y;
        const(char)* typed;
        int event;
        while ((event = v_event(&key, &x, &y, &typed)) != 0)
            if (!player.event(event, key, x, y, typed ? fromStringz(typed).idup : "")) {
                if (player.mode == Mode.play)
                    player.autosave();
                return player.failed ? 1 : 0;
            }
        if (player.failed)
            return 1;
        if (player.mode == Mode.play && player.overlay == Overlay.none) {
            // Auto-advance nothing else: reading is the player's pace.
        }
        v_delay();
    }
}

/// Headless run for `make test-sdl`: starts a game, plays by the first sensible choice,
/// exercises text input, save/load and the overlays, and writes one screenshot.
private int smokeGame(GamePlayer player, string screenshot) {
    if (!player.newGame())
        return 1;
    bool captured;
    size_t after;
    foreach (step; 0 .. 4000) {
        // After the screenshot, play on for a while: choices, scenes and toasts keep working.
        if (captured && ++after > 400)
            break;
        player.draw();
        auto v = player.host.view;
        if (player.mode == Mode.over)
            break;
        if (v.inScene) {
            auto kind = v.beat.kind;
            if (kind == "input") {
                if (!player.event(4, 0, 0, 0, "Rowan♥") || !player.event(3, 0, 0, 0, "") || !player.event(2, 13, 0, 0, ""))
                    return 1;
            } else if (kind == "menu") {
                if (!player.event(2, 13, 0, 0, ""))
                    return 1;
            } else if (!player.advance())
                return 1;
        } else {
            // Prefer an enabled activity; with none left, go to bed (or walk home through the square).
            size_t pick = size_t.max, bed = size_t.max, home = size_t.max, square = size_t.max, first = size_t.max;
            foreach (i, ref r; player.rows) {
                if (!r.enabled)
                    continue;
                auto story = v.stories[r.story];
                if (first == size_t.max)
                    first = i;
                if (story.id == "sleep")
                    bed = i;
                else if (story.id == "walk") {
                    if (story.bindings.get("to", "") == "house")
                        home = i;
                    if (story.bindings.get("to", "") == "square")
                        square = i;
                } else if (story.id != "look" && story.id != "barred" && pick == size_t.max)
                    pick = i;
            }
            if (pick == size_t.max)
                pick = bed != size_t.max ? bed : home != size_t.max ? home : square != size_t.max ? square : first;
            if (pick == size_t.max) {
                writeln("smoke: stranded hub at step ", step);
                return 1;
            }
            auto day = v.values.get("day", 0);
            if (!captured && v.values.get("slot", 0) >= 2 && day >= 1) {
                // Overlays render without error, then a save round trip, then the screenshot.
                foreach (o; [
                    Overlay.sheet, Overlay.journal, Overlay.map, Overlay.help, Overlay.history,
                    Overlay.pause
                ]) {
                    player.overlay = o;
                    player.draw();
                }
                player.overlay = Overlay.none;
                string bytes, again;
                // Presenting after a load logs the presentation, so a restored game is compared with
                // a second restore of the same bytes rather than with the bytes themselves.
                bool saved1 = player.host.save(bytes);
                bool restored = saved1 && player.host.restore(bytes);
                bool saved2 = restored && player.host.save(again);
                string third;
                bool again2 = saved2 && player.host.restore(bytes) && player.host.save(third);
                if (!saved1 || !restored || !saved2 || !again2 || again != third) {
                    writeln("smoke: save round trip failed (save ", saved1, ", restore ", restored, ", save ", saved2,
                            ", second restore ", again2, ", equal ", again == third, "): ", player.host.error);
                    return 1;
                }
                if (!player.afterBoundary())
                    return 1;
                player.draw();
                if (!v_capture(screenshot.toStringz)) {
                    writeln(fromStringz(v_error()).idup);
                    return 1;
                }
                captured = true;
            }
            if (!player.choose(pick))
                return 1;
        }
        v_end();
    }
    if (!captured) {
        writeln("smoke: never reached the hub");
        return 1;
    }
    writeln("SDL game, hub, overlays, input and save/load checks passed");
    return 0;
}
