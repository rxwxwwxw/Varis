/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// A status-returning host for whole games: the storylet hub, scenes, the stage and a status
/// panel, over a project's own world factory, save and load hooks. `SceneHost` (presentation.d)
/// serves scene-only content with an empty world; this adapter serves a project that names its
/// session functions in its manifest (`varis play` reads the same manifest).
///
/// A host retains the adapter, not Lua frames. `view` is read-only and calls no engine code;
/// only `refresh`, `advance` and `choose` do, once per boundary, so drawing never consumes
/// randomness.
module varis.services.gamehost;

import varis;
import varis.logic.world;
import varis.narrative.codec;
import varis.narrative.registry;
import varis.narrative.scenes;
import varis.narrative.session;
import varis.narrative.persistence;
import varis.services.manifest;
import varis.services.presentation : SceneChoice, SceneView, StageCharacter;

/// One selectable line of the hub. A choice with a `require` that fails is `enabled == false`,
/// carries a reason in `because` and has no token.
struct GameChoice {
    LuaValue id;
    string title, text, because;
    bool enabled = true;
    LuaValue token;
}

struct GameStory {
    string id, title, text;
    string[string] bindings; // parameter name to the symbol or text it is bound to
    GameChoice[] choices;
}

/// A titled list of lines the project wants the player to be able to look up (clues, allies, items).
struct JournalSection {
    string title;
    string[] lines;
}

/// Where the player is and which places can be reached, for a map overlay.
struct MapState {
    string at;
    bool[string] reachable;
}

/// A visible quality of the status panel.
struct HudStat {
    string entity, id, label;
    double value = 0, minimum = 0, maximum = 0;
    bool hasMinimum, hasMaximum;
}

/// Something the player should be told about after a boundary: a stat change or a note.
struct Toast {
    string text;
    bool good = true;
}

struct GameView {
    /// True while a scene beat is current; `beat` then holds it. The stage fields of `beat`
    /// (background, characters, audio) are filled in the hub too.
    bool inScene;
    SceneView beat;
    GameStory[] stories;
    HudStat[] hud;
    double[string] values; // every number quality of the player and the world, by name
    string deck;
    ulong turn;
    bool over;
}

/// A field of a plain Lua table (the hooks return ordinary tables, not immutable records).
private LuaValue tfield(LuaValue table, string key) {
    return table.typeOf() == LuaType.Table ? table.asTable.rawget(LuaValue(key)) : LuaValue.init;
}

class GameHost {
    LuaState state;
    Session session;
    GameView view;
    string error;
    Toast[] toasts;
    private LuaValue sessionValue, newSession, loadHook, afterChoose, finished, toastHook, journalHook,
    achievementsHook, mapHook;
    private LuaValue sceneToken;
    string startScene;
    string language;

    /// Loads the project in `root`: runs its entry module (which registers and seals content)
    /// and resolves the manifest's session, load, after-choose and finished functions.
    bool loadProject(string root, string startScene) {
        try {
            auto manifest = loadManifest(root);
            if (!manifest.present || !manifest.entry.length || !manifest.session.length) {
                error = "the project has no manifest naming `entry` and `session`";
                return false;
            }
            auto candidate = new LuaState;
            openLibs(candidate);
            enum bootstrap = q"LUA
local cfg, root = ...
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local entry = require(cfg.entry)
if cfg.language then narrative.source_language(cfg.language) end
local function resolve(path)
    if not path or path == "" then return nil end
    local module, name = path:match("^(.*)%.([^.]+)$")
    return require(module)[name]
end
return resolve(cfg.session), resolve(cfg.load), resolve(cfg.after_choose), resolve(cfg.finished),
    entry.take_toasts, entry.journal, entry.achievements, entry.map_state
LUA";
            auto config = new LuaTable();
            config.rawset(LuaValue("entry"), LuaValue(manifest.entry));
            config.rawset(LuaValue("session"), LuaValue(manifest.session));
            config.rawset(LuaValue("load"), LuaValue(manifest.load));
            config.rawset(LuaValue("after_choose"), LuaValue(manifest.afterChoose));
            config.rawset(LuaValue("finished"), LuaValue(manifest.finished));
            config.rawset(LuaValue("language"), LuaValue(manifest.language));
            auto chunk = candidate.loadString(bootstrap, "=varis-gamehost");
            auto hooks = VM.callValue(candidate, LuaValue(chunk), [LuaValue(config), LuaValue(root)]);
            if (hooks.length < 8 || !isFunction(hooks[0])) {
                error = "the manifest has no usable `session` function";
                return false;
            }
            state = candidate;
            newSession = hooks[0];
            loadHook = hooks[1];
            afterChoose = hooks[2];
            finished = hooks[3];
            toastHook = hooks[4];
            journalHook = hooks[5];
            achievementsHook = hooks[6];
            mapHook = hooks[7];
            this.startScene = startScene;
            error = "";
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// A fresh game: a new session from the project, started at the initial scene (if any).
    bool newGame(long seed) {
        if (state is null) {
            error = "no project loaded";
            return false;
        }
        try {
            auto value = VM.callValue(state, newSession, [LuaValue(seed)]);
            if (!value.length) {
                error = "the session function returned nothing";
                return false;
            }
            auto next = unwrapSession(value[0]);
            if (startScene.length)
                next.playScene(startScene);
            auto previous = session;
            session = next;
            sessionValue = value[0];
            if (language.length)
                session.language = language;
            toasts = null;
            if (!refresh()) {
                session = previous;
                return false;
            }
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    private bool ready() {
        if (state !is null && session !is null)
            return true;
        error = "no game in progress";
        return false;
    }

    private double numberOf(LuaValue value, out bool ok) {
        ok = true;
        if (value.isInteger)
            return cast(double) value.asInteger;
        if (value.isFloat)
            return value.asFloat;
        ok = false;
        return 0;
    }

    private LuaValue qualityOf(string entity, string name) {
        auto library = state.getGlobal("quality");
        auto get = tfield(library, "get");
        auto result = VM.callValue(state, get, [
            state.getSymbol(entity), state.getSymbol(name), wrapWorld(session.world)
        ]);
        return result.length ? result[0] : LuaValue.init;
    }

    private void readStatus(ref GameView next) {
        foreach (definition; session.registry.qualityDefinitions()) {
            foreach (entity; ["player", "world"]) {
                bool ok;
                auto value = numberOf(qualityOf(entity, definition.id), ok);
                if (!ok)
                    continue;
                next.values[definition.id] = value;
                if (definition.visible) {
                    HudStat stat;
                    stat.entity = entity;
                    stat.id = definition.id;
                    stat.label = definition.label.length ? definition.label : definition.id;
                    stat.value = value;
                    bool bound;
                    stat.minimum = numberOf(definition.minimum, bound);
                    stat.hasMinimum = bound;
                    stat.maximum = numberOf(definition.maximum, bound);
                    stat.hasMaximum = bound;
                    next.hud ~= stat;
                }
                break;
            }
        }
    }

    private void readStage(LuaValue stage, ref SceneView target) {
        target.background = nameOf(field(stage, "background"));
        target.audio = field(stage, "audio");
        target.characters = null;
        foreach (definition; session.registry.characters) {
            auto current = field(field(stage, "characters"), definition.id);
            auto slot = nameOf(field(current, "slot"));
            if (slot.length)
                target.characters ~= StageCharacter(definition.id, slot, field(current, "attributes"));
        }
    }

    /// Reads the presentation of the current boundary. Draws from the session's RNG exactly as
    /// `session:present()` does, so the caller reads `view` afterwards rather than calling it again.
    bool refresh() {
        if (!ready())
            return false;
        try {
            return read(session.present());
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    private LuaValue lastPresentation;

    private bool read(LuaValue p) {
        try {
            lastPresentation = p;
            GameView next;
            next.turn = cast(ulong) field(p, "turn").asInteger;
            auto beats = field(p, "beats");
            if (!beats.isNil) {
                auto beat = sequence(beats)[0];
                sceneToken = field(p, "token");
                next.inScene = true;
                next.beat.scene = nameOf(field(p, "scene"));
                next.beat.index = cast(size_t) field(p, "beat_index").asInteger;
                next.beat.kind = nameOf(field(beat, "kind"));
                next.beat.text = nameOf(field(beat, "text"));
                next.beat.character = nameOf(field(beat, "character"));
                next.beat.speaker = nameOf(field(field(beat, "speaker"), "name"));
                foreach (choice; sequence(field(beat, "choices")))
                    next.beat.choices ~= SceneChoice(field(choice, "id"), nameOf(field(choice, "text")));
            } else {
                next.deck = nameOf(field(p, "deck"));
                foreach (story; sequence(field(p, "storylets"))) {
                    GameStory s;
                    s.id = nameOf(field(story, "id"));
                    s.title = nameOf(field(story, "title"));
                    s.text = nameOf(field(story, "text"));
                    auto bound = field(story, "bindings");
                    if (isRecord(bound))
                        foreach (name, value; (cast(ImmutableRecord) bound.asUserData.payload).fields)
                            s.bindings[name] = nameOf(value);
                    foreach (choice; sequence(field(story, "choices"))) {
                        GameChoice c;
                        c.id = field(choice, "id");
                        c.title = nameOf(field(choice, "title"));
                        c.text = nameOf(field(choice, "text"));
                        auto enabled = field(choice, "enabled");
                        c.enabled = enabled.isNil || (enabled.isBoolean && enabled.asBool);
                        c.because = nameOf(field(choice, "because"));
                        c.token = field(choice, "token");
                        s.choices ~= c;
                    }
                    next.stories ~= s;
                }
            }
            readStage(field(p, "stage"), next.beat);
            readStatus(next);
            if (!finished.isNil) {
                auto done = VM.callValue(state, finished, [sessionValue]);
                next.over = done.length && done[0].isBoolean && done[0].asBool;
            }
            view = next;
            collectToasts();
            error = "";
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    private void collectToasts() {
        if (toastHook.isNil)
            return;
        auto list = VM.callValue(state, toastHook, []);
        if (!list.length || list[0].isNil)
            return;
        auto library = list[0].asTable;
        for (long i = 1;; ++i) {
            auto item = library.rawget(LuaValue(i));
            if (item.isNil)
                break;
            auto text = nameOf(tfield(item, "text"));
            if (text.length) {
                toasts ~= Toast(text, true);
                continue;
            }
            auto name = nameOf(tfield(item, "name"));
            auto entity = nameOf(tfield(item, "entity"));
            auto definition = session.registry.quality(name);
            bool ok;
            auto delta = numberOf(tfield(item, "delta"), ok);
            if (!ok || definition is null || delta == 0)
                continue;
            import std.conv : to;
            import std.format : format;

            string label = definition.label.length ? definition.label : name;
            string amount = format("%s%d", delta > 0 ? "+" : "", cast(long) delta);
            if (entity != "player" && entity != "world") {
                auto who = session.registry.display(state.getSymbol(entity));
                toasts ~= Toast(format("%s %s: %s", who, label, amount), delta > 0);
            } else if (definition.visible)
                toasts ~= Toast(format("%s %s", amount, label), delta > 0);
        }
    }

    /// The project's journal, read on demand (a pure read of the world).
    JournalSection[] journal() {
        JournalSection[] result;
        if (!ready() || journalHook.isNil)
            return result;
        try {
            auto list = VM.callValue(state, journalHook, [sessionValue]);
            if (!list.length || list[0].isNil)
                return result;
            auto table = list[0].asTable;
            for (long i = 1;; ++i) {
                auto item = table.rawget(LuaValue(i));
                if (item.isNil)
                    break;
                JournalSection section;
                section.title = nameOf(tfield(item, "title"));
                auto lines = tfield(item, "lines");
                if (lines.typeOf() == LuaType.Table) {
                    auto lineTable = lines.asTable;
                    for (long j = 1;; ++j) {
                        auto line = lineTable.rawget(LuaValue(j));
                        if (line.isNil)
                            break;
                        section.lines ~= nameOf(line);
                    }
                }
                result ~= section;
            }
        } catch (Exception failure) {
            error = failure.msg;
        }
        return result;
    }

    string[] achievements() {
        string[] result;
        if (state is null || achievementsHook.isNil)
            return result;
        try {
            auto list = VM.callValue(state, achievementsHook, []);
            if (!list.length || list[0].isNil)
                return result;
            auto table = list[0].asTable;
            for (long i = 1;; ++i) {
                auto item = table.rawget(LuaValue(i));
                if (item.isNil)
                    break;
                result ~= nameOf(item);
            }
        } catch (Exception failure) {
            error = failure.msg;
        }
        return result;
    }

    MapState mapState() {
        MapState result;
        if (!ready() || mapHook.isNil)
            return result;
        try {
            auto value = VM.callValue(state, mapHook, [sessionValue]);
            if (!value.length || value[0].isNil)
                return result;
            result.at = nameOf(tfield(value[0], "at"));
            auto reachable = tfield(value[0], "reachable");
            if (reachable.typeOf() == LuaType.Table) {
                auto table = reachable.asTable;
                LuaValue previous, key, item;
                while (table.next(previous, key, item)) {
                    previous = key;
                    result.reachable[nameOf(key)] = true;
                }
            }
        } catch (Exception failure) {
            error = failure.msg;
        }
        return result;
    }

    /// Takes the pending toasts; the host shows them and forgets them.
    Toast[] takeToasts() {
        auto result = toasts;
        toasts = null;
        return result;
    }

    /// Acknowledges the current scene beat (with the player's input or menu choice, when it asks for one).
    bool advance(LuaValue input = LuaValue.init) {
        if (!ready())
            return false;
        if (!view.inScene) {
            error = "no scene beat is current";
            return false;
        }
        try {
            session.advanceScene(sceneToken, input);
            return refresh();
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Takes a hub choice by position. A disabled choice is refused with its reason.
    bool choose(size_t story, size_t choice) {
        if (!ready())
            return false;
        if (view.inScene || story >= view.stories.length || choice >= view.stories[story].choices.length) {
            error = "no such choice";
            return false;
        }
        auto chosen = view.stories[story].choices[choice];
        if (!chosen.enabled) {
            error = chosen.because;
            return false;
        }
        try {
            session.choose(unwrapChoiceToken(chosen.token));
            if (!afterChoose.isNil)
                VM.callValue(state, afterChoose, [sessionValue]);
            return refresh();
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    bool save(out string bytes) {
        if (!ready())
            return false;
        try {
            bytes = saveSession(session);
            error = "";
            return bytes.length != 0;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    bool restore(string bytes) {
        if (state is null || loadHook.isNil) {
            error = "the project has no `load` function";
            return false;
        }
        try {
            auto value = VM.callValue(state, loadHook, [LuaValue(bytes)]);
            if (!value.length) {
                error = "the load function returned nothing";
                return false;
            }
            auto previousSession = session;
            auto previousValue = sessionValue;
            session = unwrapSession(value[0]);
            sessionValue = value[0];
            if (language.length)
                session.language = language;
            toasts = null;
            if (refresh())
                return true;
            session = previousSession;
            sessionValue = previousValue;
            return false;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Switches the language texts are shown in (empty: the source language). Re-reads the
    /// boundary without advancing. A view, not state: it is never saved.
    bool setLanguage(string tag) {
        language = tag;
        if (session is null)
            return true;
        session.language = tag;
        if (lastPresentation.isNil)
            return true;
        try {
            return read(session.render(lastPresentation, tag));
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    string display(string symbolName) {
        if (session is null)
            return symbolName;
        return session.registry.display(state.getSymbol(symbolName));
    }
}
