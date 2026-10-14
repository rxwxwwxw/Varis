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

import varis.exception : isControlSignal, hostForm;
import varis;
import varis.logic.world;
import varis.narrative.codec;
import varis.narrative.registry;
import varis.narrative.scenes;
import varis.narrative.session;
import varis.narrative.persistence;
import varis.services.manifest;
import varis.services.tier : installTierEnforcement;
import varis.services.presentation : SceneChoice, SceneView, StageCharacter;
import varis.game.battle : Battle, Problem;
import varis.game.kinds : TowerKind;
import varis.game.types : BattleSetup, Command, CommandKind, Outcome, StepResult, MomentSpec, WaveSpec;
import varis.lib.battle : BattleHost, readSetup, outcomeTable, syncMods;

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

/// Where a battle stands (TOWER_DEFENSE_PLAN.md §5.5): asked for by the story and being built,
/// running, interrupted by a moment's scene, or over and waiting for the player to go on.
enum BattlePhase : ubyte {
    none,
    build,
    night,
    moment,
    ended,
}

class GameHost {
    LuaState state;
    Session session;
    GameView view;
    string error;
    Toast[] toasts;
    private LuaValue sessionValue, newSession, loadHook, afterChoose, finished, toastHook, journalHook,
    achievementsHook, mapHook;
    private LuaValue requestHook, setupHook, syncHook, resultHook;

    // ---- the battle bridge ----
    /// The battle in progress (null when `battlePhase == none`). The view reads its simulation
    /// state directly and never writes it: commands go through `battleCommand`.
    BattleHost battle;
    BattlePhase battlePhase;
    /// The world as it was when the battle was asked for (after the choice that asked), and
    /// before that choice: a retry restores the first, an abandon the second.
    string battleStart, battleHub;
    private LuaValue battleRequest, battleSetupTable;
    private string pendingHub;
    /// Notes the view shows about the battle (a refused command, a judge's chip).
    string[] battleNotes;
    /// The silent judge's last report: structures it chipped.
    int judgeChipped;
    private LuaValue sceneToken;
    string startScene;
    string language;
    /// Scene-only content (no project): an empty world and no hooks.
    bool sceneOnly;
    /// How many choices and beats `back` can take back; 0 turns it off. Applied to each new or
    /// restored session.
    size_t undoLimit = 64;
    private string sceneSource, sceneFile;

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
            installTierEnforcement(candidate, manifest, root);
            enum bootstrap = q"LUA
local cfg, root = ...
__varis_root = root
package.path = root .. "/?.varis;" .. root .. "/?/init.varis;" .. root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local entry = require(cfg.entry)
if cfg.language then narrative.source_language(cfg.language) end
local function resolve(path)
    if not path or path == "" then return nil end
    local module, name = path:match("^(.*)%.([^.]+)$")
    return require(module)[name]
end
return resolve(cfg.session), resolve(cfg.load), resolve(cfg.after_choose), resolve(cfg.finished),
    entry.take_toasts, entry.journal, entry.achievements, entry.map_state,
    resolve(cfg.battle_request), resolve(cfg.battle_setup), resolve(cfg.battle_sync),
    resolve(cfg.battle_result)
LUA";
            auto config = new LuaTable();
            config.rawset(LuaValue("entry"), LuaValue(manifest.entry));
            config.rawset(LuaValue("session"), LuaValue(manifest.session));
            config.rawset(LuaValue("load"), LuaValue(manifest.load));
            config.rawset(LuaValue("after_choose"), LuaValue(manifest.afterChoose));
            config.rawset(LuaValue("finished"), LuaValue(manifest.finished));
            config.rawset(LuaValue("language"), LuaValue(manifest.language));
            config.rawset(LuaValue("battle_request"), LuaValue(manifest.battleRequest));
            config.rawset(LuaValue("battle_setup"), LuaValue(manifest.battleSetup));
            config.rawset(LuaValue("battle_sync"), LuaValue(manifest.battleSync));
            config.rawset(LuaValue("battle_result"), LuaValue(manifest.battleResult));
            auto chunk = candidate.loadString(bootstrap, "=varis-gamehost");
            auto hooks = VM.callValue(candidate, LuaValue(chunk), [LuaValue(config), LuaValue(root)]);
            if (hooks.length < 12 || !isFunction(hooks[0])) {
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
            requestHook = hooks[8];
            setupHook = hooks[9];
            syncHook = hooks[10];
            resultHook = hooks[11];
            this.startScene = startScene;
            error = "";
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Scene-only content: a source file of `scene` and `character` declarations, played over an
    /// empty world. Its game is over when its scene stack empties.
    bool loadScenes(string source, string filename, string scene) {
        try {
            auto candidate = new LuaState;
            openLibs(candidate);
            auto fn = candidate.loadString(source, "@" ~ filename);
            LuaException failure;
            VM.callProtected(candidate, LuaValue(fn), null, failure);
            if (failure !is null) {
                if (isControlSignal(failure))
                    throw hostForm(failure); // an exit passes through
                error = failure.msg;
                return false;
            }
            state = candidate;
            sceneOnly = true;
            startScene = scene;
            sceneSource = source;
            sceneFile = filename;
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
            Session next;
            LuaValue nextValue;
            if (sceneOnly) {
                next = new Session(state, new World);
            } else {
                auto value = VM.callValue(state, newSession, [LuaValue(seed)]);
                if (!value.length) {
                    error = "the session function returned nothing";
                    return false;
                }
                next = unwrapSession(value[0]);
                nextValue = value[0];
            }
            if (startScene.length)
                next.playScene(startScene);
            auto previous = session;
            auto previousValue = sessionValue;
            session = next;
            sessionValue = nextValue;
            session.setUndoLimit(undoLimit);
            if (language.length)
                session.language = language;
            toasts = null;
            endBattle();
            if (!refresh()) {
                session = previous;
                sessionValue = previousValue;
                return false;
            }
            return checkBattle();
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
                    stat.label = translated("quality." ~ definition.id ~ ".label",
                            definition.label.length ? definition.label : definition.id);
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
                next.beat.speaker = translated("character." ~ next.beat.character ~ ".name",
                        nameOf(field(field(beat, "speaker"), "name")));
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
            if (sceneOnly)
                next.over = !next.inScene;
            else if (!finished.isNil) {
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

            string label = translated("quality." ~ name ~ ".label", definition.label.length ? definition.label : name);
            string amount = format("%s%d", delta > 0 ? "+" : "", cast(long) delta);
            if (entity != "player" && entity != "world") {
                auto who = session.registry.displayIn(language, state.getSymbol(entity));
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
            if (!refresh())
                return false;
            // a moment's scene has ended: the story's decisions become the battle's modifiers
            if (battlePhase == BattlePhase.moment && !view.inScene)
                return resumeAfterMoment();
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// The cross-save profile (`narrative.profile_*`) as text, for a host to keep beside its saves.
    bool profileSave(out string text) {
        if (state is null) {
            error = "no project loaded";
            return false;
        }
        try {
            auto result = VM.callValue(state, tfield(state.getGlobal("narrative"), "profile_save"), [
            ]);
            text = result.length ? nameOf(result[0]) : "";
            return text.length != 0;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Loads profile text written by `profileSave`; the old profile stays when it is invalid.
    bool profileLoad(string text) {
        if (state is null) {
            error = "no project loaded";
            return false;
        }
        try {
            VM.callValue(state, tfield(state.getGlobal("narrative"), "profile_load"), [
                LuaValue(text)
            ]);
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Whether `back` has something to take back.
    /// The host's idle moment (stage M): call it after a frame has been drawn and nothing is
    /// waiting. Collects garbage if the heap has grown enough to matter; returns whether it did.
    /// Never during a battle, and it changes no session state.
    bool idle() {
        if (session is null || battlePhase != BattlePhase.none)
            return false;
        return session.idle();
    }

    bool canBack() {
        return session !is null && battlePhase == BattlePhase.none && session.undoDepth() > 0;
    }

    /// Takes back the last choice or beat advance and shows what was current before it. Not
    /// available during a battle. Only the session is rolled back: state a project keeps in
    /// its own Lua tables is the project's to restore.
    bool back() {
        if (!ready())
            return false;
        if (battlePhase != BattlePhase.none) {
            error = "going back is not available during a battle";
            return false;
        }
        if (session.undoDepth() == 0) {
            error = "nothing to go back to";
            return false;
        }
        try {
            toasts = null;
            return read(session.undo());
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
            // the world before this choice: where an abandoned battle returns to
            if (!requestHook.isNil && battlePhase == BattlePhase.none)
                pendingHub = saveSession(session);
            session.choose(unwrapChoiceToken(chosen.token));
            if (!afterChoose.isNil)
                VM.callValue(state, afterChoose, [sessionValue]);
            if (!refresh())
                return false;
            return checkBattle();
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    bool save(out string bytes) {
        if (!ready())
            return false;
        if (battlePhase != BattlePhase.none) {
            error = "a battle is in progress: the game cannot be saved until it ends";
            return false;
        }
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
        if (state is null || (loadHook.isNil && !sceneOnly)) {
            error = "the project has no `load` function";
            return false;
        }
        try {
            Session restored;
            LuaValue restoredValue;
            if (sceneOnly) {
                restored = loadSession(state, bytes, LuaValue(new LuaNativeFunction((void* ignored, LuaValue[] args) {
                            return [wrapWorld(new World)];
                        }, "gamehost_world")));
            } else {
                auto value = VM.callValue(state, loadHook, [LuaValue(bytes)]);
                if (!value.length) {
                    error = "the load function returned nothing";
                    return false;
                }
                restored = unwrapSession(value[0]);
                restoredValue = value[0];
            }
            auto previousSession = session;
            auto previousValue = sessionValue;
            session = restored;
            sessionValue = restoredValue;
            session.setUndoLimit(undoLimit);
            if (language.length)
                session.language = language;
            toasts = null;
            endBattle();
            if (refresh())
                return checkBattle();
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

    // ---- battle -----------------------------------------------------------------------

    /// True while a battle is asked for, running, or waiting to be accepted.
    bool inBattle() const {
        return battlePhase != BattlePhase.none;
    }

    /// The bytes of the autosave: the world at the start of a battle while one is in progress
    /// (a save inside a battle is not possible; Continue starts the battle again), else a save.
    bool autosaveBytes(out string bytes) {
        if (battlePhase != BattlePhase.none && battleStart.length) {
            bytes = battleStart;
            return true;
        }
        return save(bytes);
    }

    private void endBattle() {
        battle = null;
        battlePhase = BattlePhase.none;
        battleRequest = LuaValue.init;
        battleSetupTable = LuaValue.init;
        battleNotes = null;
        judgeChipped = 0;
    }

    /// After a boundary: has the story asked for a battle? If so, build its setup from the world
    /// and start its build phase. A refused setup is an error and leaves the world untouched.
    private bool checkBattle() {
        if (requestHook.isNil || battlePhase != BattlePhase.none || view.inScene)
            return true;
        try {
            auto requested = VM.callValue(state, requestHook, [sessionValue]);
            if (!requested.length || requested[0].isNil)
                return true;
            // call results share a buffer: keep the request before the next call
            immutable request = requested[0];
            auto made = VM.callValue(state, setupHook, [sessionValue, request]);
            if (!made.length || made[0].isNil) {
                error = "battle_setup returned nothing";
                return false;
            }
            immutable setup = made[0];
            auto candidate = new BattleHost;
            auto problem = candidate.start(setup);
            if (!problem.ok()) {
                error = problem.field ~ ": " ~ problem.message;
                return false;
            }
            foreach (i, m; candidate.battle.setup.moments)
                if (session.registry.scene(m.scene) is null) {
                    error = "moments.scene: moment " ~ m.scene ~ " names an unknown scene";
                    return false;
                }
            battle = candidate;
            battleRequest = request;
            battleSetupTable = setup;
            battleStart = saveSession(session);
            battleHub = pendingHub.length ? pendingHub : battleStart;
            pendingHub = null;
            battlePhase = BattlePhase.build;
            battleNotes = null;
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// A command during the build phase or the night. Returns false with the reason in `reason`.
    bool battleCommand(Command c, out string reason) {
        if (battle is null || (battlePhase != BattlePhase.build && battlePhase != BattlePhase.night)) {
            reason = "there is no battle to command";
            return false;
        }
        return battle.battle.command(c, reason);
    }

    /// The silent days: a raid on a copy at 30 percent chips the thinnest structure (never
    /// destroying it). Then the night begins. Nothing is shown.
    bool battleBegin() {
        if (battle is null || battlePhase != BattlePhase.build) {
            error = "no battle is waiting to begin";
            return false;
        }
        try {
            auto setup = battle.battle.setup;
            setup.moments = [];
            setup.waves = setup.waves.dup;
            foreach (ref w; setup.waves) {
                w.count = w.count * 30 / 100;
                if (w.count < 1)
                    w.count = 1;
            }
            Battle raid;
            if (raid.begin(setup).ok()) {
                foreach (c; battle.battle.log) {
                    string why;
                    raid.command(c, why);
                }
                int[] before;
                foreach (s; 0 .. raid.structureCount)
                    before ~= raid.sHp[s];
                foreach (_; 0 .. 60_000) {
                    if (raid.step() != StepResult.running)
                        break;
                }
                int lostMost, lostSlot = -1;
                foreach (s; 0 .. raid.structureCount) {
                    if (raid.sIsHero[s])
                        continue;
                    immutable lost = before[s] - raid.sHp[s];
                    if (lost > lostMost && before[s] > 1) {
                        lostMost = lost;
                        lostSlot = s;
                    }
                }
                judgeChipped = 0;
                if (lostSlot >= 0) {
                    Command c;
                    c.action = CommandKind.setHp;
                    c.target = battle.battle.sId[lostSlot];
                    c.a = before[lostSlot] - lostMost > 1 ? before[lostSlot] - lostMost : 1;
                    string why;
                    if (battle.battle.command(c, why))
                        judgeChipped = 1;
                }
            }
            battlePhase = BattlePhase.night;
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Runs up to `steps` steps of the night. A moment pauses the battle and starts its scene
    /// (the view then shows the beats); an ending leaves the battle waiting in `ended`.
    StepResult battleAdvance(int steps) {
        if (battle is null || battlePhase != BattlePhase.night || battle.paused)
            return StepResult.running;
        try {
            immutable result = battle.pump(steps);
            if (result == StepResult.moment) {
                battlePhase = BattlePhase.moment;
                session.playScene(battle.momentScene());
                refresh();
            } else if (result != StepResult.running) {
                battlePhase = BattlePhase.ended;
            }
            return result;
        } catch (Exception failure) {
            error = failure.msg;
            return StepResult.running;
        }
    }

    private bool resumeAfterMoment() {
        try {
            auto context = new LuaTable();
            foreach (s; 0 .. battle.battle.structureCount)
                if (battle.battle.sIsHero[s] && battle.battle.sDowned[s] && !battle.battle.sAlive[s])
                    context.rawset(LuaValue("downed"), LuaValue(cast(long) battle.battle.sId[s]));
            auto mods = VM.callValue(state, syncHook, [sessionValue, LuaValue(context)]);
            if (mods.length)
                syncMods(battle, mods[0]);
            battlePhase = BattlePhase.night;
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// The finished battle's outcome as the table `battle_result` receives.
    LuaValue battleOutcome() {
        return battle is null ? LuaValue.init : outcomeTable(battle.battle);
    }

    /// The player goes on after the result (or accepts a loss): the world is written, the hub
    /// returns and the autosave is the caller's.
    bool battleAccept() {
        if (battle is null || battlePhase != BattlePhase.ended) {
            error = "no finished battle";
            return false;
        }
        try {
            auto info = new LuaTable();
            info.rawset(LuaValue("request"), battleRequest);
            info.rawset(LuaValue("setup"), battleSetupTable);
            VM.callValue(state, resultHook, [sessionValue, battleOutcome(), LuaValue(info)]);
            endBattle();
            if (!refresh())
                return false;
            return checkBattle();
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    /// Try again from the start of the battle: the world returns to the snapshot taken when it
    /// was asked for, and the same battle is built again.
    bool battleRetry() {
        if (battle is null || battleStart.length == 0) {
            error = "no battle to retry";
            return false;
        }
        immutable bytes = battleStart;
        immutable hub = battleHub;
        endBattle();
        if (!restore(bytes))
            return false;
        battleHub = hub;
        return true;
    }

    /// Leave the battle: the world returns to the hub as it was before the choice that asked.
    bool battleAbandon() {
        if (battle is null) {
            error = "no battle to abandon";
            return false;
        }
        immutable bytes = battleHub.length ? battleHub : battleStart;
        endBattle();
        pendingHub = null;
        return restoreNoBattle(bytes);
    }

    /// Restores without letting the pending request start a battle (used by abandon).
    private bool restoreNoBattle(string bytes) {
        try {
            Session restored;
            LuaValue restoredValue;
            auto value = VM.callValue(state, loadHook, [LuaValue(bytes)]);
            if (!value.length) {
                error = "the load function returned nothing";
                return false;
            }
            restored = unwrapSession(value[0]);
            restoredValue = value[0];
            session = restored;
            sessionValue = restoredValue;
            if (language.length)
                session.language = language;
            toasts = null;
            return refresh();
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    string display(string symbolName) {
        if (session is null)
            return symbolName;
        return session.registry.displayIn(language, state.getSymbol(symbolName));
    }

    /// The text of a plain message (a label or a name) in the current language, or `fallback`.
    private string translated(string key, string fallback) {
        if (language.length && session !is null)
            if (auto message = session.registry.translation(language, key))
                return message.literalText;
        return fallback;
    }
}
