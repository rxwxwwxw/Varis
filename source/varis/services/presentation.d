/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module varis.services.presentation;

import varis.exception : isControlSignal, hostForm;
import varis;
import varis.logic.world;
import varis.narrative.codec;
import varis.narrative.scenes;
import varis.narrative.session;
import varis.narrative.persistence;

struct StageCharacter {
    string id, slot;
    LuaValue attributes;
}

struct SceneChoice {
    LuaValue id;
    string text;
}

struct SceneView {
    string scene, kind, text, speaker, character, background;
    StageCharacter[] characters;
    SceneChoice[] choices;
    LuaValue audio;
    size_t index;
    bool finished;
    LuaValue rawBeat;
}

/// Status-returning adapter over the existing exception-based runtime. A host retains the
/// adapter, not Lua frames. Reading `view` never advances the session or consumes randomness.
class SceneHost {
    LuaState state;
    Session session;
    private LuaValue token;
    SceneView view;
    string error;
    string language;
    /// How many beats `back` can take back; 0 turns it off. Applied to each new or restored session.
    size_t undoLimit = 256;

    /// Re-renders the current boundary in another language (empty tag: the source language).
    bool setLanguage(string tag) {
        language = tag;
        if (session !is null)
            session.language = tag;
        return refresh();
    }

    bool loadContent(string source, string filename, string scene) {
        try {
            auto candidate = new SceneHost;
            candidate.state = new LuaState;
            openLibs(candidate.state);
            auto fn = candidate.state.loadString(source, "@" ~ filename);
            LuaException failure;
            VM.callProtected(candidate.state, LuaValue(fn), null, failure);
            if (failure !is null) {
                if (isControlSignal(failure))
                    throw hostForm(failure); // an exit passes through
                error = failure.msg;
                return false;
            }
            candidate.session = new Session(candidate.state, new World);
            candidate.session.playScene(scene);
            candidate.session.setUndoLimit(undoLimit);
            if (!candidate.refresh()) {
                error = candidate.error;
                return false;
            }
            state = candidate.state;
            session = candidate.session;
            token = candidate.token;
            view = candidate.view;
            error = "";
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    private bool ready() {
        if (state !is null && session !is null)
            return true;
        error = "no scene content loaded";
        return false;
    }

    bool refresh() {
        if (!ready())
            return false;
        try {
            SceneView next;
            if (session.data.scene is null || !session.data.scene.frames.length) {
                next.finished = true;
            } else {
                auto p = session.scenePresentation();
                auto beat = sequence(field(p, "beats"))[0];
                auto stage = field(p, "stage");
                token = field(p, "token");
                next.scene = nameOf(field(p, "scene"));
                next.index = cast(size_t) field(p, "beat_index").asInteger;
                next.kind = nameOf(field(beat, "kind"));
                next.text = nameOf(field(beat, "text"));
                next.character = nameOf(field(beat, "character"));
                next.speaker = nameOf(field(field(beat, "speaker"), "name"));
                next.background = nameOf(field(stage, "background"));
                next.audio = field(stage, "audio");
                foreach (definition; session.registry.characters) {
                    auto current = field(field(stage, "characters"), definition.id);
                    auto slot = nameOf(field(current, "slot"));
                    if (slot.length)
                        next.characters ~= StageCharacter(definition.id, slot, field(current, "attributes"));
                }
                next.rawBeat = beat;
                foreach (choice; sequence(field(beat, "choices")))
                    next.choices ~= SceneChoice(field(choice, "id"), nameOf(field(choice, "text")));
            }
            view = next;
            error = "";
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    bool advance(LuaValue input = LuaValue.init) {
        if (!ready())
            return false;
        if (view.finished) {
            error = "scene has finished";
            return false;
        }
        try {
            session.advanceScene(token, input);
            return refresh();
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    bool canBack() {
        return session !is null && session.undoDepth() > 0;
    }

    /// Takes back the last beat advance (beat-granularity rollback); the earlier beat is current again.
    bool back() {
        if (!ready())
            return false;
        if (session.undoDepth() == 0) {
            error = "nothing to go back to";
            return false;
        }
        try {
            session.undo();
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
            return true;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }

    bool restore(string bytes) {
        if (!ready())
            return false;
        try {
            auto restored = loadSession(state, bytes, LuaValue(new LuaNativeFunction((void* ignored, LuaValue[] args) {
                        return [wrapWorld(new World)];
                    }, "presentation_world")));
            auto previous = session;
            session = restored;
            session.setUndoLimit(undoLimit);
            if (language.length)
                session.language = language;
            if (refresh())
                return true;
            session = previous;
            return false;
        } catch (Exception failure) {
            error = failure.msg;
            return false;
        }
    }
}
