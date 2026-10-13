/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The SDL3 player: scene-only games (`content` + `scene`) and whole games (`project`), both
/// through `GameHost`. It draws widgets from `tools.sdl.ui` and decides nothing about layout
/// itself except which arrangement a window size calls for:
///
/// * **regular** (about 900x560 units and up): status panel and stage over a text-and-choices panel;
/// * **wide** (1500x820 and up): a left sidebar with the status and the goals, the stage and text in
///   the middle, and the choices in a column of their own on the right;
/// * **compact**: the stage on top and one scrolling panel below; the status and the menu move to a
///   drawer opened by the Menu button (or Tab).
///
/// Colours, type sizes and spacing come from the manifest's `theme`; text size and the layout are
/// also the player's choice, in the pause menu.
module tools.sdl.gameplayer;

import tools.sdl.native;
import tools.sdl.ui;
import tools.sdl.battleview;
import varis.game.battle : Battle;
import varis.game.kinds : Primitive, TowerKind;
import varis.game.types : Command, CommandKind, CueKind, Outcome, StepResult;
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
import std.algorithm : max, min;

private struct Image {
    string id, character;
    JsonValue match;
    void* texture;
}

private struct Slot {
    string id;
    float x, width; // fractions of the stage width
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
    history
}

private immutable float[] textScales = [0.8f, 0.9f, 1.0f, 1.15f, 1.3f, 1.5f, 1.75f];
private immutable string[] layoutNames = ["Auto", "Compact", "Regular", "Wide"];

/// Gives its child whatever room is left and reports no natural height of its own, so the bars
/// around it keep their place however tall its content would like to be.
private final class Squeezable : Widget {
    Widget inner;

    this(Widget inner) {
        this.inner = inner;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, 0);
    }

    override bool shrinkable() {
        return true;
    }

    override float minHeight(Ui ui) {
        return ui.u(80);
    }

    override void arrange(Ui ui, Rect r) {
        rect = r;
        inner.arrange(ui, r);
    }

    override void draw(Ui ui) {
        ui.pushClip(rect);
        inner.draw(ui);
        ui.popClip();
    }

    override bool event(Ui ui, ref UiEvent e) {
        return inner.event(ui, e);
    }
}

/// The pictures of a scene: sprites in their slots of the stage rectangle.
private final class StageWidget : Widget {
    GamePlayer player;

    this(GamePlayer player) {
        this.player = player;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, 0);
    }

    override bool shrinkable() {
        return true;
    }

    override float minHeight(Ui ui) {
        return ui.u(60);
    }

    override void draw(Ui ui) {
        auto view = player.host.view.beat;
        ui.pushClip(rect);
        foreach (ref slot; player.slots)
            foreach (ref c; view.characters)
                if (c.slot == slot.id) {
                    auto art = player.characterImage(player.sprites, c.id, c.attributes);
                    ui.image(art, Rect(rect.x + slot.x * rect.w, rect.y + rect.h * 0.04f, slot.width * rect.w, rect.h * 0.96f), 1);
                }
        ui.popClip();
        player.drawToasts(ui, rect);
    }
}

/// The map overlay: places and roads scaled into whatever box they are given.
private final class MapView : Widget {
    GamePlayer player;
    MapState state;
    void delegate(string) onPick;
    private Rect[string] spots;

    this(GamePlayer player, MapState state) {
        this.player = player;
        this.state = state;
    }

    override Size measure(Ui ui, float maxW, float maxH) {
        return Size(maxW, maxH);
    }

    override bool shrinkable() {
        return true;
    }

    override float minHeight(Ui ui) {
        return ui.u(120);
    }

    private Rect spot(Ui ui, Node n) {
        float x0 = float.max, y0 = float.max, x1 = -float.max, y1 = -float.max;
        foreach (ref m; player.nodes) {
            x0 = min(x0, m.x);
            y0 = min(y0, m.y);
            x1 = max(x1, m.x);
            y1 = max(y1, m.y);
        }
        auto margin = ui.u(70);
        auto box = rect.inset(margin, ui.u(24), margin, ui.u(34));
        auto sx = x1 > x0 ? box.w / (x1 - x0) : 1, sy = y1 > y0 ? box.h / (y1 - y0) : 1;
        auto s = min(sx, sy);
        auto cx = box.x + box.w / 2 - (x1 - x0) * s / 2, cy = box.y + box.h / 2 - (y1 - y0) * s / 2;
        auto half = ui.u(11);
        return Rect(cx + (n.x - x0) * s - half, cy + (n.y - y0) * s - half, 2 * half, 2 * half);
    }

    override void draw(Ui ui) {
        spots = null;
        foreach (ref n; player.nodes)
            spots[n.id] = spot(ui, n);
        foreach (from, list; player.roads)
            foreach (to; list)
                if (from in spots && to in spots) {
                    auto a = spots[from], b = spots[to];
                    auto ax = a.x + a.w / 2, ay = a.y + a.h / 2, bx = b.x + b.w / 2, by = b.y + b.h / 2;
                    foreach (s; 0 .. 24) {
                        auto f = s / 24.0f;
                        ui.fill(Rect(ax + (bx - ax) * f - 1, ay + (by - ay) * f - 1, 3, 3), ui.theme.dim);
                    }
                }
        foreach (ref n; player.nodes) {
            auto r = spots[n.id];
            bool here = n.id == state.at, open = (n.id in state.reachable) !is null;
            ui.fill(r, here ? ui.theme.gold : open ? ui.theme.accent : ui.theme.locked);
            auto name = player.host.display(n.id);
            auto size = ui.measure(name, FontRole.small);
            ui.drawText(name, FontRole.small, r.x + r.w / 2 - size.w / 2, r.y + r.h + ui.u(3), 0,
                    open ? ui.theme.text : ui.theme.locked);
        }
    }

    override bool event(Ui ui, ref UiEvent e) {
        if (e.type != 5)
            return false;
        foreach (id, r; spots)
            if (r.inset(-ui.u(8)).contains(e.x, e.y) && onPick !is null) {
                onPick(id);
                return true;
            }
        return false;
    }
}

class GamePlayer {
    GameHost host;
    Ui ui;
    Image[] backgrounds, sprites, portraits;
    Slot[] slots;
    Sound[] sounds;
    Channel[] channels;
    Language[] languages;
    Node[] nodes;
    string[][string] roads;
    string[] clock;
    string[] choiceLabels; // storylets whose rows are labelled by the choice, not the storylet
    string root, savePath, autosavePath, settingsPath, profilePath, title, subtitle;
    string[] history;
    Mode mode;
    Overlay overlay;
    bool drawerOpen;
    Row[] rows;
    Button[] rowButtons, menuButtons;
    int selected, menuIndex;
    bool revealSelected;
    ToastView[] toasts;
    string notice, input;
    ulong noticeAt;
    long seed;
    int volume = 8, textScaleIndex = 2, layoutIndex;
    bool fullscreen, failed;
    string fontPath, headingFontPath;
    int windowWidth = 1280, windowHeight = 720;
    bool sceneOnly;
    private Widget lastRoot;
    // the battle view (state that outlives a frame) and the smoke test's fixed step rate
    BattleViewState bview;
    BattleCanvas bcanvas;
    int smokeStepsPerFrame;

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

    bool load(string manifest, bool hidden, int forcedWidth = 0, int forcedHeight = 0) {
        root = dirName(manifest);
        JsonValue config;
        string error;
        if (!parseJson(readText(manifest), config, error))
            return fail(error);
        title = config.stringOr("title", "Varis");
        subtitle = config.stringOr("subtitle");
        host = new GameHost;
        bview = new BattleViewState;
        auto project = config.stringOr("project");
        if (project.length) {
            if (!host.loadProject(path(project), config.stringOr("scene")))
                return fail(host.error);
        } else {
            auto source = config.stringOr("content");
            auto scene = config.stringOr("scene");
            if (!source.length || !scene.length)
                return fail("manifest requires content and scene (or a project)");
            sceneOnly = true;
            if (!host.loadScenes(readText(path(source)), path(source), scene))
                return fail(host.error);
        }
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
        if (auto heading = config.stringOr("heading_font"))
            headingFontPath = path(heading);
        auto theme = Theme.fromJson(config.get("theme"));
        // The legacy `font_size` key sets the type scale as the theme's does.
        auto legacySize = config.integerOr("font_size", 0);
        if (legacySize) {
            if (legacySize < 8 || legacySize > 96)
                return fail("font_size must be between 8 and 96");
            auto ratio = cast(float) legacySize / theme.fontBody;
            theme.fontBody *= ratio;
            theme.fontSmall *= ratio;
            theme.fontHeading *= ratio;
            theme.fontTitle *= ratio;
        }
        theme.panel = cast(uint) config.integerOr("panel_color", theme.panel);
        theme.accent = cast(uint) config.integerOr("accent_color", theme.accent);
        if (auto size = config.get("window"))
            if (size.kind == JsonValue.Kind.array && size.items.length == 2) {
                windowWidth = cast(int) size.items[0].number;
                windowHeight = cast(int) size.items[1].number;
            }
        if (forcedWidth > 0) {
            windowWidth = forcedWidth;
            windowHeight = forcedHeight;
        }
        if (!v_open(title.toStringz, windowWidth, windowHeight, hidden))
            return fail(fromStringz(v_error()).idup);
        ui = new Ui;
        ui.theme = theme;
        ui.fontBody = v_font(font.toStringz);
        if (!ui.fontBody)
            return fail("font " ~ font ~ ": " ~ fromStringz(v_error()).idup);
        if (headingFontPath.length)
            ui.fontHeading = v_font(headingFontPath.toStringz);
        savePath = path(config.stringOr("save", "quicksave.json"));
        autosavePath = path(config.stringOr("autosave", "autosave.json"));
        settingsPath = path(config.stringOr("settings", "settings.json"));
        profilePath = path(config.stringOr("profile", "profile.json"));
        if (exists(profilePath))
            host.profileLoad(readText(profilePath)); // a bad file leaves the empty profile
        seed = config.integerOr("seed", 0);
        if (!images(config.get("backgrounds"), backgrounds) || !images(config.get("sprites"), sprites) ||
                !images(config.get("portraits"), portraits))
            return false;
        // Slots are written in the 1280-unit design; they are kept as fractions of the stage.
        if (auto values = config.get("slots"))
            foreach (ref s; values.items) {
                Slot slot;
                slot.id = s.stringOr("id");
                slot.x = s.integerOr("x") / 1280.0f;
                slot.width = s.integerOr("width", 400) / 1280.0f;
                if (!slot.id.length || slot.width <= 0)
                    return fail("slot requires id and positive dimensions");
                slots ~= slot;
            }
        if (!slots.length)
            slots = [
            Slot("left", 0.06f, 0.3f), Slot("center", 0.35f, 0.3f), Slot("right", 0.64f, 0.3f)
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
        applySettings();
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
        textScaleIndex = cast(int) v.integerOr("text_scale", textScaleIndex);
        if (textScaleIndex < 0 || textScaleIndex >= cast(int) textScales.length)
            textScaleIndex = 2;
        layoutIndex = cast(int) v.integerOr("layout", 0);
        if (layoutIndex < 0 || layoutIndex >= cast(int) layoutNames.length)
            layoutIndex = 0;
        auto tag = v.stringOr("language");
        foreach (ref l; languages)
            if (l.tag == tag)
                host.language = tag;
    }

    void saveSettings() {
        if (sceneOnly)
            return;
        write(settingsPath, format(`{"volume":%d,"fullscreen":%d,"text_scale":%d,"layout":%d,"language":"%s"}`, volume,
                fullscreen ? 1 : 0, textScaleIndex, layoutIndex, host.language));
    }

    void applySettings() {
        v_volume(volume / 10.0f);
        v_fullscreen(fullscreen ? 1 : 0);
        ui.userScale = textScales[textScaleIndex];
        ui.isForced = layoutIndex != 0;
        ui.forced = layoutIndex == 1 ? SizeClass.compact : layoutIndex == 3 ? SizeClass.wide : SizeClass.regular;
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

    void* backgroundImage() {
        auto id = host.view.beat.background;
        foreach (ref image; backgrounds)
            if (image.id == id)
                return image.texture;
        return null;
    }

    /// An unmapped background, slot, sprite or audio channel is a diagnostic, not a blank screen.
    bool validate() {
        auto v = host.view.beat;
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
        return true;
    }

    bool syncAudio() {
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
                return fail("unmapped audio tag: " ~ tag);
            v_play(c.track, sound, c.loop);
            c.playing = tag;
        }
        return true;
    }

    /// A one-shot sound on the `sfx` channel; a missing channel or sound is silent.
    void sfx(string id) {
        foreach (ref c; channels)
            if (c.id == "sfx")
                foreach (ref a; sounds)
                    if (a.id == id) {
                        v_play(c.track, a.sound, 0);
                        return;
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
        drawerOpen = false;
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
                kind == "transition" || kind == "pause";
            if (!media)
                break;
            if (!validate() || !syncAudio())
                return false;
            if (!host.advance())
                return fail(host.error);
        }
        input = "";
        rows = null;
        auto v = host.view;
        if (!validate() || !syncAudio())
            return false;
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
        // The highlighted row starts on the first one that can be taken.
        selected = 0;
        foreach (i, ref r; rows)
            if (r.enabled) {
                selected = cast(int) i;
                break;
            }
        revealSelected = true;
        bool gained, lost;
        foreach (t; host.takeToasts()) {
            toasts ~= ToastView(t.text, t.good, v_ticks());
            gained = gained || t.good;
            lost = lost || !t.good;
        }
        if (lost)
            sfx("fail");
        else if (gained)
            sfx("stat_up");
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
        sfx("click");
        if (!host.choose(r.story, r.choice))
            return fail(host.error);
        autosave();
        return afterBoundary();
    }

    /// The profile (achievements, endings seen) lives outside every save; it is kept beside them.
    void saveProfile() {
        string text;
        if (host.profileSave(text))
            write(profilePath, text);
    }

    void autosave() {
        saveProfile();
        if (sceneOnly)
            return;
        // inside a battle the autosave is the world at its start: Continue begins it again
        string bytes;
        if (host.autosaveBytes(bytes))
            write(autosavePath, bytes);
    }

    bool advance(LuaValue value = LuaValue.init) {
        if (!host.advance(value))
            return fail(host.error);
        return afterBoundary();
    }

    // ---- widgets -------------------------------------------------------------------

    private Label text(string value, FontRole role = FontRole.body, uint colour = 0, Overflow overflow = Overflow.grow) {
        auto l = new Label(value, role, colour);
        l.overflow = overflow;
        l.wrap = overflow != Overflow.ellipsis;
        return l;
    }

    private Box panel(bool vertical = true, float pad = -1) {
        auto b = new Box(vertical);
        b.background = ui.theme.panel;
        b.pad = pad < 0 ? ui.theme.pad : pad;
        return b;
    }

    private Button button(string label, void delegate() click, bool enabled = true) {
        auto b = new Button(label, click);
        b.role = FontRole.body;
        b.enabled = enabled;
        return b;
    }

    private string timeLabel() {
        auto slot = cast(size_t) host.view.values.get("slot", 1);
        return slot >= 1 && slot <= clock.length ? clock[slot - 1] : "";
    }

    private string placeLabel() {
        auto place = host.display(host.view.beat.background);
        return place.length ? place : title;
    }

    private Widget topBar(bool compact) {
        auto bar = panel(false, 8);
        auto v = host.view;
        if (compact) {
            auto menu = button("Menu", { drawerOpen = true; });
            menu.fit = true;
            bar.add(menu);
        }
        auto place = text(placeLabel(), FontRole.heading, ui.theme.text, Overflow.ellipsis);
        bar.add(place, 1.8f);
        if (v.values.length) {
            if (!compact)
                bar.add(text(format("Day %d, %s", cast(long) v.values.get("day", 1), timeLabel()), FontRole.body, ui
                        .theme.text,
                        Overflow.ellipsis), 1);
            auto coins = text(format("%d coins", cast(long) v.values.get("coins", 0)), FontRole.body, ui.theme.gold,
                    Overflow.ellipsis);
            coins.alignment = Align.right;
            bar.add(coins, compact ? 0 : 1);
        }
        return bar;
    }

    private Box statPanel() {
        auto p = panel(true, 10);
        p.gap = 5;
        foreach (ref stat; host.view.hud) {
            if (stat.id == "coins" || stat.id == "day")
                continue;
            auto line = new Box(false);
            line.add(text(stat.label, FontRole.small, ui.theme.text, Overflow.ellipsis), 1);
            auto number = text(format("%d", cast(long) stat.value), FontRole.small);
            number.alignment = Align.right;
            line.add(number);
            auto group = new Box(true);
            group.gap = 2;
            group.add(line);
            group.add(new Bar(stat.value, stat.hasMinimum ? stat.minimum : 0, stat.hasMaximum ? stat.maximum
                    : 100,
                    stat.id == "stamina" && stat.value <= 2 ? ui.theme.bad : 0));
            p.add(group);
        }
        return p;
    }

    private bool summerStarted() {
        foreach (ref s; host.view.stories)
            if (s.id == "look")
                return true;
        return false;
    }

    private Box goalsPanel() {
        auto p = panel(true, 10);
        p.add(text("Goals", FontRole.small, ui.theme.accent));
        foreach (ref section; host.journal()) {
            if (section.title != "Goals")
                continue;
            foreach (line; section.lines)
                p.add(text(line, FontRole.small, ui.theme.text));
        }
        return p;
    }

    /// The text of the panel next to the choices: the place's own description, then what the
    /// highlighted row says (its text, its reason when locked).
    private string narrativeText(out string reason) {
        auto v = host.view;
        string ambient, detail;
        foreach (ref s; v.stories)
            if (s.text.length && s.id == "look") {
                ambient = s.text;
                break;
            }
        if (selected >= 0 && selected < cast(int) rows.length) {
            auto r = rows[selected];
            auto story = v.stories[r.story];
            // A question shows its own text above its answers; the panel need not repeat it.
            detail = story.choices.length > 1 ? "" : story.text;
            if (!r.enabled)
                reason = story.choices[r.choice].because;
            else if (story.choices[r.choice].text.length)
                detail ~= (detail.length ? "\n\n" : "") ~ story.choices[r.choice].text;
        }
        string result = ambient;
        if (detail.length && detail != ambient)
            result ~= (result.length ? "\n\n" : "") ~ detail;
        return result;
    }

    private Box narrativePanel() {
        string reason;
        auto body = narrativeText(reason);
        // Nothing to say (character creation): no empty panel; the room goes to the choices.
        if (!body.length && !reason.length && !(notice.length && ui.now - noticeAt < 4000))
            return null;
        auto p = panel(true, ui.theme.pad);
        p.gap = 6;
        auto label = text(body, FontRole.body, ui.theme.text, Overflow.scroll);
        label.id = "narrative";
        p.add(label, 1);
        if (reason.length)
            p.add(text(reason, FontRole.small, ui.theme.bad));
        else if (notice.length && ui.now - noticeAt < 4000)
            p.add(text(notice, FontRole.small, ui.theme.bad));
        return p;
    }

    /// The choices as a list. A storylet that asks a question (several choices) is shown as a
    /// heading with its text, so the question and its answers read together; a storylet with one
    /// choice is one row, with its description under it when the column is wide enough to show it.
    private Widget choiceList(bool describe) {
        auto v = host.view;
        auto list = new Box(true);
        list.gap = 4;
        rowButtons = null;
        size_t index;
        Widget target;
        foreach (si, ref story; v.stories) {
            auto question = story.choices.length > 1;
            if (question) {
                auto head = new Box(true);
                head.gap = 2;
                head.add(text(story.title, FontRole.body, ui.theme.accent));
                if (story.text.length)
                    head.add(text(story.text, FontRole.small, ui.theme.dim));
                list.add(head);
            }
            foreach (ci, ref choice; story.choices) {
                auto i = index++;
                auto r = rows[i];
                auto b = new Button(question ? choice.title : r.label, rowClick(i));
                b.role = FontRole.small;
                b.wrap = true;
                b.prefix = i < 9 ? format("%d", i + 1) : "";
                b.hint = r.enabled ? "" : "locked";
                b.locked = !r.enabled;
                b.selected = cast(int) i == selected;
                b.id = format("row%d", i);
                if (describe && !question && story.text.length && story.id != "look")
                    b.detail = story.text;
                if (question && !r.enabled && choice.because.length)
                    b.detail = choice.because;
                rowButtons ~= b;
                list.add(b);
                if (cast(int) i == selected)
                    target = b;
            }
        }
        auto scroll = new ScrollBox(list);
        scroll.id = "choices";
        if (revealSelected && target !is null) {
            scroll.revealTarget = target;
            revealSelected = false;
        }
        return scroll;
    }

    /// The notices of stat changes, stacked at the top right of the stage.
    void drawToasts(Ui ui, Rect area) {
        auto y = area.y + ui.u(8);
        ToastView[] alive;
        // A burst shows its newest few; the rest are not queued up to scroll past.
        if (toasts.length > 5)
            toasts = toasts[$ - 5 .. $];
        foreach (ref t; toasts) {
            auto age = ui.now - t.born;
            if (age > 3600)
                continue;
            alive ~= t;
            auto fade = age > 2800 ? 1.0f - (age - 2800) / 800.0f : 1.0f;
            auto size = ui.measure(t.text, FontRole.small);
            auto pad = ui.u(6);
            auto width = min(size.w + 2 * pad, area.w - 2 * pad);
            auto box = Rect(area.x + area.w - width - pad, y, width, size.h + 2 * pad);
            ui.fill(box, (ui.theme.panelStrong & 0xffffff00) | cast(uint)(220 * fade));
            ui.pushClip(box);
            ui.drawText(t.text, FontRole.small, box.x + pad, box.y + pad, 0,
                    ((t.good ? ui.theme.good
                    : ui.theme.bad) & 0xffffff00) | cast(uint)(255 * fade));
            ui.popClip();
            y += box.h + ui.u(6);
        }
        toasts = alive;
    }

    private Widget stageArea() {
        auto s = new StageWidget(this);
        s.flex = 1;
        return s;
    }

    private Widget hubBody(SizeClass cls) {
        auto hint = text("1-9 or Enter: choose   C sheet   J journal   M map   Esc menu", FontRole.small,
                ui.theme.dim, Overflow.ellipsis);
        final switch (cls) {
        case SizeClass.wide: {
                auto side = new Box(true);
                side.gap = 10;
                side.widthUnits = 300;
                side.add(statPanel());
                if (summerStarted())
                    side.add(goalsPanel());
                auto centre = new Box(true);
                centre.gap = 0;
                centre.add(topBar(false));
                centre.add(stageArea(), 1);
                auto narrative = narrativePanel();
                if (narrative !is null) {
                    narrative.heightUnits = 190;
                    centre.add(narrative);
                }
                auto right = panel(true, ui.theme.pad);
                right.widthUnits = 540;
                right.gap = 8;
                right.add(text(summerStarted() ? "What now?" : "Who are you?", FontRole.heading, ui.theme.accent));
                right.add(choiceList(true), 1);
                right.add(hint);
                auto row = new Box(false);
                row.gap = 0;
                row.add(side);
                row.add(centre, 1);
                row.add(right);
                return row;
            }
        case SizeClass.regular: {
                auto top = new Box(false);
                top.gap = 0;
                auto side = new Box(true);
                side.widthUnits = 250;
                side.add(statPanel());
                top.add(side);
                top.add(stageArea(), 1);
                auto bottom = new Box(false);
                bottom.gap = 0;
                bottom.heightPx = max(ui.u(250), ui.height * 0.4f);
                bottom.add(narrativePanel(), 1);
                auto choices = panel(true, ui.theme.pad);
                choices.add(choiceList(false), 1);
                choices.add(hint);
                choices.gap = 6;
                bottom.add(choices, 1.25f);
                auto column = new Box(true);
                column.gap = 0;
                column.add(topBar(false));
                column.add(top, 1);
                column.add(bottom);
                return column;
            }
        case SizeClass.compact: {
                auto column = new Box(true);
                column.gap = 0;
                column.add(topBar(true));
                column.add(stageArea(), 0.7f);
                auto bottom = panel(true, 8);
                bottom.gap = 6;
                // The text takes the room it needs (and shrinks first); the list takes the rest.
                bottom.add(narrativePanel());
                bottom.add(choiceList(false), 1);
                column.add(bottom, 1.7f);
                return column;
            }
        }
    }

    private Widget dialogue(SizeClass cls) {
        auto v = host.view.beat;
        auto page = new Box(true);
        page.gap = 0;
        if (host.view.values.length)
            page.add(topBar(cls == SizeClass.compact));
        page.add(stageArea(), 1);
        if (v.kind == "menu") {
            auto menu = panel(true, ui.theme.pad);
            menu.gap = 6;
            menuButtons = null;
            foreach (i, ref c; v.choices) {
                auto b = new Button(c.text, menuClick(i));
                b.role = FontRole.body;
                b.wrap = true;
                b.prefix = format("%d", i + 1);
                b.selected = cast(int) i == selected;
                b.id = format("menu%d", i);
                menuButtons ~= b;
                menu.add(b);
            }
            page.add(menu);
            return page;
        }
        auto box = panel(false, ui.theme.pad);
        box.gap = 12;
        box.heightPx = min(ui.height * 0.4f, max(ui.u(190), ui.height * 0.28f));
        void* portrait;
        foreach (ref c; v.characters)
            if (c.id == v.character)
                portrait = characterImage(portraits, c.id, c.attributes);
        if (portrait !is null && cls != SizeClass.compact) {
            auto p = new ImageBox(portrait, 1);
            p.width = 140;
            p.height = 170;
            auto column = new Box(true);
            column.widthUnits = 140;
            column.add(p);
            box.add(column);
        }
        auto words = new Box(true);
        words.gap = 4;
        if (v.speaker.length)
            words.add(text(v.speaker, FontRole.heading, ui.theme.accent, Overflow.ellipsis));
        string body = v.kind == "input" ? v.text ~ "\n> " ~ input ~ "_" : v.text;
        auto message = text(body, FontRole.body, ui.theme.text, Overflow.scroll);
        message.id = "dialogue";
        words.add(message, 1);
        words.add(text(v.kind == "input" ? "Type, then Enter" : "Enter or click to continue    H: history", FontRole
                .small,
                ui.theme.dim, Overflow.ellipsis));
        box.add(words, 1);
        page.add(box);
        return page;
    }

    // Delegates made in a loop must not share the loop variable: each gets its own copy here.
    private void delegate() rowClick(size_t i) {
        return{ selected = cast(int) i; choose(i); };
    }

    private void delegate() menuClick(size_t i) {
        return{ selected = cast(int) i; advance(host.view.beat.choices[i].id); };
    }

    private void delegate() drawerClick(string target) {
        return{ drawerOpen = false; openOverlay(target); };
    }

    private Widget playScreen() {
        auto cls = ui.sizeClass;
        if (host.inBattle)
            return battleScreen(cls);
        auto layers = new Stack;
        auto back = new Backdrop;
        back.texture = backgroundImage();
        back.colour = ui.theme.backdrop;
        auto slot = host.view.values.get("slot", 1);
        back.overlay = slot >= 4 ? 0x0a0a3a88 : slot >= 3 ? 0x2a124a44 : 0;
        layers.add(back);
        layers.add(host.view.inScene ? dialogue(cls) : hubBody(cls));
        if (drawerOpen && cls == SizeClass.compact) {
            auto d = new Box(true);
            d.gap = 8;
            d.add(text(title, FontRole.heading, ui.theme.accent));
            d.add(statPanel());
            foreach (entry; [
                    ["Character", "sheet"], ["Journal", "journal"], ["Map", "map"],
                    ["History", "history"], ["Help", "help"],
                    ["Menu", "pause"]
                ]) {
                auto target = entry[1];
                d.add(button(entry[0], drawerClick(target)));
            }
            auto drawer = new Drawer(d);
            drawer.onClose = { drawerOpen = false; };
            layers.add(drawer);
        }
        return layers;
    }

    private void openOverlay(string name) {
        foreach (o; [
            Overlay.pause, Overlay.sheet, Overlay.journal, Overlay.map, Overlay.help,
            Overlay.history
        ])
            if (to!string(o) == name)
                overlay = o;
    }

    private Widget overlayWidget() {
        void close() {
            overlay = Overlay.none;
        }

        Modal modal;
        final switch (overlay) {
        case Overlay.none:
            return null;
        case Overlay.pause: {
                auto body = new Box(true);
                body.gap = 6;
                body.add(button("Resume", &close));
                body.add(button("Save (F5)", { quickSave(); }));
                body.add(button("Load (F9)", { quickLoad(); }));
                body.add(button("Back (B)", { goBack(); }, host.canBack()));
                body.add(button("Language: " ~ currentLanguage(), { cycleLanguage(1); }, languages.length > 1));
                body.add(button(format("Volume: %d", volume), { adjustVolume(1); }));
                body.add(button(format("Text size: %d%%", cast(int)(textScales[textScaleIndex] * 100 + 0.5f)), {
                        textScaleIndex = (textScaleIndex + 1) % cast(int) textScales.length;
                        applySettings();
                        saveSettings();
                    }));
                body.add(button("Layout: " ~ layoutNames[layoutIndex], {
                        layoutIndex = (layoutIndex + 1) % cast(int) layoutNames.length;
                        applySettings();
                        saveSettings();
                    }));
                body.add(button(fullscreen ? "Fullscreen: on" : "Fullscreen: off", {
                        toggleFullscreen();
                    }));
                body.add(button("Quit to title", {
                        autosave();
                        mode = Mode.title;
                        menuIndex = 0;
                        close();
                    }));
                if (notice.length && ui.now - noticeAt < 3000)
                    body.add(text(notice, FontRole.small, ui.theme.good));
                modal = new Modal("Paused", new ScrollBox(body), 460, 640);
                break;
            }
        case Overlay.sheet: {
                auto body = new Box(true);
                body.gap = 10;
                foreach (ref stat; host.view.hud) {
                    if (stat.id == "day")
                        continue;
                    auto line = new Box(false);
                    line.add(text(stat.label, FontRole.body, ui.theme.text, Overflow.ellipsis), 1);
                    auto number = text(format("%d", cast(long) stat.value), FontRole.body);
                    number.alignment = Align.right;
                    line.add(number);
                    auto group = new Box(true);
                    group.gap = 3;
                    group.add(line);
                    group.add(new Bar(stat.value, stat.hasMinimum ? stat.minimum : 0, stat.hasMaximum ? stat.maximum
                            : 100));
                    body.add(group);
                }
                modal = new Modal("Character", new ScrollBox(body), 640, 620);
                break;
            }
        case Overlay.journal: {
                auto body = new Box(true);
                body.gap = 4;
                foreach (ref section; host.journal()) {
                    body.add(text(section.title, FontRole.heading, ui.theme.accent));
                    foreach (line; section.lines)
                        body.add(text("  " ~ line, FontRole.body));
                    body.add(new Spacer(0, 8));
                }
                modal = new Modal("Journal", new ScrollBox(body), 820, 640);
                break;
            }
        case Overlay.map: {
                auto view = new MapView(this, host.mapState());
                view.flex = 1;
                view.onPick = (string id) {
                    foreach (i, ref r; rows)
                        if (host.view.stories[r.story].id == "walk" && host.view.stories[r.story].bindings.get("to", "") == id) {
                            close();
                            choose(i);
                            return;
                        }
                    notice = "You can't go there from here right now.";
                    noticeAt = ui.now;
                };
                auto body = new Box(true);
                body.add(view, 1);
                body.add(text("Click a place you can reach to go there.", FontRole.small, ui.theme.dim));
                modal = new Modal("The town", body, 1000, 640);
                break;
            }
        case Overlay.help: {
                auto body = new Box(true);
                body.gap = 6;
                foreach (line; [
                    "Spend your days getting ready for the Trials.",
                    "Each activity uses a part of the day. Stats rise by training, and many choices need a stat to be high enough: locked choices say what they want.",
                    "Up/Down and Enter, a number key, or the mouse choose.",
                    "C character, J journal, M map, H history, F5 save, F9 load, B back, F11 fullscreen, Tab or Esc for the menu.",
                    "The text size and the layout can be changed in the menu; a narrow window moves the status into a drawer."
                ])
                    body.add(text(line, FontRole.body));
                modal = new Modal("How to play", new ScrollBox(body), 760, 520);
                break;
            }
        case Overlay.history: {
                auto body = new Box(true);
                body.gap = 8;
                auto start = history.length > 20 ? history.length - 20 : 0;
                foreach (line; history[start .. $])
                    body.add(text(line, FontRole.body));
                modal = new Modal("Recent lines", new ScrollBox(body), 820, 640);
                break;
            }
        }
        modal.onClose = &close;
        return modal;
    }

    private string currentLanguage() {
        foreach (ref l; languages)
            if (l.tag == host.language)
                return l.name;
        return "English";
    }

    private Widget titleScreen() {
        auto layers = new Stack;
        auto back = new Backdrop;
        foreach (ref image; backgrounds)
            if (image.id == "title")
                back.texture = image.texture;
        back.colour = ui.theme.backdrop;
        back.overlay = 0x00000070;
        layers.add(back);
        auto column = new Box(true);
        column.add(new Spacer(0, 0, 1));
        auto heading = text(title, FontRole.title, ui.theme.text, Overflow.grow);
        heading.alignment = Align.centre;
        column.add(heading);
        if (subtitle.length) {
            auto sub = text(subtitle, FontRole.heading, ui.theme.accent);
            sub.alignment = Align.centre;
            column.add(sub);
        }
        column.add(new Spacer(0, 24));
        auto menu = new Box(true);
        menu.gap = 8;
        menu.widthUnits = 360;
        auto items = [
            button("New game", { menuIndex = 0; activateTitle(); }),
            button(exists(autosavePath) ? "Continue" : "Continue (no save yet)", {
                menuIndex = 1;
                activateTitle();
            }),
            button("Language: " ~ currentLanguage(), { menuIndex = 2; activateTitle(); }, languages.length > 1),
            button(format("Text size: %d%%", cast(int)(textScales[textScaleIndex] * 100 + 0.5f)), {
                menuIndex = 3;
                activateTitle();
            }),
            button("Quit", { menuIndex = 4; activateTitle(); })
        ];
        foreach (i, b; items) {
            b.alignment = Align.centre;
            b.selected = cast(int) i == menuIndex;
            menu.add(b);
        }
        auto row = new Box(false);
        row.add(new Spacer(0, 0, 1));
        row.add(menu);
        row.add(new Spacer(0, 0, 1));
        column.add(row);
        if (notice.length && ui.now - noticeAt < 4000) {
            auto n = text(notice, FontRole.small, ui.theme.bad);
            n.alignment = Align.centre;
            column.add(n);
        }
        column.add(new Spacer(0, 0, 1.4f));
        layers.add(column);
        return layers;
    }

    private Widget overScreen() {
        auto layers = new Stack;
        auto back = new Backdrop;
        back.texture = backgroundImage();
        back.colour = ui.theme.backdrop;
        back.overlay = 0x000000a0;
        layers.add(back);
        auto body = new Box(true);
        body.gap = 6;
        body.add(text("How it went", FontRole.heading, ui.theme.accent));
        foreach (ref stat; host.view.hud) {
            if (stat.id == "day")
                continue;
            auto line = new Box(false);
            line.add(text(stat.label, FontRole.body, ui.theme.text, Overflow.ellipsis), 1);
            auto n = text(format("%d", cast(long) stat.value), FontRole.body);
            n.alignment = Align.right;
            line.add(n);
            body.add(line);
        }
        auto achievements = host.achievements();
        if (achievements.length) {
            body.add(new Spacer(0, 10));
            body.add(text("Achievements", FontRole.heading, ui.theme.accent));
            foreach (a; achievements)
                body.add(text("  " ~ a, FontRole.body));
        }
        body.add(new Spacer(0, 10));
        body.add(text(sceneOnly ? "Esc: close" : "Enter: play again    Esc: title", FontRole.small, ui.theme.dim));
        layers.add(new Modal(sceneOnly ? "The end" : "The summer is over", new ScrollBox(body), 640, 620));
        return layers;
    }

    private Widget build() {
        Widget base;
        final switch (mode) {
        case Mode.title:
            base = titleScreen();
            break;
        case Mode.over:
            base = overScreen();
            break;
        case Mode.play:
            base = playScreen();
            break;
        }
        auto overlayW = mode == Mode.play ? overlayWidget() : null;
        if (overlayW is null)
            return base;
        auto layers = new Stack;
        layers.add(new Dimmed(base));
        layers.add(overlayW);
        return layers;
    }

    /// One frame: build the tree for the current state, lay it out in the window, draw it.
    void frame() {
        v_output_size(&ui.width, &ui.height);
        ui.pixelScale = v_pixel_scale();
        ui.now = v_ticks();
        {
            auto points = Size(ui.width / ui.pixelScale, ui.height / ui.pixelScale);
            ui.autoFit = max(0.75f, min(1.25f, min(points.w / 1280.0f, points.h / 720.0f)));
        }
        updateBattle();
        auto rootWidget = build();
        layout(ui, rootWidget);
        v_begin(ui.theme.backdrop);
        rootWidget.draw(ui);
        lastRoot = rootWidget;
    }

    // ---- battle --------------------------------------------------------------------

    /// Runs the night in real time (20 steps a second times the speed), and turns what the
    /// simulation did into effects. The view never touches the simulation but through the host.
    private void updateBattle() {
        if (!host.inBattle) {
            bview.lastTick = 0;
            bview.reset();
            return;
        }
        if (bcanvas is null)
            bcanvas = new BattleCanvas(host, bview);
        auto now = v_ticks();
        if (host.battlePhase == BattlePhase.night && !host.view.inScene && !host.battle.paused) {
            double due;
            if (smokeStepsPerFrame)
                due = smokeStepsPerFrame;
            else {
                auto elapsed = bview.lastTick ? now - bview.lastTick : 16;
                due = min(elapsed, 100UL) * 20.0 * host.battle.speed / 1000.0;
            }
            bview.stepDebt += due;
            int steps = min(cast(int) bview.stepDebt, 80);
            bview.stepDebt -= cast(int) bview.stepDebt;
            auto leaksBefore = host.battle.battle.leaks;
            while (steps-- > 0) {
                auto result = host.battleAdvance(1);
                bcanvas.collect();
                if (result == StepResult.moment) {
                    sfx("moment");
                    afterBoundary();
                    break;
                }
                if (result != StepResult.running) {
                    sfx(result == StepResult.won ? "stat_up" : "fail");
                    break;
                }
            }
            if (host.inBattle && host.battle.battle.leaks > leaksBefore)
                sfx("fail");
        }
        bview.lastTick = now;
        if (bcanvas !is null) {
            bcanvas.age();
            // a moment takes the camera to whoever it is about, and gives it back afterwards
            if (host.battlePhase == BattlePhase.moment && !bview.hasSaved)
                bcanvas.focusOnMoment();
            else if (host.battlePhase == BattlePhase.night && bview.hasSaved)
                bview.returnCamera();
            bview.ease();
        }
    }

    private string towerName(const TowerKind kind) {
        auto shown = host.display(kind.name);
        return shown.length ? shown : kind.name;
    }

    private void battleNotice(string text) {
        bview.say(text, ui.now);
    }

    /// What can be done now, in words: the build phase must say how to build.
    private Widget battleHelp() {
        auto box = panel(true, 8);
        box.gap = 3;
        if (host.battlePhase == BattlePhase.build) {
            box.add(text("Build phase: nothing moves until you begin the night.", FontRole.small, ui.theme.accent));
            if (bview.placeKind >= 0) {
                auto kind = host.battle.battle.setup.towers[bview.placeKind];
                box.add(text(format("Placing %s: click a free tile on the map to build it. Esc cancels.",
                        towerName(kind)), FontRole.small, ui.theme.gold));
            } else
                box.add(text("To build a lamp: 1) pick one in the bar below (or press 1-5), 2) click a free tile "
                        ~ "near the pale road. Click a lamp to upgrade or sell it.", FontRole.small, ui.theme.text));
            box.add(text("Scroll wheel zooms, arrow keys pan, F fits the map. Press Begin the night when ready.",
                    FontRole.small, ui.theme.dim));
        } else if (bview.placeKind >= 0) {
            box.add(text("Click a free tile to build. Esc cancels.", FontRole.small, ui.theme.gold));
        } else
            return null;
        return box;
    }

    /// True when nothing on screen can change without an event: the player may skip drawing.
    bool battleIdle() {
        if (mode != Mode.play || !host.inBattle || bview.easing || bview.flashes.length || host.view.inScene)
            return false;
        if (bview.notice.length && ui.now - bview.noticeAt < 3600)
            return false;
        return host.battlePhase == BattlePhase.build || host.battlePhase == BattlePhase.ended
            || host.battle.paused;
    }

    private Widget battleTopBar(bool compact) {
        auto bar = panel(false, 8);
        const b = &host.battle.battle;
        string phase = host.battlePhase == BattlePhase.build ? "Build" : host.battlePhase == BattlePhase.ended ? "Over" : host
            .battle.paused ? "Paused" : format("Night  x%d", host.battle.speed);
        bar.add(text(phase, FontRole.heading, ui.theme.accent, Overflow.ellipsis), 0.8f);
        bar.add(text(format("Oil %d", b.credits), FontRole.body, ui.theme.gold, Overflow.ellipsis), 1);
        bar.add(text(format("Leaks %d/%d", b.leaks, b.setup.maxLeaks), FontRole.body,
                b.leaks * 2 >= b.setup.maxLeaks ? ui.theme.bad : ui.theme.text, Overflow.ellipsis), 1);
        if (!compact) {
            bar.add(text(format("Fallen %d", b.kills), FontRole.body, ui.theme.text, Overflow.ellipsis), 1);
            bar.add(text(format("%d:%02d", b.stepIndex / 1200, (b.stepIndex / 20) % 60), FontRole.body, ui.theme.dim,
                    Overflow.ellipsis), 0.6f);
        }
        return bar;
    }

    private void delegate() paletteClick(int kind) {
        return{ bview.placeKind = bview.placeKind == kind ? -1 : kind; bview.targeting = false; };
    }

    private Widget battlePalette(SizeClass cls) {
        auto bar = panel(false, 6);
        bar.gap = 6;
        const b = &host.battle.battle;
        int shown;
        foreach (i, ref kind; b.setup.towers) {
            if (!kind.buildable)
                continue;
            ++shown;
            auto label = format("%s  %d", towerName(kind), kind.cost);
            bool affordable = kind.cost <= b.credits;
            auto button = new Button(label, paletteClick(cast(int) i));
            button.role = cls == SizeClass.compact ? FontRole.small : FontRole.body;
            button.prefix = format("%d", shown);
            button.selected = bview.placeKind == cast(int) i;
            button.id = format("tower%d", i);
            if (!affordable)
                button.enabled = true; // clickable: the reason is shown when placing fails
            bar.add(button, 1);
        }
        return bar;
    }

    private string describeUnit(int id) {
        const b = &host.battle.battle;
        foreach (s; 0 .. b.structureCount) {
            if (b.sId[s] != id)
                continue;
            auto kind = b.setup.towers[b.sKind[s]];
            string head = b.sIsHero[s] ? heroName(id) : towerName(kind);
            string line = format("%s  hp %d/%d", head, b.sHp[s], b.sMaxHp[s]);
            if (b.sShield[s] > 0)
                line ~= format("  shield %d", b.sShield[s]);
            if (!b.sIsHero[s])
                line ~= format("  level %d", b.sLevel[s]);
            if (!b.sAlive[s])
                line ~= b.sIsHero[s] ? "  (down)" : "  (ruin)";
            return line;
        }
        return "";
    }

    private string heroName(int id) {
        switch (id) {
        case 9001:
            return host.display("ilse");
        case 9002:
            return host.display("corvin");
        case 9003:
            return host.display("wren");
        default:
            return format("Hero %d", id);
        }
    }

    private Widget battleSidePanel() {
        auto p = panel(true, 8);
        p.gap = 6;
        const b = &host.battle.battle;
        // heroes: a button each, with health
        foreach (s; 0 .. b.structureCount) {
            if (!b.sIsHero[s])
                continue;
            auto id = b.sId[s];
            string label = format("%s  %d/%d%s", heroName(id), max(0, b.sHp[s]), b.sMaxHp[s], b.sAlive[s] ? ""
                    : "  down");
            auto button = new Button(label, { bview.selectedId = id; bview.placeKind = -1; });
            button.role = FontRole.small;
            button.selected = bview.selectedId == id;
            button.id = format("hero%d", id);
            p.add(button);
        }
        if (bview.selectedId >= 0) {
            p.add(text(describeUnit(bview.selectedId), FontRole.small, ui.theme.text));
            int sel = bview.selectedId;
            int slot = -1;
            foreach (s; 0 .. b.structureCount)
                if (b.sId[s] == sel)
                    slot = s;
            if (slot >= 0 && b.sAlive[slot]) {
                if (b.sIsHero[slot]) {
                    auto ak = b.sAbilityKind[slot];
                    if (ak >= 0) {
                        auto ability = b.setup.towers[ak];
                        string label = towerName(ability);
                        bool ready = b.sAbilityCd[slot] == 0;
                        auto bt = new Button(ready ? "Use " ~ label : format("%s (%d)", label, (b.sAbilityCd[slot] + 19) / 20),
                        {
                            if (ability.primitive == Primitive.burn) {
                                bview.targeting = true;
                                bview.placeKind = -1;
                                battleNotice("Click where the flare should land.");
                            } else {
                                Command c;
                                c.action = CommandKind.useAbility;
                                c.target = sel;
                                c.q = -1;
                                c.r = -1;
                                string why;
                                if (!host.battleCommand(c, why))
                                    battleNotice(why);
                            }
                        });
                        bt.role = FontRole.small;
                        bt.enabled = ready && host.battlePhase == BattlePhase.night;
                        p.add(bt);
                    }
                    p.add(text("Click the ground to order a move.", FontRole.small, ui.theme.dim));
                } else {
                    auto kind = b.setup.towers[b.sKind[slot]];
                    auto up = new Button(format("Upgrade  %d", kind.cost * b.sLevel[slot]), {
                        Command c;
                        c.action = CommandKind.upgrade;
                        c.target = sel;
                        string why;
                        if (!host.battleCommand(c, why))
                            battleNotice(why);
                    });
                    up.role = FontRole.small;
                    up.enabled = b.sLevel[slot] < 3 && kind.buildable;
                    p.add(up);
                    auto sell = new Button(format("Sell  %d", kind.cost * b.sLevel[slot] / 2), {
                        Command c;
                        c.action = CommandKind.sell;
                        c.target = sel;
                        string why;
                        if (host.battleCommand(c, why))
                            bview.selectedId = -1;
                        else
                            battleNotice(why);
                    });
                    sell.role = FontRole.small;
                    sell.enabled = kind.buildable;
                    p.add(sell);
                    if (b.sHp[slot] < b.sMaxHp[slot]) {
                        auto mend = new Button(format("Repair  %d", (b.sMaxHp[slot] - b.sHp[slot] + 1) / 2), {
                            Command c;
                            c.action = CommandKind.repair;
                            c.target = sel;
                            string why;
                            if (!host.battleCommand(c, why))
                                battleNotice(why);
                        });
                        mend.role = FontRole.small;
                        p.add(mend);
                    }
                }
            }
        } else {
            p.add(text(bview.placeKind >= 0 ? "Click a free, open tile to build." : "Click a tower or a hero.",
                    FontRole.small, ui.theme.dim));
        }
        return p;
    }

    private Widget battleControls() {
        auto bar = panel(false, 6);
        bar.gap = 6;
        if (host.battlePhase == BattlePhase.build) {
            bar.add(button("Begin the night", {
                    if (!host.battleBegin())
                        fail(host.error);
                    else {
                        if (host.judgeChipped > 0)
                            battleNotice("");
                        autosave();
                    }
                }), 2.0f);
        } else {
            auto pause = button(host.battle.paused ? "Resume (Space)" : "Pause (Space)", {
                host.battle.paused = !host.battle.paused;
            });
            bar.add(pause, 1.6f);
            foreach (speed; [1, 2, 4]) {
                auto b = new Button(format("x%d", speed), { host.battle.speed = speed; });
                b.role = FontRole.body;
                b.selected = host.battle.speed == speed;
                bar.add(b, 0.4f);
            }
        }
        bar.add(button("Fit (F)", { bview.fitted = false; }), 0.6f);
        bar.add(button("Abandon", {
                if (!host.battleAbandon())
                    fail(host.error);
                else
                    afterBoundary();
            }), 0.8f);
        return bar;
    }

    private Widget battleResultPanel() {
        const b = &host.battle.battle;
        auto body = new Box(true);
        body.gap = 8;
        string head = b.outcome == Outcome.won ? "The terraces held." : b.outcome == Outcome.withdrawn
            ? "You sounded the retreat." : "The line broke.";
        body.add(text(head, FontRole.heading, b.outcome == Outcome.won ? ui.theme.good : ui.theme.bad));
        body.add(text(format("%d fell on the road. %d got past the last lamp.", b.kills, b.leaks), FontRole.body));
        void proceed() {
            if (!host.battleAccept())
                fail(host.error);
            else {
                autosave();
                afterBoundary();
            }
        }

        if (b.outcome == Outcome.won || b.outcome == Outcome.withdrawn) {
            body.add(button("Continue", &proceed));
        } else {
            body.add(button("Try the night again", {
                    if (!host.battleRetry())
                        fail(host.error);
                    else
                        afterBoundary();
                }));
            body.add(button("Accept the loss and go on", &proceed));
        }
        return new Modal("The night is over", body, 520, 320);
    }

    /// The whole battle screen: the canvas, with the HUD above and below, a side panel, and a
    /// moment's scene over the dimmed battle.
    private Widget battleScreen(SizeClass cls) {
        if (bcanvas is null)
            bcanvas = new BattleCanvas(host, bview);
        auto canvas = bcanvas;
        canvas.flex = 1;
        auto main = new Box(false);
        main.gap = 0;
        main.add(canvas, 1);
        if (cls != SizeClass.compact) {
            auto side = new Box(true);
            side.widthUnits = 230;
            side.gap = 6;
            side.add(new MiniMap(host, bview, canvas));
            side.add(battleSidePanel());
            main.add(side);
        }
        auto column = new Box(true);
        column.gap = 0;
        column.add(battleTopBar(cls == SizeClass.compact));
        if (auto help = battleHelp())
            column.add(help);
        // the middle takes what is left and never pushes the palette and controls off the screen
        column.add(new Squeezable(main), 1);
        if (cls == SizeClass.compact)
            column.add(battleSidePanel());
        column.add(battlePalette(cls));
        column.add(battleControls());
        auto layers = new Stack;
        auto back = new Backdrop;
        back.colour = ui.theme.backdrop;
        layers.add(back);
        if (host.view.inScene) {
            layers.add(new Dimmed(column));
            layers.add(dialogue(cls));
        } else {
            layers.add(column);
            if (host.battlePhase == BattlePhase.ended)
                layers.add(battleResultPanel());
            else if (bview.notice.length && ui.now - bview.noticeAt < 3500) {
                auto note = new Box(true);
                note.add(new Spacer(0, 0, 1));
                auto line = text(bview.notice, FontRole.body, ui.theme.gold, Overflow.ellipsis);
                auto holder = panel(false, 6);
                holder.add(line, 1);
                note.add(holder);
                note.add(new Spacer(0, 150));
                layers.add(note);
            }
        }
        return layers;
    }

    /// Keys of the battle screen: tower numbers, pan, zoom, pause, begin.
    bool battleEvent(int type, int key, string typed) {
        if (type == 2 && host.battlePhase == BattlePhase.build) {
            if (!host.battleBegin())
                return fail(host.error);
            autosave();
            return true;
        }
        if (type != 6)
            return false;
        auto canvas = bcanvas;
        switch (key) {
        case 27:
            if (bview.placeKind >= 0 || bview.targeting || bview.selectedId >= 0) {
                bview.placeKind = -1;
                bview.targeting = false;
                bview.selectedId = -1;
                return true;
            }
            return false;
        case ' ':
            if (host.battlePhase == BattlePhase.night)
                host.battle.paused = !host.battle.paused;
            return true;
        case 'f':
            bview.fitted = false;
            return true;
        case KeyLeft:
        case 'a':
            if (canvas !is null)
                canvas.pan(-60, 0);
            return true;
        case KeyRight:
        case 'd':
            if (canvas !is null)
                canvas.pan(60, 0);
            return true;
        case KeyUp:
        case 'w':
            if (canvas !is null)
                canvas.pan(0, -60);
            return true;
        case KeyDown:
        case 's':
            if (canvas !is null)
                canvas.pan(0, 60);
            return true;
        case '=':
        case '+':
            if (canvas !is null)
                canvas.zoomAbout(1.25f, canvas.rect.x + canvas.rect.w / 2, canvas.rect.y + canvas.rect.h / 2);
            return true;
        case '-':
            if (canvas !is null)
                canvas.zoomAbout(0.8f, canvas.rect.x + canvas.rect.w / 2, canvas.rect.y + canvas.rect.h / 2);
            return true;
        default:
            break;
        }
        if (key >= '1' && key <= '9') {
            int number = cast(int)(key - '1'), seen;
            foreach (i, ref kind; host.battle.battle.setup.towers) {
                if (!kind.buildable)
                    continue;
                if (seen++ == number) {
                    bview.placeKind = bview.placeKind == cast(int) i ? -1 : cast(int) i;
                    bview.targeting = false;
                    return true;
                }
            }
        }
        return false;
    }

    // ---- input ---------------------------------------------------------------------

    enum KeyUp = 0x40000052, KeyDown = 0x40000051, KeyF1 = 0x4000003a, KeyF5 = 0x4000003e, KeyF9 = 0x40000042,
        KeyF11 = 0x40000044, KeyLeft = 0x40000050, KeyRight = 0x4000004f, KeyTab = 9;

    void cycleLanguage(int direction) {
        size_t index;
        foreach (i, ref l; languages)
            if (l.tag == host.language)
                index = i;
        index = (index + languages.length + direction) % languages.length;
        host.setLanguage(languages[index].tag);
        if (mode == Mode.play)
            afterBoundary();
        saveSettings();
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

    void toggleFullscreen() {
        fullscreen = !fullscreen;
        v_fullscreen(fullscreen ? 1 : 0);
        saveSettings();
    }

    bool quickSave() {
        saveProfile();
        string bytes;
        if (!host.save(bytes))
            notice = host.error;
        else {
            write(savePath, bytes);
            notice = "Saved";
        }
        noticeAt = v_ticks();
        return true;
    }

    /// Takes back the last choice or beat (session undo); a status line says when there is none.
    bool goBack() {
        if (!host.back())
            notice = host.error;
        else {
            overlay = Overlay.none;
            afterBoundary();
            notice = "Went back";
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
        case 3:
            textScaleIndex = (textScaleIndex + 1) % cast(int) textScales.length;
            applySettings();
            saveSettings();
            break;
        default:
            return false;
        }
        return true;
    }

    /// Returns false to quit.
    bool event(int type, int key, float x, float y, string typed) {
        if (type == 1)
            return false;
        if (type == 7 || type == 9 || type == 10) {
            ui.mouseX = x;
            ui.mouseY = y;
            if (lastRoot !is null && host.inBattle) {
                auto e = UiEvent(type, key, x, y, typed);
                if (lastRoot.event(ui, e))
                    return true;
            }
            if (type != 7)
                return true;
            if (mode == Mode.play && overlay == Overlay.none)
                foreach (i, b; rowButtons)
                    if (b.rect.contains(x, y))
                        selected = cast(int) i;
            return true;
        }
        if (type == 5 || type == 8) {
            ui.mouseX = x;
            ui.mouseY = y;
            // Pointer events go to the widget tree first (a click on a button, the wheel on a list).
            if (lastRoot !is null) {
                auto e = UiEvent(type, key, x, y, typed);
                if (lastRoot.event(ui, e))
                    return !failed;
            }
        }
        final switch (mode) {
        case Mode.title:
            return titleEvent(type, key);
        case Mode.over:
            if (type == 2)
                return newGame() || true;
            if (type == 6 && key == 27) {
                if (sceneOnly)
                    return false;
                mode = Mode.title;
                menuIndex = 0;
            }
            return true;
        case Mode.play:
            return playEvent(type, key, typed);
        }
    }

    bool titleEvent(int type, int key) {
        enum count = 5;
        if (type == 6 && key == KeyDown)
            menuIndex = (menuIndex + 1) % count;
        else if (type == 6 && key == KeyUp)
            menuIndex = (menuIndex + count - 1) % count;
        else if (type == 2)
            return activateTitle();
        else if (type == 6 && key == 27)
            return false;
        return true;
    }

    bool playEvent(int type, int key, string typed) {
        auto v = host.view;
        if (overlay != Overlay.none) {
            if (type == 6 && key == 27) {
                overlay = Overlay.none;
                return true;
            }
            if (type == 6 && ((overlay == Overlay.sheet && key == 'c') || (overlay == Overlay.journal && key == 'j') ||
                    (overlay == Overlay.map && key == 'm') || (overlay == Overlay.history && key == 'h') ||
                    (overlay == Overlay.help && key == KeyF1)))
                overlay = Overlay.none;
            if (overlay == Overlay.pause && type == 6 && key == KeyLeft)
                adjustVolume(-1);
            return true;
        }
        if (drawerOpen && type == 6 && (key == 27 || key == KeyTab)) {
            drawerOpen = false;
            return true;
        }
        bool typing = v.inScene && v.beat.kind == "input";
        if (host.inBattle && !v.inScene && battleEvent(type, key, typed))
            return true;
        if (type == 6) {
            switch (key) {
            case 27:
                if (sceneOnly)
                    return false;
                overlay = Overlay.pause;
                return true;
            case KeyTab:
                if (!typing && ui.sizeClass == SizeClass.compact) {
                    drawerOpen = !drawerOpen;
                    return true;
                }
                if (!sceneOnly)
                    overlay = Overlay.pause;
                return true;
            case KeyF1:
                overlay = Overlay.help;
                return true;
            case KeyF5:
                return quickSave();
            case KeyF9:
                return quickLoad();
            case 'b':
                if (!typing && overlay == Overlay.none)
                    return goBack();
                break;
            case KeyF11:
                toggleFullscreen();
                return true;
            case 'c':
                if (!typing && !sceneOnly) {
                    overlay = Overlay.sheet;
                    return true;
                }
                break;
            case 'j':
                if (!typing && !sceneOnly) {
                    overlay = Overlay.journal;
                    return true;
                }
                break;
            case 'm':
                if (!typing && !v.inScene && !sceneOnly) {
                    overlay = Overlay.map;
                    return true;
                }
                break;
            case 'h':
                if (!typing) {
                    overlay = Overlay.history;
                    return true;
                }
                break;
            default:
                break;
            }
        }
        if (v.inScene)
            return sceneEvent(type, key, typed);
        auto count = cast(int) rows.length;
        if (type == 6 && key == KeyDown && count) {
            selected = (selected + 1) % count;
            revealSelected = true;
        } else if (type == 6 && key == KeyUp && count) {
            selected = (selected + count - 1) % count;
            revealSelected = true;
        } else if (type == 6 && key >= '1' && key <= '9') {
            int row = cast(int)(key - '1');
            if (row < count)
                return choose(row) || true;
        } else if (type == 2 && count)
            return choose(selected) || true;
        return true;
    }

    bool sceneEvent(int type, int key, string typed) {
        auto v = host.view;
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
            // Space arrives as a key (advance) and as text; only the text types the space.
            if (type == 2 && key == ' ')
                return true;
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
            return true;
        }
        if (type == 5 || type == 2)
            return advance() || true;
        return true;
    }

    void close() {
        if (ui !is null) {
            ui.release();
            v_font_free(ui.fontBody);
            v_font_free(ui.fontHeading);
        }
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

/// Runs the player until the window is closed. Returns the process exit code.
int runGame(string manifest, string screenshot) {
    import std.process : environment;

    bool smoke = screenshot.length != 0;
    int forcedWidth, forcedHeight;
    auto size = environment.get("VARIS_SMOKE_SIZE", "");
    if (smoke && size.length) {
        import std.string : indexOf;

        auto at = size.indexOf('x');
        if (at > 0) {
            forcedWidth = to!int(size[0 .. at]);
            forcedHeight = to!int(size[at + 1 .. $]);
        }
    }
    auto player = new GamePlayer;
    scope (exit)
        player.close();
    if (!player.load(manifest, smoke, forcedWidth, forcedHeight))
        return 1;
    if (smoke)
        return smokeGame(player, screenshot);
    player.mode = player.sceneOnly ? Mode.play : Mode.title;
    if (player.sceneOnly && !player.newGame())
        return 1;
    bool redraw = true;
    for (;;) {
        // a build phase, a pause or a result changes nothing by itself: draw only after an event
        if (redraw || !player.battleIdle()) {
            player.frame();
            v_end();
            redraw = false;
            // the frame is on screen and nothing is waiting: the cheapest moment for a pause
            if (!player.host.inBattle)
                player.host.idle();
        }
        int key;
        float x, y;
        const(char)* typed;
        int event;
        while ((event = v_event(&key, &x, &y, &typed)) != 0) {
            redraw = true;
            if (!player.event(event, key, x, y, typed ? fromStringz(typed).idup : "")) {
                if (player.mode == Mode.play)
                    player.autosave();
                return player.failed ? 1 : 0;
            }
        }
        if (player.failed)
            return 1;
        v_delay();
    }
}

/// Plays the first night of a project that has battles, through the player's own widgets and
/// the host: builds a few towers along the route, captures one frame per zoom band, runs the night
/// (taking the first answer of every moment), accepts the result and prints the digest, so the
/// test can compare it with the same night played headless.
private int battleSmoke(GamePlayer player, string screenshot) {
    import std.path : stripExtension;
    import varis.game.route : unreachable;

    if (!player.newGame())
        return 1;
    player.smokeStepsPerFrame = 10;
    auto host = player.host;
    // the prologue and anything else before the hub
    foreach (_; 0 .. 200) {
        if (!host.view.inScene)
            break;
        if (host.view.beat.kind == "menu") {
            if (!player.advance(host.view.beat.choices[0].id))
                return 1;
        } else if (!player.advance())
            return 1;
    }
    // "Go up to the terraces"
    bool asked;
    foreach (i, ref story; host.view.stories)
        if (story.id == "go_up") {
            if (!player.rows.length || !host.choose(i, 0)) {
                writeln("battle smoke: go_up refused: ", host.error);
                return 1;
            }
            player.afterBoundary();
            asked = true;
            break;
        }
    if (!asked || host.battlePhase != BattlePhase.build) {
        writeln("battle smoke: no battle was asked for");
        return 1;
    }
    auto base = screenshot.stripExtension;
    player.frame();
    v_capture((base ~ "-build.bmp").toStringz);
    // towers along the route, a step off the road, every sixth tile from the Lantern end
    const b = &host.battle.battle;
    int[] route;
    {
        immutable sink = b.setup.sources[0].sink;
        immutable at = sink * b.tiles;
        int t = b.sourceTile[0];
        foreach (_; 0 .. b.tiles) {
            route ~= t;
            if (t == b.sinkTile[sink])
                break;
            immutable next = b.openDistance[at + t] != unreachable ? b.openParent[at + t] : b.throughParent[at + t];
            if (next < 0)
                break;
            t = next;
        }
    }
    int placed;
    foreach (k; 0 .. 12) {
        if (placed >= 6 || route.length < 10 * (k + 1))
            break;
        immutable t = route[$ - 6 * (k + 1)];
        foreach (d; [[1, 1], [-1, 1], [1, -1], [-1, -1], [2, 0], [-2, 0]]) {
            Command c;
            c.action = CommandKind.place;
            c.towerKind = 0;
            c.q = t % b.width + d[0];
            c.r = t / b.width + d[1];
            string why;
            if (host.battleCommand(c, why)) {
                writeln("place ", c.towerKind + 1, " ", c.q, " ", c.r);
                ++placed;
                break;
            }
        }
    }
    // one frame in each zoom band (plan §7.3); the frame times are the budget evidence
    ulong worst;
    foreach (band, zoom; [5.0f, 11.0f, 26.0f, 55.0f]) {
        player.bview.zoom = zoom;
        player.bview.fitted = true;
        player.bview.easing = false;
        auto before = v_ticks();
        player.frame();
        auto took = v_ticks() - before;
        if (took > worst)
            worst = took;
        v_capture((base ~ "-" ~ ["overview", "tactical", "standard", "close"][band] ~ ".bmp").toStringz);
    }
    player.bview.fitted = false;
    if (!host.battleBegin()) {
        writeln("battle smoke: ", host.error);
        return 1;
    }
    size_t frames;
    int moments;
    while (host.inBattle && host.battlePhase != BattlePhase.ended && frames++ < 60000) {
        auto before = v_ticks();
        player.frame();
        auto took = v_ticks() - before;
        if (took > worst)
            worst = took;
        if (frames == 30)
            v_capture((base ~ "-night.bmp").toStringz);
        if (host.view.inScene) {
            ++moments;
            if (host.view.beat.kind == "menu") {
                if (!player.advance(host.view.beat.choices[0].id))
                    return 1;
            } else if (!player.advance())
                return 1;
        }
    }
    if (host.battlePhase != BattlePhase.ended) {
        writeln("battle smoke: the night did not end");
        return 1;
    }
    player.frame();
    v_capture((base ~ "-over.bmp").toStringz);
    const done = &host.battle.battle;
    writeln("battle smoke: result ", done.outcome, " steps ", done.stepIndex, " kills ", done.kills, " leaks ",
            done.leaks, " digest ", cast(long) done.digest(), " moments ", moments);
    writeln("battle smoke: worst frame ", worst, " ms");
    if (!host.battleAccept()) {
        writeln("battle smoke: ", host.error);
        return 1;
    }
    player.afterBoundary();
    bool dawn;
    foreach (ref story; host.view.stories)
        dawn = dawn || story.id == "report";
    if (!dawn || host.inBattle) {
        writeln("battle smoke: the hub did not return with the dawn report");
        return 1;
    }
    player.frame();
    v_capture(screenshot.toStringz);
    writeln("checks passed");
    return 0;
}

/// Headless run for `make test-sdl`: starts a game, plays by the first sensible choice,
/// exercises text input, save/load and the overlays, and writes one screenshot.
/// Environment: VARIS_SMOKE_SIZE=WxH, VARIS_SMOKE_SCALE=index of the text sizes, VARIS_SMOKE_LAYOUT=
/// compact|regular|wide, VARIS_SMOKE_OVERLAY=map|journal|sheet|help|pause|history, VARIS_SMOKE_DRAWER=1.
private int smokeGame(GamePlayer player, string screenshot) {
    import std.process : environment;

    auto layout = environment.get("VARIS_SMOKE_LAYOUT", "");
    foreach (i, name; ["", "compact", "regular", "wide"])
        if (name.length && name == layout)
            player.layoutIndex = cast(int) i;
    auto scale = environment.get("VARIS_SMOKE_SCALE", "");
    if (scale.length)
        player.textScaleIndex = to!int(scale);
    player.applySettings();
    auto screen = environment.get("VARIS_SMOKE_SCREEN", "");
    if (screen == "title") {
        player.mode = Mode.title;
        player.frame();
        return v_capture(screenshot.toStringz) ? 0 : 1;
    }
    if (environment.get("VARIS_SMOKE_PLAY", "") == "ui")
        return uiPlaythrough(player, screenshot);
    if (environment.get("VARIS_SMOKE_PLAY", "") == "battle")
        return battleSmoke(player, screenshot);
    if (!player.newGame())
        return 1;
    bool captured, project = !player.sceneOnly;
    // VARIS_SMOKE_SCREEN=scene captures the first spoken line of a whole game instead of the hub.
    if (screen == "scene")
        project = false;
    size_t after;
    foreach (step; 0 .. 4000) {
        // After the screenshot, play on for a while: choices, scenes and toasts keep working.
        if (captured && ++after > 400)
            break;
        player.frame();
        auto v = player.host.view;
        if (player.mode == Mode.over)
            break;
        if (!project && v.inScene && v.beat.kind == "say" && !captured) {
            string bytes, restored;
            if (!player.host.save(bytes) || !player.host.restore(bytes) || !player.host.save(restored) || bytes != restored) {
                writeln("smoke: save round trip failed: ", player.host.error);
                return 1;
            }
            player.frame();
            if (!v_capture(screenshot.toStringz)) {
                writeln(fromStringz(v_error()).idup);
                return 1;
            }
            captured = true;
        }
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
                    player.frame();
                }
                player.overlay = Overlay.none;
                string bytes, again, third;
                // Presenting after a load logs the presentation, so a restored game is compared
                // with a second restore of the same bytes rather than with the bytes themselves.
                bool saved1 = player.host.save(bytes);
                bool restored = saved1 && player.host.restore(bytes);
                bool saved2 = restored && player.host.save(again);
                bool again2 = saved2 && player.host.restore(bytes) && player.host.save(third);
                if (!saved1 || !restored || !saved2 || !again2 || again != third) {
                    writeln("smoke: save round trip failed (save ", saved1, ", restore ", restored, ", save ", saved2,
                            ", second restore ", again2, ", equal ", again == third, "): ", player.host.error);
                    return 1;
                }
                if (!player.afterBoundary())
                    return 1;
                foreach (o; [
                    Overlay.sheet, Overlay.journal, Overlay.map, Overlay.help, Overlay.history,
                    Overlay.pause
                ])
                    if (environment.get("VARIS_SMOKE_OVERLAY", "") == to!string(o))
                        player.overlay = o;
                if (environment.get("VARIS_SMOKE_DRAWER", "") == "1")
                    player.drawerOpen = true;
                player.frame();
                if (!v_capture(screenshot.toStringz)) {
                    writeln(fromStringz(v_error()).idup);
                    return 1;
                }
                player.overlay = Overlay.none;
                player.drawerOpen = false;
                captured = true;
            }
            if (!player.choose(pick))
                return 1;
        }
        v_end();
    }
    if (!captured) {
        writeln("smoke: never reached a capture point");
        return 1;
    }
    writeln(project ? "SDL game, hub, overlays, input and save/load checks passed"
            : "SDL scene, assets, input/menu and save/load checks passed");
    return 0;
}

/// A whole game played the way a person plays it: only pointer and keyboard events go in, through
/// the same widget tree the window shows. Every click must change the game; one that does not is
/// reported (a soft lock). Prints a summary and writes a screenshot of the last screen.
private int uiPlaythrough(GamePlayer player, string screenshot) {
    import std.process : environment;

    auto verbose = environment.get("VARIS_SMOKE_VERBOSE", "") == "1";
    // The build the player makes: strength (default), wits or charm.
    auto build = environment.get("VARIS_SMOKE_BUILD", "strength");
    string wantFamily = build == "wits" ? "scholar" : build == "charm" ? "merchant" : "farm";
    string wantTemper = build == "wits" ? "nerdy" : build == "charm" ? "charming" : "athletic";
    string wantPoints = build;
    player.mode = Mode.title;
    player.menuIndex = 0;
    player.frame();
    // "New game" is a button on the title screen: click it.
    int[string] chosen, visits;
    string[] scenesSeen;
    size_t steps;
    size_t unchanged;
    bool paid;

    void click(Rect r) {
        player.event(7, 0, r.x + r.w / 2, r.y + r.h / 2, "");
        player.event(5, 0, r.x + r.w / 2, r.y + r.h / 2, "");
    }

    string signature() {
        auto v = player.host.view;
        return format("%s|%s|%s|%s|%s|%s", player.mode, v.turn, v.beat.scene, v.beat.index, v.stories.length,
                v.values.length ? to!string(v.values) : "");
    }

    // Title: the first button.
    player.frame();
    if (player.mode != Mode.title) {
        writeln("ui play: expected the title screen");
        return 1;
    }
    player.event(2, 13, 0, 0, "");
    if (player.mode != Mode.play) {
        writeln("ui play: New game did nothing");
        return 1;
    }
    while (steps++ < 3000 && player.mode == Mode.play) {
        player.frame();
        auto before = signature();
        auto v = player.host.view;
        string what;
        // VARIS_SMOKE_STOP_AT=<storylet id>: capture the first screen that offers it, and stop.
        auto stopAt = environment.get("VARIS_SMOKE_STOP_AT", "");
        if (stopAt.length && !v.inScene)
            foreach (ref st; v.stories)
                if (st.id == stopAt) {
                    if (environment.get("VARIS_SMOKE_SKIP", "") != "1" || (stopAt == "points" && v.values.get("points", 6) < 4)) {
                        if (screenshot.length)
                            v_capture(screenshot.toStringz);
                        writeln("ui play: stopped at ", stopAt);
                        return 0;
                    }
                }
        if (v.inScene) {
            auto kind = v.beat.kind;
            what = "scene " ~ v.beat.scene ~ " " ~ kind;
            if (v.beat.scene.length && (scenesSeen.length == 0 || scenesSeen[$ - 1] != v.beat.scene))
                scenesSeen ~= v.beat.scene;
            if (kind == "input") {
                player.event(4, 0, 0, 0, "Rowan Kestrel");
                player.event(2, 13, 0, 0, "");
            } else if (kind == "menu") {
                if (player.menuButtons.length)
                    click(player.menuButtons[0].rect);
            } else
                player.event(5, 0, player.ui.width / 2.0f, player.ui.height / 3.0f, "");
        } else {
            size_t pick = size_t.max;
            int best = int.min;
            auto at = v.beat.background;
            auto slot = cast(int) v.values.get("slot", 1);
            auto coins = cast(int) v.values.get("coins", 0);
            auto points = cast(int) v.values.get("points", 0);
            foreach (i, ref r; player.rows) {
                if (!r.enabled)
                    continue;
                auto story = v.stories[r.story];
                auto choice = story.choices[r.choice];
                auto sid = story.id, cid = nameOf(choice.id);
                int score = 0;
                string key = sid ~ "/" ~ cid;
                switch (sid) {
                case "family":
                    score = cid == wantFamily ? 100 : 0;
                    break;
                case "temper":
                    score = cid == wantTemper ? 100 : 0;
                    break;
                case "quirk_first":
                case "quirk_second":
                    score = 50;
                    break;
                case "points":
                    score = cid == wantPoints ? 80 : cid == "done" ? 100 : 10;
                    break;
                case "look_choice":
                    score = cid == "sporty" ? 100 : 0;
                    break;
                case "confirm":
                    score = cid == "begin" ? 100 : 0;
                    break;
                case "verdict":
                case "to_trials":
                    score = 100;
                    break;
                case "fee":
                    score = 90;
                    break;
                case "sleep":
                    score = slot >= 4 ? 95 : 1;
                    break;
                case "walk":
                    auto to = story.bindings.get("to", "");
                    if (slot >= 4)
                        score = to == "house" ? 90 : (at != "house" && to == "square" ? 80 : -50);
                    else if (coins >= 30 && !paid)
                        score = to == "square" || at == "square" ? 85 : -20;
                    else
                        score = 6 - 3 * visits.get(to, 0);
                    break;
                case "look":
                case "barred":
                    score = -100;
                    break;
                default:
                    score = 40 - 14 * chosen.get(key, 0);
                    if (sid.length > 6 && sid[0 .. 6] == "trial_")
                        score = 100;
                    if (coins < 30 && (sid == "unload" || sid == "stall_work" || sid == "haggle" || sid == "board"))
                        score += 10;
                    if (slot >= 4)
                        score = -60;
                }
                if (score > best) {
                    best = score;
                    pick = i;
                }
            }
            if (pick == size_t.max) {
                writeln("ui play: no enabled choice at turn ", v.turn);
                return 1;
            }
            auto story = v.stories[player.rows[pick].story];
            auto cid = nameOf(story.choices[player.rows[pick].choice].id);
            what = story.id ~ "/" ~ cid;
            if (story.id == "fee")
                paid = true;
            chosen[what] = chosen.get(what, 0) + 1;
            if (story.id == "walk")
                visits[story.bindings.get("to", "")] = visits.get(story.bindings.get("to", ""), 0) + 1;
            if (pick < player.rowButtons.length)
                click(player.rowButtons[pick].rect);
        }
        if (player.failed) {
            writeln("ui play: the player failed: ", player.host.error);
            return 1;
        }
        auto after = signature();
        if (verbose)
            writeln(steps, " ", what, " -> ", after != before ? "ok" : "NO EFFECT");
        if (after == before) {
            if (++unchanged > 2) {
                writeln("ui play: soft lock: an action had no effect: ", what, " (", before, ")");
                return 1;
            }
        } else
            unchanged = 0;
    }
    if (player.mode != Mode.over) {
        writeln("ui play: did not reach the end in ", steps, " steps");
        return 1;
    }
    player.frame();
    if (screenshot.length)
        v_capture(screenshot.toStringz);
    auto v = player.host.view;
    string ending;
    foreach (s; scenesSeen)
        if (s.length > 4 && s[0 .. 4] == "end_")
            ending = s;
    writeln("ui play: finished after ", steps, " steps: day ", cast(long) v.values.get("day", 0), ", ending ", ending,
            ", strength ", cast(long) v.values.get("strength", 0), ", wits ", cast(long) v.values.get("wits", 0), ", charm ",
            cast(long) v.values.get("charm", 0), ", grit ", cast(long) v.values.get("grit", 0), ", coins ",
            cast(long) v.values.get("coins", 0));
    writeln("SDL game, hub, overlays, input and save/load checks passed");
    return 0;
}
