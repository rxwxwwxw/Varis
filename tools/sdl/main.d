/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module tools.sdl.main;

import tools.sdl.native;
import varis.services.presentation;
import varis.services.json;
import varis.narrative.scenes : field, nameOf;
import varis.types;
import std.file : readText, write, exists;
import std.path : buildPath, dirName, isAbsolute;
import std.string : toStringz, fromStringz;
import std.stdio : stderr, writeln;

struct Image {
    string id, character;
    JsonValue match;
    void* texture;
}

struct Slot {
    string id;
    float x, y, width, height;
}

struct Audio {
    string id;
    void* sound;
}

struct Channel {
    string id, playing;
    bool loop;
    void* track;
}

class Player {
    SceneHost host;
    Image[] backgrounds, sprites, portraits;
    Slot[] slots;
    Audio[] sounds;
    Channel[] channels;
    void*[] labels;
    void* heading, body, hint;
    string input, notice;
    string[] history;
    bool historyOpen, autoMode, skipMode, failed;
    int selected, scroll;
    ulong entered;
    uint panel = 0x101a2eee, accent = 0x9bdbd9ff;
    string root, savePath;

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
        auto source = config.stringOr("content");
        auto scene = config.stringOr("scene");
        if (!source.length || !scene.length)
            return fail("manifest requires content and scene");
        host = new SceneHost;
        if (!host.loadContent(readText(path(source)), path(source), scene))
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
        auto fontSize = config.integerOr("font_size", 28);
        if (fontSize < 8 || fontSize > 96)
            return fail("font_size must be between 8 and 96");
        if (!v_open(config.stringOr("title", "Varis").toStringz, font.toStringz, cast(float) fontSize, hidden))
            return fail(fromStringz(v_error()).idup);
        savePath = path(config.stringOr("save", "quicksave.json"));
        panel = cast(uint) config.integerOr("panel_color", panel);
        accent = cast(uint) config.integerOr("accent_color", accent);
        if (!images(config.get("backgrounds"), backgrounds) || !images(config.get("sprites"), sprites) ||
                !images(config.get("portraits"), portraits))
            return false;
        if (auto values = config.get("slots"))
            foreach (ref s; values.items) {
                auto slot = Slot(s.stringOr("id"), s.integerOr("x"), s.integerOr("y"),
                        s.integerOr("width", 400), s.integerOr("height", 650));
                if (!slot.id.length || slot.width <= 0 || slot.height <= 0)
                    return fail("slot requires id and positive dimensions");
                slots ~= slot;
            }
        if (!slots.length)
            slots = [
            Slot("left", 80, 0, 400, 670), Slot("center", 440, 0, 400, 670),
            Slot("right", 800, 0, 400, 670)
        ];
        if (auto values = config.get("audio"))
            foreach (ref s; values.items) {
                auto file = s.stringOr("file");
                auto sound = v_sound(path(file).toStringz);
                if (!sound)
                    return fail("audio " ~ file ~ ": " ~ fromStringz(v_error()).idup);
                sounds ~= Audio(s.stringOr("id"), sound);
            }
        if (auto values = config.get("channels"))
            foreach (ref s; values.items) {
                auto track = v_channel();
                if (!track)
                    return fail(fromStringz(v_error()).idup);
                channels ~= Channel(s.stringOr("id"), "", s.integerOr("loop", 1) != 0, track);
            }
        return update();
    }

    void clearText() {
        v_free(heading);
        v_free(body);
        v_free(hint);
        heading = body = hint = null;
        foreach (label; labels)
            v_free(label);
        labels = null;
    }

    bool text(ref void* target, string value, int wrap, uint color = 0xffffffff) {
        v_free(target);
        target = v_text(value.toStringz, wrap, color);
        return !value.length || target !is null || fail(fromStringz(v_error()).idup);
    }

    void* characterImage(Image[] images, string character, LuaValue attributes) {
        void* found;
        size_t best;
        bool matched;
        foreach (ref image; images) {
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

    bool update() {
        clearText();
        selected = scroll = 0;
        input = "";
        entered = v_ticks();
        auto v = host.view;
        if (v.finished)
            return true;
        if (v.kind == "picture" || v.kind == "screen")
            return fail("SDL player does not yet support beat kind: " ~ v.kind);
        bool hasBackground = !v.background.length;
        foreach (ref image; backgrounds)
            if (image.id == v.background)
                hasBackground = true;
        if (!hasBackground)
            return fail("unmapped background: " ~ v.background);
        foreach (ref c; v.characters) {
            bool hasSlot;
            foreach (ref s; slots)
                if (s.id == c.slot)
                    hasSlot = true;
            if (!hasSlot)
                return fail("unmapped slot: " ~ c.slot);
            if (!characterImage(sprites, c.id, c.attributes))
                return fail("no matching sprite for character: " ~ c.id);
        }
        // Validate every active channel, including those omitted from the manifest.
        import varis.narrative.codec : ImmutableRecord;

        if (!v.audio.isNil) {
            auto record = cast(ImmutableRecord) v.audio.asUserData.payload;
            foreach (name, value; record.fields) {
                bool mapped;
                foreach (ref c; channels)
                    if (c.id == name)
                        mapped = true;
                if (!mapped)
                    return fail("unmapped audio channel: " ~ name);
            }
        }
        foreach (ref c; channels) {
            auto tag = nameOf(field(v.audio, c.id));
            if (tag == c.playing)
                continue;
            void* sound;
            foreach (ref a; sounds)
                if (a.id == tag)
                    sound = a.sound;
            if (tag.length && !sound)
                return fail("unmapped audio tag: " ~ tag);
            if (!v_play(c.track, sound, c.loop))
                return fail(fromStringz(v_error()).idup);
            c.playing = tag;
        }
        if (!text(heading, v.speaker, 1100, accent) || !text(body, v.text, 1000))
            return false;
        if (v.kind == "say" || v.kind == "narration") {
            history ~= (v.speaker.length ? v.speaker ~ ": " : "") ~ v.text;
        }
        foreach (ref choice; v.choices) {
            void* label;
            if (!text(label, choice.text, 850))
                return false;
            labels ~= label;
        }
        return updateHint();
    }

    bool updateHint() {
        auto message = host.view.kind == "input" ? "> " ~ input ~ "  [Enter]"
            : "Enter / click: next    Arrows: scroll/menu    H: history    A: auto    S: skip    F5: save    F9: load";
        if (notice.length)
            message = notice;
        return text(hint, message, 1200, accent);
    }

    bool advance(LuaValue value = LuaValue.init) {
        notice = "";
        return host.advance(value) ? update() : fail(host.error);
    }

    void draw() {
        v_begin();
        auto v = host.view;
        foreach (ref image; backgrounds)
            if (image.id == v.background)
                v_draw(image.texture, 0, 0, 1280, 720, 0, 1);
        foreach (ref slot; slots)
            foreach (ref character; v.characters)
                if (character.slot == slot.id)
                    v_draw(characterImage(sprites, character.id, character.attributes), slot.x, slot.y,
                            slot.width, slot.height, 1, 1);
        if (v.kind == "menu") {
            auto first = selected / 6 * 6;
            for (size_t i = first; i < labels.length && i < first + 6; ++i) {
                float y = 70 + (i - first) * 72;
                v_rect(190, y, 900, 64, i == selected ? 0x356b80ee : panel);
                v_draw(labels[i], 215, y + 10, 850, 48, 1, 1);
            }
        } else if (v.text.length || v.kind == "input") {
            v_rect(24, 490, 1232, 200, panel);
            foreach (ref c; v.characters)
                if (c.id == v.character)
                    v_draw(characterImage(portraits, c.id, c.attributes), 34, 500, 140, 170, 1, 1);
            v_draw(heading, 190, 504, 0, 0, 2, 1);
            v_clip(190, 546, 1030, 134);
            v_draw(body, 190, 546 - scroll * 32, 0, 0, 2, 1);
            v_clip(0, 0, 0, 0);
        }
        v_rect(0, 690, 1280, 30, panel);
        v_draw(hint, 20, 694, 1200, 24, 1, 1);
        if (v.kind == "transition") {
            float alpha = 1 - cast(float)(v_ticks() - entered) / 300;
            if (alpha > 0)
                v_rect(0, 0, 1280, 720, cast(uint)(alpha * 255));
        }
        if (historyOpen) {
            v_rect(24, 24, 1232, 650, 0x101a2ef8);
            v_draw(body, 45, 45, 0, 0, 2, 1);
        }
    }

    bool event(int type, int key, float x, float y, string typed) {
        if (type == 1)
            return false;
        auto kind = host.view.kind;
        if (type == 6 && key == 'h') {
            historyOpen = !historyOpen;
            if (historyOpen) {
                string log;
                auto start = history.length > 5 ? history.length - 5 : 0;
                foreach (line; history[start .. $])
                    log ~= line ~ "\n\n";
                if (!text(body, log, 1150))
                    return false;
            } else if (!text(body, host.view.text, 1000))
                return false;
            return true;
        }
        if (historyOpen)
            return true;
        if (type == 6 && key == 0x4000003e) { // F5
            string bytes;
            if (!host.save(bytes))
                return fail(host.error);
            write(savePath, bytes);
            notice = "Saved";
            return updateHint();
        }
        if (type == 6 && key == 0x40000042) { // F9
            if (!exists(savePath)) {
                notice = "No quicksave yet";
                return updateHint();
            }
            if (!host.restore(readText(savePath))) {
                notice = host.error;
                return updateHint();
            }
            if (!update())
                return false;
            notice = "Loaded";
            return updateHint();
        }
        if (kind == "input") {
            if (type == 4) {
                if (input.length + typed.length <= 4096)
                    input ~= typed;
                return updateHint();
            }
            if (type == 3 && input.length) {
                auto last = input.length - 1;
                while (last && (input[last] & 0xc0) == 0x80)
                    --last;
                input = input[0 .. last];
                return updateHint();
            }
            if (type == 2 && key == 13)
                return advance(LuaValue(input));
            return true;
        }
        if (type == 6 && key == 'a') {
            autoMode = !autoMode;
            notice = autoMode ? "Auto on" : "Auto off";
            return updateHint();
        }
        if (type == 6 && key == 's') {
            skipMode = !skipMode;
            notice = skipMode ? "Skip on" : "Skip off";
            return updateHint();
        }
        if (type == 6 && (key == 0x40000051 || key == 0x40000052)) {
            int direction = key == 0x40000051 ? 1 : -1;
            if (kind == "menu")
                selected = (selected + direction + cast(int) labels.length) % cast(int) labels.length;
            else {
                scroll += direction;
                if (scroll < 0)
                    scroll = 0;
            }
        }
        if (kind == "menu") {
            if (type == 5 && x >= 190 && x <= 1090 && y >= 70) {
                auto row = cast(int)((y - 70) / 72);
                if (row < 6 && y < 70 + row * 72 + 64 && selected / 6 * 6 + row < labels.length)
                    return advance(host.view.choices[selected / 6 * 6 + row].id);
            }
            if (type == 2)
                return advance(host.view.choices[selected].id);
            return true;
        }
        if (type == 2 || type == 5)
            return advance();
        return true;
    }

    void close() {
        clearText();
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

int main(string[] args) {
    if (args.length < 2) {
        stderr.writeln("usage: varis-sdl manifest.json [--smoke screenshot.bmp]");
        return 1;
    }
    bool smoke = args.length == 4 && args[2] == "--smoke";
    auto player = new Player;
    scope (exit)
        player.close();
    try {
        if (!player.load(args[1], smoke))
            return 1;
        bool captured;
        for (size_t steps; !player.host.view.finished; ++steps) {
            auto kind = player.host.view.kind;
            player.draw();
            if (smoke) {
                if (steps >= 1000) {
                    stderr.writeln("smoke beat budget exceeded");
                    return 1;
                }
                if (kind == "say" && !captured) {
                    string bytes, restored;
                    if (!player.host.save(bytes) || !player.host.restore(bytes) || !player.host.save(restored) || bytes != restored)
                        return player.fail("save round trip failed: " ~ player.host.error) ? 0 : 1;
                    if (!v_capture(args[3].toStringz))
                        return player.fail(fromStringz(v_error()).idup) ? 0 : 1;
                    captured = true;
                }
                v_end();
                if (kind == "input") {
                    // Exercise the same UTF-8 edit/submit path as native SDL events.
                    if (!player.event(4, 0, 0, 0, "Rowan♥") || !player.event(3, 0, 0, 0, "") ||
                            !player.event(2, 13, 0, 0, ""))
                        return 1;
                } else if (kind == "menu") {
                    if (!player.event(2, 13, 0, 0, ""))
                        return 1;
                } else if (!player.advance())
                    return 1;
                continue;
            }
            v_end();
            int key;
            float x, y;
            const(char)* typed;
            bool handled;
            int event;
            while ((event = v_event(&key, &x, &y, &typed)) != 0) {
                auto before = player.host.view.index;
                auto sceneBefore = player.host.view.scene;
                if (!player.event(event, key, x, y, typed ? fromStringz(typed).idup : ""))
                    return player.failed || player.host.error.length ? 1 : 0;
                if (before != player.host.view.index || sceneBefore != player.host.view.scene) {
                    handled = true;
                    break;
                }
            }
            if (!handled && !player.historyOpen && !player.host.view.finished) {
                auto elapsed = v_ticks() - player.entered;
                bool media = kind == "background" || kind == "show" || kind == "hide" || kind == "audio";
                bool timed = (kind == "transition" || kind == "pause") && elapsed >= 300;
                bool dialogue = (kind == "say" || kind == "narration") &&
                    ((player.skipMode && elapsed >= 100) || (player.autoMode && elapsed >= 1500 + player
                            .host.view.text.length * 35));
                if ((media || timed || dialogue) && !player.advance())
                    return 1;
            }
            v_delay();
        }
        if (smoke) {
            if (!captured)
                return player.fail("smoke scene contains no dialogue") ? 0 : 1;
            writeln("SDL scene, assets, input/menu and save/load checks passed");
        }
        return 0;
    } catch (Exception error) {
        stderr.writeln(error.msg);
        return 1;
    }
}
