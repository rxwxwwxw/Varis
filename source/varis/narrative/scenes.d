/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.scenes;

import varis.types;
import varis.table;
import varis.narrative.codec;

/// Scene programs are immutable records. No Lua frame survives a beat boundary.
struct SceneDefinition {
    string id;
    LuaValue[] beats;
}

struct CharacterDefinition {
    string id;
    LuaValue fields;
}

LuaValue field(LuaValue record, string key, LuaValue fallback = LuaValue.init) {
    if ((record.typeOf() == LuaType.UserData)) {
        auto payload = cast(ImmutableRecord) record.asUserData.payload;
        if (payload !is null)
            return payload.fields.get(key, fallback);
    }
    return fallback;
}

string nameOf(LuaValue value) nothrow {
    if (value.isSymbol)
        return value.asSymbol.name;
    if (value.isString)
        return value.asString;
    return "";
}

LuaValue[] sequence(LuaValue value) {
    if ((value.typeOf() == LuaType.UserData)) {
        auto payload = cast(ImmutableSequence) value.asUserData.payload;
        if (payload !is null)
            return payload.values;
    }
    return null;
}

/// Freeze author tables at registration; reject cycles, functions and nonportable leaves.
string freeze(LuaValue value, out LuaValue result, size_t depth = 0) {
    if (depth > 32)
        return "scene data is cyclic or too deeply nested";
    if (!value.isTable) {
        if (value.isNil || value.isBoolean || value.isInteger || value.isString || value.isSymbol) {
            result = value;
            return "";
        }
        if (value.isFloat && value.asFloat == value.asFloat && value.asFloat <= double.max && value.asFloat >= -double
                .max) {
            result = value;
            return "";
        }
        return "scene data must contain portable scalar values and tables";
    }
    auto table = value.asTable;
    LuaValue key, next, item;
    size_t count;
    bool list = true;
    while (table.next(key, next, item)) {
        key = next;
        count++;
        if (!key.isInteger || key.asInteger < 1)
            list = false;
    }
    if (list && count) {
        auto values = new LuaValue[count];
        for (size_t i; i < count; i++) {
            auto source = table.rawget(LuaValue(cast(long) i + 1));
            if (source.isNil)
                return "scene sequences must be dense";
            auto error = freeze(source, values[i], depth + 1);
            if (error.length)
                return error;
        }
        result = immutableSequence(values);
    } else {
        // Records are the portable codec's boundary representation.
        LuaValue[string] fields;
        key = LuaValue.init;
        while (table.next(key, next, item)) {
            key = next;
            if (!key.isString)
                return "scene record keys must be strings";
            LuaValue frozen;
            auto error = freeze(item, frozen, depth + 1);
            if (error.length)
                return error;
            fields[key.asString] = frozen;
        }
        result = immutableRecord(fields);
    }
    return "";
}

/// Wording is excluded from gameplay identity, as it is for storylets.
LuaValue structural(LuaValue value) {
    if (!isRecord(value))
        return value;
    auto fields = (cast(ImmutableRecord) value.asUserData.payload).fields.dup;
    auto text = field(value, "text");
    fields.remove("text");
    if (text.isString) {
        import varis.narrative.translation : TranslationTemplate, parseTranslation;

        TranslationTemplate parsed;
        string error;
        if (parseTranslation(text.asString, parsed, error))
            fields["text_structure"] = LuaValue(parsed.structure());
        else
            fields["text_structure"] = text; // Invalid templates are rejected before play.
    }
    auto choices = sequence(field(value, "choices"));
    if (choices.length) {
        auto copied = new LuaValue[choices.length];
        foreach (i, choice; choices)
            copied[i] = structural(choice);
        fields["choices"] = immutableSequence(copied);
    }
    return immutableRecord(fields);
}

bool portableScalar(LuaValue value) {
    return value.isNil || value.isBoolean || value.isInteger || value.isString || value.isSymbol ||
        (value.isFloat && value.asFloat == value.asFloat && value.asFloat <= double.max && value.asFloat >= -double.max);
}

struct SceneFrame {
    string id;
    size_t pc;
    LuaValue locals;
}

class SceneState {
    SceneFrame[] frames;
    LuaValue stage;
    LuaValue beat;
    ulong revision;

    SceneState copy() {
        auto result = new SceneState;
        result.frames = frames.dup;
        result.stage = stage;
        result.beat = beat;
        result.revision = revision;
        return result;
    }

    LuaValue portable() {
        auto values = new LuaValue[frames.length];
        foreach (i, frame; frames)
            values[i] = immutableRecord([
            "scene": LuaValue(frame.id),
            "pc": LuaValue(cast(long) frame.pc),
            "locals": frame.locals
        ]);
        return immutableRecord([
            "frames": immutableSequence(values),
            "stage": stage,
            "revision": LuaValue(cast(long) revision)
        ]);
    }
}

import varis.narrative.registry : ContentRegistry;

LuaValue replaceField(LuaValue record, string key, LuaValue value, bool eraseNil = true) {
    LuaValue[string] fields;
    if ((record.typeOf() == LuaType.UserData)) {
        auto payload = cast(ImmutableRecord) record.asUserData.payload;
        if (payload !is null)
            fields = payload.fields.dup;
    }
    if (value.isNil && eraseNil)
        fields.remove(key);
    else
        fields[key] = value;
    return immutableRecord(fields);
}

bool isRecord(LuaValue value) {
    return (value.typeOf() == LuaType.UserData) && cast(ImmutableRecord) value.asUserData.payload !is null;
}

string validateAttributes(ContentRegistry registry, string character, LuaValue attributes) {
    auto definition = registry.character(character);
    if (definition is null)
        return "unknown character '" ~ character ~ "'";
    if (attributes.isNil)
        return "";
    if (!isRecord(attributes))
        return "character attributes must be a record";
    auto allowed = field(definition.fields, "attributes");
    foreach (key, value; (cast(ImmutableRecord) attributes.asUserData.payload).fields) {
        bool found;
        foreach (option; sequence(field(allowed, key)))
            if (luaRawEqual(value, option))
                found = true;
        if (!found)
            return "unknown attribute '" ~ key ~ "' or value for character '" ~ character ~ "'";
    }
    return "";
}

string validateScenes(ContentRegistry registry) {
    foreach (definition; registry.characters) {
        if (!isRecord(definition.fields))
            return "character body must be a record: " ~ definition.id;
        auto name = field(definition.fields, "name");
        if (!name.isNil && !name.isString)
            return "character name must be text: " ~ definition.id;
        auto tag = field(definition.fields, "tag");
        if (!tag.isNil && !nameOf(tag).length)
            return "character tag must be named: " ~ definition.id;
        auto attributes = field(definition.fields, "attributes");
        if (!attributes.isNil && !isRecord(attributes))
            return "character attributes must be a record: " ~ definition.id;
        if (isRecord(attributes))
            foreach (key, allowed; (cast(ImmutableRecord) attributes.asUserData.payload).fields) {
                auto options = sequence(allowed);
                if (!key.length || !options.length)
                    return "character attribute requires allowed values: " ~ definition.id;
                foreach (option; options)
                    if (!portableScalar(option))
                        return "character attribute values must be scalars: " ~ definition.id;
            }
        auto problem = validateAttributes(registry, definition.id, field(definition.fields, "defaults"));
        if (problem.length)
            return problem;
    }
    string[] ids;
    foreach (ref definition; registry.scenes) {
        foreach (i, ref beat; definition.beats) {
            if (!isRecord(beat))
                return "scene beat must be a record: " ~ definition.id;
            auto kind = nameOf(field(beat, "kind"));
            if (!field(beat, "text").isNil) {
                if (!field(beat, "text").isString)
                    return "scene line requires text: " ~ definition.id;
                auto id = nameOf(field(beat, "id"));
                if (!id.length) {
                    import std.conv : to;

                    id = definition.id ~ "." ~ (i + 1).to!string;
                    beat = replaceField(beat, "id", LuaValue(id));
                }
                foreach (previous; ids)
                    if (previous == id)
                        return "duplicate scene line id: " ~ id;
                ids ~= id;
            }
            switch (kind) {
            case "say":
            case "narration":
                if (!field(beat, "text").isString)
                    return "scene line requires text: " ~ definition.id;
                if (kind == "narration")
                    break;
                goto case "show";
            case "show":
            case "hide":
                auto character = nameOf(field(beat, "character"));
                auto problem = validateAttributes(registry, character, field(beat, "attributes"));
                if (problem.length)
                    return definition.id ~ ": " ~ problem;
                if (kind == "show" && !nameOf(field(beat, "slot")).length)
                    return "show requires a named slot";
                break;
            case "jump":
            case "call":
                auto target = nameOf(field(beat, "target"));
                if (target != "hub" && registry.scene(target) is null)
                    return "unknown scene '" ~ target ~ "'";
                if (kind == "call" && target == "hub")
                    return "call cannot target hub";
                break;
            case "menu":
                auto options = sequence(field(beat, "choices"));
                if (!options.length)
                    return "scene menu requires choices";
                string[] choices;
                foreach (option; options) {
                    auto id = nameOf(field(option, "id"));
                    if (!id.length || !field(option, "text").isString)
                        return "menu choice requires id and text";
                    foreach (previous; choices)
                        if (previous == id)
                            return "duplicate menu choice";
                    choices ~= id;
                    if (registry.scene(nameOf(field(option, "target"))) is null)
                        return "unknown menu target";
                }
                break;
            case "input":
            case "set":
                if (!nameOf(field(beat, "local")).length)
                    return "input/set requires a local name";
                if (kind == "set" && !portableScalar(field(beat, "value")))
                    return "scene locals must be portable scalars";
                break;
            case "background":
                if (!nameOf(field(beat, "tag")).length)
                    return "background requires a tag";
                break;
            case "audio":
                auto tag = field(beat, "tag");
                if (!tag.isNil && !nameOf(tag).length)
                    return "audio tag must be named";
                if (!nameOf(field(beat, "channel")).length)
                    return "audio requires a channel";
                break;
            case "return":
            case "pause":
            case "transition":
            case "screen":
            case "picture":
            case "ended":
                break;
            default:
                return "unknown scene beat kind '" ~ kind ~ "' in '" ~ definition.id ~ "'";
            }
        }
    }
    return "";
}

string applyBeat(ContentRegistry registry, SceneState state, LuaValue beat) {
    auto kind = nameOf(field(beat, "kind"));
    auto character = nameOf(field(beat, "character"));
    if (kind == "show" || kind == "hide" || kind == "say") {
        auto chars = field(state.stage, "characters");
        auto current = field(chars, character);
        if (current.isNil)
            current = immutableRecord([
            "attributes": field(registry.character(character).fields, "defaults", immutableRecord(null))
        ]);
        if (kind == "show")
            current = replaceField(current, "slot", field(beat, "slot"));
        if (kind == "hide")
            current = replaceField(current, "slot", LuaValue.init);
        auto attributes = field(beat, "attributes");
        if (isRecord(attributes)) {
            auto merged = field(current, "attributes");
            foreach (key, value; (cast(ImmutableRecord) attributes.asUserData.payload).fields)
                merged = replaceField(merged, key, value);
            current = replaceField(current, "attributes", merged);
        }
        // A slot contains at most one character; a later show replaces its occupant.
        if (kind == "show" && isRecord(chars)) {
            foreach (key, value; (cast(ImmutableRecord) chars.asUserData.payload).fields)
                if (key != character && luaRawEqual(field(value, "slot"), field(beat, "slot")))
                    chars = replaceField(chars, key, replaceField(value, "slot", LuaValue.init));
        }
        state.stage = replaceField(state.stage, "characters", replaceField(chars, character, current));
    } else if (kind == "background") {
        state.stage = replaceField(state.stage, "background", field(beat, "tag"));
    } else if (kind == "audio") {
        auto audio = field(state.stage, "audio");
        state.stage = replaceField(state.stage, "audio", replaceField(audio, nameOf(field(beat, "channel")), field(
                beat, "tag")));
    }
    return "";
}

/// Resolve control beats with a budget; publish only a completed boundary in the caller.
string seekBeat(ContentRegistry registry, SceneState state) {
    for (size_t steps; steps < 1000; steps++) {
        if (!state.frames.length) {
            state.beat = LuaValue.init;
            return "";
        }
        auto frame = &state.frames[$ - 1];
        auto definition = registry.scene(frame.id);
        if (definition is null)
            return "unknown scene '" ~ frame.id ~ "'";
        if (frame.pc >= definition.beats.length) {
            state.frames.length--;
            continue;
        }
        auto beat = definition.beats[frame.pc];
        auto kind = nameOf(field(beat, "kind"));
        if (kind == "jump" || kind == "call") {
            auto target = nameOf(field(beat, "target"));
            auto locals = frame.locals;
            frame.pc++;
            if (kind == "jump")
                state.frames.length--;
            if (target == "hub")
                state.frames.length = 0;
            else {
                if (state.frames.length >= 128)
                    return "scene call stack limit exceeded";
                state.frames ~= SceneFrame(target, 0, locals);
            }
        } else if (kind == "return") {
            state.frames.length--;
        } else if (kind == "set") {
            frame.locals = replaceField(frame.locals, nameOf(field(beat, "local")), field(beat, "value"), false);
            frame.pc++;
        } else {
            auto problem = applyBeat(registry, state, beat);
            if (problem.length)
                return problem;
            state.beat = beat;
            return "";
        }
    }
    return "scene control-flow limit exceeded";
}

SceneState restoreScene(ContentRegistry registry, LuaValue value, out string problem) {
    auto state = new SceneState;
    if (!isRecord(value)) {
        problem = "expected record";
        return null;
    }
    state.stage = field(value, "stage");
    auto revision = field(value, "revision");
    if (!revision.isInteger || revision.asInteger < 0) {
        problem = "invalid revision";
        return null;
    }
    state.revision = revision.asInteger;
    auto frames = field(value, "frames");
    if (frames.typeOf() != LuaType.UserData || cast(ImmutableSequence) frames.asUserData.payload is null) {
        problem = "invalid frames";
        return null;
    }
    foreach (saved; sequence(frames)) {
        auto id = nameOf(field(saved, "scene"));
        auto pc = field(saved, "pc");
        auto locals = field(saved, "locals");
        auto definition = registry.scene(id);
        if (definition is null || !pc.isInteger || pc.asInteger < 0 || pc.asInteger > definition.beats.length || !isRecord(
                locals)) {
            problem = "invalid position or locals";
            return null;
        }
        foreach (name, local; (cast(ImmutableRecord) locals.asUserData.payload).fields)
            if (!portableScalar(local)) {
                problem = "nonportable scene local";
                return null;
            }
        state.frames ~= SceneFrame(id, cast(size_t) pc.asInteger, locals);
    }
    if (state.frames.length > 128 || !isRecord(state.stage)) {
        problem = "invalid stack or stage";
        return null;
    }
    foreach (frame; state.frames.length ? state.frames[0 .. $ - 1] : state.frames) {
        auto definition = registry.scene(frame.id);
        if (frame.pc == 0 || nameOf(field(definition.beats[frame.pc - 1], "kind")) != "call") {
            problem = "invalid scene return address";
            return null;
        }
    }
    if (state.frames.length) {
        auto top = state.frames[$ - 1];
        auto definition = registry.scene(top.id);
        if (top.pc >= definition.beats.length) {
            problem = "beat does not match position";
            return null;
        }
        state.beat = definition.beats[top.pc];
        auto kind = nameOf(field(state.beat, "kind"));
        if (kind == "jump" || kind == "call" || kind == "return" || kind == "set") {
            problem = "position is not a beat boundary";
            return null;
        }
    }
    auto chars = field(state.stage, "characters");
    if (!chars.isNil && !isRecord(chars)) {
        problem = "invalid stage characters";
        return null;
    }
    auto background = field(state.stage, "background");
    if (!background.isNil && !nameOf(background).length) {
        problem = "invalid background";
        return null;
    }
    auto audio = field(state.stage, "audio");
    if (!audio.isNil && !isRecord(audio)) {
        problem = "invalid audio channels";
        return null;
    }
    if (isRecord(audio))
        foreach (channel, tag; (cast(ImmutableRecord) audio.asUserData.payload).fields)
            if (!channel.length || !nameOf(tag).length) {
                problem = "invalid audio tag";
                return null;
            }
    string[] slots;
    if (isRecord(chars))
        foreach (id, character; (cast(ImmutableRecord) chars.asUserData.payload).fields) {
            if (!isRecord(character) || !isRecord(field(character, "attributes"))) {
                problem = "invalid character state";
                return null;
            }
            auto slot = field(character, "slot");
            if (!slot.isNil) {
                auto name = nameOf(slot);
                if (!name.length) {
                    problem = "invalid stage slot";
                    return null;
                }
                foreach (previous; slots)
                    if (previous == name) {
                        problem = "duplicate stage slot";
                        return null;
                    }
                slots ~= name;
            }
            problem = validateAttributes(registry, id, field(character, "attributes"));
            if (problem.length)
                return null;
        }
    return state;
}
