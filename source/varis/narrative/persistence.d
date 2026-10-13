/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.persistence;

import varis.types;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.logic.world;
import varis.logic.model;
import varis.narrative.session;
import varis.narrative.codec;
import varis.narrative.fingerprint;
import varis.narrative.registry : narrativeRegistry;
import std.json;
import std.conv : to;
import std.algorithm : sort;

/// Save formats. Format 1 recorded the content identity with wording in it; format 2 does not
/// (a typo fix no longer invalidates saves) and adds the presentation revision, which is
/// informational. Format 1 saves are read with their own validation and are written back as 2.
/// Sessions that have entered a scene use format 3, so old readers reject rather than discard
/// the continuation. Sessions without scenes keep their exact format-2 representation.
enum saveFormat1 = "varis-session-1";
enum saveFormat2 = "varis-session-2";
enum saveFormat3 = "varis-session-3"; // Scene positions and engine-owned stage state.

/// Changing code/sampling semantics requires a new runtime identity.
enum narrativeRuntimeVersion = "varis-narrative-1/xorshift64star-tier-1";

/// Deterministic JSON independent of associative-array iteration order.
string canonicalJSON(JSONValue value) {
    if (value.type == JSONType.object) {
        auto names = value.object.keys;
        names.sort;
        string result = "{";
        foreach (i, name; names) {
            if (i)
                result ~= ",";
            result ~= JSONValue(name).toString ~ ":" ~ canonicalJSON(value.object[name]);
        }
        return result ~ "}";
    }
    if (value.type == JSONType.array) {
        string result = "[";
        foreach (i, element; value.array) {
            if (i)
                result ~= ",";
            result ~= canonicalJSON(element);
        }
        return result ~ "]";
    }
    return value.toString;
}

private JSONValue counter(ulong value) {
    return JSONValue(value.to!string);
}

private ulong unsignedValue(JSONValue value, string path) {
    auto text = value.str;
    if (!text.length)
        throw new LuaException("invalid save counter at " ~ path);
    foreach (c; text)
        if (c < '0' || c > '9')
            throw new LuaException("invalid save counter at " ~ path);
    return text.to!ulong;
}

private bool boolean(JSONValue value) {
    if (value.type == JSONType.true_)
        return true;
    if (value.type == JSONType.false_)
        return false;
    throw new LuaException("invalid Boolean in save");
}

private string stringValue(JSONValue value) {
    auto decoded = decodeValue(value);
    if (!isString(decoded))
        throw new LuaException("invalid saved name");
    return decoded.match!((string s) => s, _ => "");
}

private string symbolValue(JSONValue value) {
    auto decoded = decodeValue(value);
    if (!isSymbol(decoded))
        throw new LuaException("invalid saved symbol");
    return decoded.match!((Symbol s) => s.name, _ => "");
}

private JSONValue strings(string[] values) {
    JSONValue[] result;
    foreach (value; values)
        result ~= encodeValue(LuaValue(value));
    return JSONValue(result);
}

private string[] readStrings(JSONValue values) {
    string[] result;
    foreach (value; values.array)
        result ~= stringValue(value);
    return result;
}

private JSONValue setKeys(bool[string] values) {
    auto keys = values.keys;
    keys.sort;
    return strings(keys);
}

private bool[string] readSet(JSONValue input) {
    bool[string] result;
    foreach (key; readStrings(input)) {
        if (key in result)
            throw new LuaException("duplicate saved history key");
        result[key] = true;
    }
    return result;
}

private JSONValue schema(Relation relation) {
    JSONValue[] keys;
    foreach (column; relation.keyColumns)
        keys ~= counter(column);
    return JSONValue([
        "name": encodeValue(LuaValue(relation.name)),
        "arity": counter(relation.arity),
        "columns": strings(relation.columns),
        "keys": JSONValue(keys),
        "protected": JSONValue(relation.protectedRelation)
    ]);
}

string schemaFingerprint(World world) {
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;

    JSONValue[] entries;
    auto names = world.relations.keys;
    names.sort;
    foreach (name; names)
        entries ~= schema(world.relations[name]);
    return canonicalJSON(JSONValue(entries)).sha256Of.toHexString.idup;
}

void declareAuthoredProgram(World world, string authoredVersion) {
    checkMutationWorld(world);
    prohibitProgramChange();
    if (!authoredVersion.length)
        throw new LuaException("authored program version must be nonempty");
    if (world.narrativeOwner !is null)
        throw new LuaException("declare authored program before creating a session");
    auto fingerprint = portableProgramFingerprint(world, true);
    if (world.narrativeProgramVersion.length && (world.narrativeProgramVersion != authoredVersion || world
            .narrativeProgramFingerprint != fingerprint))
        throw new LuaException("authored program already declared with another version/program");
    world.narrativeProgramVersion = authoredVersion;
    world.narrativeProgramFingerprint = fingerprint;
}

private string checkedProgram(World world) {
    auto fingerprint = portableProgramFingerprint(world, world.narrativeProgramVersion.length != 0);
    if (world.narrativeProgramVersion.length && fingerprint != world.narrativeProgramFingerprint)
        throw new LuaException("non-reconstructible runtime rule program changed after authored initialization");
    return fingerprint;
}

/// `label` and `meta` are informational header fields (a slot name, a host timestamp, a
/// location): they are never read back by `loadSession` and are outside every identity.
string saveSession(Session session, string label = null, LuaValue meta = LuaValue.init) {
    session.requireIdle();
    try {
        auto data = session.data;
        JSONValue[] relations;
        auto names = session.world.relations.keys;
        names.sort;
        foreach (name; names) {
            auto relation = session.world.relations[name];
            JSONValue[] tuples;
            foreach (tuple; relation.baseFacts.keys) {
                JSONValue[] values;
                foreach (i, value; tuple.values)
                    values ~= encodeValue(value, "relation." ~ name ~ "[" ~ i.to!string ~ "]");
                tuples ~= JSONValue(values);
            }
            tuples.sort!((a, b) => canonicalJSON(a) < canonicalJSON(b));
            auto entry = schema(relation);
            entry.object["facts"] = JSONValue(tuples);
            entry.object["version"] = counter(relation.version_);
            relations ~= entry;
        }
        JSONValue[] decks;
        foreach (deck; data.decks)
            decks ~= JSONValue([
            "name": encodeValue(session.state.getSymbol(deck.name)),
            "identity": counter(deck.identity),
            "drawn": setKeys(deck.drawn)
        ]);
        JSONValue[] completed;
        auto completedNames = data.completed.keys;
        completedNames.sort;
        foreach (name; completedNames)
            completed ~= JSONValue([
            "key": encodeValue(LuaValue(name)),
            "turn": counter(data.completed[name])
        ]);
        JSONValue[] periods;
        auto periodNames = data.periods.keys;
        periodNames.sort;
        foreach (name; periodNames)
            periods ~= JSONValue([
            "name": encodeValue(session.state.getSymbol(name)),
            "value": encodeValue(data.periods[name], "period." ~ name)
        ]);
        JSONValue[] events;
        foreach (event; data.events)
            events ~= JSONValue([
            "sequence": counter(event.sequence),
            "turn": counter(event.turn),
            "kind": encodeValue(session.state.getSymbol(event.kind)),
            "arguments": encodeValue(event.arguments, "event.arguments")
        ]);
        JSONValue[] scheduled;
        foreach (event; data.scheduled)
            scheduled ~= JSONValue([
            "sequence": counter(event.sequence),
            "due": counter(event.due),
            "kind": encodeValue(session.state.getSymbol(event.kind)),
            "arguments": encodeValue(event.arguments, "schedule.arguments")
        ]);
        JSONValue[] consumed;
        auto tokenIds = data.consumedTokens.keys;
        tokenIds.sort;
        foreach (identity; tokenIds)
            consumed ~= counter(identity);
        JSONValue[] inputs;
        foreach (record; data.replayInputs)
            inputs ~= encodeValue(record, "replay input");
        auto encoded = JSONValue([
            "format": JSONValue(data.scene is null ? saveFormat2 : saveFormat3),
            "runtime": JSONValue(narrativeRuntimeVersion),
            "content": JSONValue(session.registry.contentVersion),
            "content_fingerprint": JSONValue(portableRegistryFingerprint(session.registry)),
            "presentation": JSONValue(presentationRevision(session.registry)),
            "program_version": JSONValue(session.world.narrativeProgramVersion),
            "program_fingerprint": JSONValue(checkedProgram(session.world)),
            "world_identity": JSONValue(session.world.persistentIdentity.length ? session.world.persistentIdentity
                    : session.world.id.to!string),
            "schema_fingerprint": JSONValue(schemaFingerprint(session.world)),
            "world_version": counter(session.world.version_),
            "relations": JSONValue(relations),
            "turn": counter(data.turn),
            "rng": counter(data.rng),
            "seeded": JSONValue(data.seeded),
            "seed": JSONValue(data.initialSeed.to!string),
            "next_deck": counter(data.nextDeck),
            "next_token": counter(data.nextToken),
            "next_schedule": counter(data.nextSchedule),
            "decks": JSONValue(decks),
            "completed": JSONValue(completed),
            "actions": setKeys(data.actionHistory),
            "periods": JSONValue(periods),
            "events": JSONValue(events),
            "scheduled": JSONValue(scheduled),
            "consumed_tokens": JSONValue(consumed),
            "inputs": JSONValue(inputs),
            "action_limit": counter(session.actionLimit),
            "event_limit": counter(session.eventLimit)
        ]);
        if (data.scene !is null)
            encoded.object["scene"] = encodeValue(data.scene.portable(), "scene");
        // Optional fields, written only when they carry something, so older saves are unchanged.
        if (data.ending.length)
            encoded.object["ending"] = encodeValue(session.state.getSymbol(data.ending), "ending");
        // The cursor is implied (every event delivered) unless events are waiting for a presentation.
        if (data.eventCursor != data.events.length)
            encoded.object["event_cursor"] = counter(data.eventCursor);
        if (label.length)
            encoded.object["label"] = JSONValue(label);
        if (!isNil(meta))
            encoded.object["meta"] = encodeValue(meta, "save metadata");
        return canonicalJSON(encoded);
    } catch (LuaException error) {
        throw error;
    } catch (Exception error) {
        throw new LuaException("cannot save narrative session: " ~ error.msg);
    }
}

/// The header of a save, read without restoring it: what a slot list shows. Nothing is checked
/// against the running content; `loadSession` does that.
LuaValue saveInfo(string saved) {
    try {
        auto input = parseJSON(saved);
        auto format = input["format"].str;
        if (format != saveFormat1 && format != saveFormat2 && format != saveFormat3)
            throw new LuaException("incompatible save format version");
        LuaValue[string] fields = [
            "format": LuaValue(format),
            "turn": LuaValue(unsignedValue(input["turn"], "turn").to!long),
            "runtime": LuaValue(input["runtime"].str),
            "content": LuaValue(input["content"].str),
            "in_scene": LuaValue("scene" in input.object ? true : false)
        ];
        if (auto label = "label" in input.object)
            fields["label"] = LuaValue(label.str);
        if (auto meta = "meta" in input.object)
            fields["meta"] = decodeValue(*meta);
        return immutableRecord(fields);
    } catch (LuaException error) {
        throw error;
    } catch (Exception error) {
        throw new LuaException("invalid narrative save: " ~ error.msg);
    }
}

private LuaValue readArguments(JSONValue value) {
    auto decoded = decodeValue(value);
    auto sequence = decoded.match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
    if (sequence is null)
        throw new LuaException("saved event arguments must be an immutable sequence");
    return decoded;
}

/// The factory returns an authored template. Restoration stages a fresh clone so
/// validation failure cannot mutate the factory world or any existing session.
Session loadSession(LuaState state, string saved, LuaValue factory) {
    if (!isFunction(factory))
        throw new LuaException("narrative.load requires a world factory");
    if (currentTransaction() !is null || currentEffectSession() !is null || isReadOnlyEvaluation())
        throw new LuaException("cannot load session during an active operation");
    try {
        auto input = parseJSON(saved);
        auto format = input["format"].str;
        bool firstFormat = format == saveFormat1;
        if (!firstFormat && format != saveFormat2 && format != saveFormat3)
            throw new LuaException("incompatible save format version");
        if (input["runtime"].str != narrativeRuntimeVersion)
            throw new LuaException("incompatible narrative runtime version");
        state.narrativeRegistry.seal();
        // A first-format save is validated as it was written: with wording in the identity. A
        // mismatch is never silently accepted in either format.
        auto expectedContent = firstFormat ? state.narrativeRegistry.legacyContentVersion() : state
            .narrativeRegistry.contentVersion;
        if (input["content"].str != expectedContent || input["content_fingerprint"].str != portableRegistryFingerprint(
                state.narrativeRegistry, firstFormat))
            throw new LuaException("incompatible narrative content version or fingerprint");
        auto data = new SessionData();
        if ((format == saveFormat3) != (("scene" in input.object) !is null))
            throw new LuaException("invalid scene save format");
        if (auto savedScene = "scene" in input.object) {
            import varis.narrative.scenes;

            auto portable = decodeValue(*savedScene);
            string problem;
            data.scene = restoreScene(state.narrativeRegistry, portable, problem);
            if (problem.length)
                throw new LuaException("invalid saved scene: " ~ problem);
        }
        data.turn = unsignedValue(input["turn"], "turn");
        if (data.turn > long.max)
            throw new LuaException("saved turn exceeds runtime range");
        data.rng = unsignedValue(input["rng"], "rng");
        data.seeded = boolean(input["seeded"]);
        data.initialSeed = input["seed"].str.to!long;
        if (data.seeded && !data.rng)
            throw new LuaException("invalid zero RNG state");
        data.nextDeck = unsignedValue(input["next_deck"], "next_deck");
        data.nextToken = unsignedValue(input["next_token"], "next_token");
        data.nextSchedule = unsignedValue(input["next_schedule"], "next_schedule");
        if (!data.nextDeck || !data.nextToken || !data.nextSchedule)
            throw new LuaException("invalid saved identity counter");
        bool[ulong] deckIds;
        foreach (entry; input["decks"].array) {
            string name = symbolValue(entry["name"]);
            state.narrativeRegistry.deck(name);
            ulong identity = unsignedValue(entry["identity"], "deck.identity");
            if (!identity || identity >= data.nextDeck || identity in deckIds)
                throw new LuaException("invalid saved deck identity");
            deckIds[identity] = true;
            data.decks ~= DeckEntry(name, identity, readSet(entry["drawn"]));
        }
        if (!data.decks.length)
            throw new LuaException("saved deck stack is empty");
        foreach (entry; input["completed"].array) {
            string key = stringValue(entry["key"]);
            ulong turn = unsignedValue(entry["turn"], "completed.turn");
            if (turn > data.turn || key in data.completed)
                throw new LuaException("invalid saved completion history");
            data.completed[key] = turn;
        }
        data.actionHistory = readSet(input["actions"]);
        foreach (entry; input["periods"].array) {
            string name = symbolValue(entry["name"]);
            if (name in data.periods)
                throw new LuaException("duplicate saved period");
            data.periods[name] = decodeValue(entry["value"]);
        }
        ulong previousTurn;
        foreach (entry; input["events"].array) {
            ulong sequence = unsignedValue(entry["sequence"], "event.sequence"), turn = unsignedValue(entry["turn"], "event.turn");
            if (sequence != data.events.length + 1 || turn > data.turn || turn < previousTurn)
                throw new LuaException("invalid saved event history");
            previousTurn = turn;
            data.events ~= NarrativeEvent(sequence, turn, symbolValue(entry["kind"]), readArguments(entry["arguments"]));
        }
        bool[ulong] scheduleIds;
        foreach (entry; input["scheduled"].array) {
            ulong sequence = unsignedValue(entry["sequence"], "schedule.sequence"), due = unsignedValue(entry["due"], "schedule.due");
            if (!sequence || sequence >= data.nextSchedule || sequence in scheduleIds || due > long.max)
                throw new LuaException("invalid saved schedule");
            scheduleIds[sequence] = true;
            data.scheduled ~= ScheduledEvent(due, sequence, symbolValue(entry["kind"]), readArguments(
                    entry["arguments"]));
        }
        foreach (entry; input["consumed_tokens"].array) {
            ulong identity = unsignedValue(entry, "consumed_token");
            if (!identity || identity >= data.nextToken || identity in data.consumedTokens)
                throw new LuaException("invalid saved consumed token");
            data.consumedTokens[identity] = true;
        }
        foreach (entry; input["inputs"].array) {
            auto record = decodeValue(entry);
            auto payload = record.match!((LuaUserData u) => cast(ImmutableRecord) u.payload, _ => null);
            if (payload is null || "kind" !in payload.fields || "value" !in payload.fields || !isSymbol(
                    payload.fields["kind"]))
                throw new LuaException("invalid saved replay input");
            data.replayInputs ~= record;
        }
        if (auto ending = "ending" in input.object) {
            data.ending = symbolValue(*ending);
            if (!data.ending.length)
                throw new LuaException("invalid saved ending");
        }
        data.eventCursor = data.events.length;
        if (auto cursor = "event_cursor" in input.object) {
            data.eventCursor = unsignedValue(*cursor, "event_cursor");
            if (data.eventCursor > data.events.length)
                throw new LuaException("invalid saved event cursor");
        }
        ulong actions = unsignedValue(input["action_limit"], "action_limit"), events = unsignedValue(
                input["event_limit"], "event_limit");
        if (!actions || !events || actions > size_t.max || events > size_t.max)
            throw new LuaException("invalid saved execution limits");
        auto created = VM.callValue(state, factory, []);
        if (!created.length)
            throw new LuaException("world factory did not return a world");
        auto authored = unwrapWorld(created[0]);
        if (authored.transactionOwner !is null || authored.narrativeOwner !is null)
            throw new LuaException("world factory must return an idle unowned authored world");
        auto staged = authored.cloneSnapshot();
        auto session = new Session(state, staged, true);
        if (input["program_version"].str != staged.narrativeProgramVersion || input["program_fingerprint"].str != checkedProgram(
                staged))
            throw new LuaException("incompatible authored rule program version or fingerprint");
        if (input["schema_fingerprint"].str != schemaFingerprint(staged))
            throw new LuaException("incompatible relation schema fingerprint");
        bool[string] seen;
        foreach (entry; input["relations"].array) {
            string name = stringValue(entry["name"]);
            if (name in seen)
                throw new LuaException("duplicate saved relation '" ~ name ~ "'");
            seen[name] = true;
            auto relation = staged.getRelation(name);
            if (relation is null || canonicalJSON(schema(relation)) != canonicalJSON(JSONValue([
                        "name": entry["name"],
                        "arity": entry["arity"],
                        "columns": entry["columns"],
                        "keys": entry["keys"],
                        "protected": entry["protected"]
                ])))
                throw new LuaException("incompatible relation schema: " ~ name);
            relation.clearFacts();
            relation.keyIndex = null;
            foreach (encoded; entry["facts"].array) {
                LuaValue[] values;
                foreach (value; encoded.array)
                    values ~= decodeValue(value);
                auto tuple = RelTuple(values);
                if (tuple.length != relation.arity || tuple in relation.baseFacts)
                    throw new LuaException("invalid saved tuple: " ~ name);
                if (relation.validateTuple !is null)
                    relation.validateTuple(tuple);
                if (relation.keyColumns.length) {
                    auto key = relation.tupleKey(tuple);
                    if (key in relation.keyIndex)
                        throw new LuaException("conflicting saved key: " ~ name);
                    relation.keyIndex[key] = tuple;
                }
                relation.baseFacts[tuple] = true;
            }
            relation.version_ = unsignedValue(entry["version"], "relation.version");
            if (!relation.version_)
                throw new LuaException("invalid saved relation version");
        }
        if (seen.length != staged.relations.length)
            throw new LuaException("incompatible relation schema set");
        auto history = staged.getRelation("narrative_event");
        bool[string] historyValues;
        foreach (tuple; history.baseFacts.keys)
            historyValues[canonicalPersisted(immutableSequence(tuple.values))] = true;
        if (historyValues.length != data.events.length)
            throw new LuaException("saved event relation/history mismatch");
        history.clearFacts();
        foreach (event; data.events) {
            auto tuple = RelTuple([
                LuaValue(cast(long) event.sequence), LuaValue(cast(long) event.turn),
                state.getSymbol(event.kind), event.arguments
            ]);
            if (canonicalPersisted(immutableSequence(tuple.values)) !in historyValues)
                throw new LuaException("saved event relation/history mismatch");
            history.baseFacts[tuple] = true;
        }
        staged.version_ = unsignedValue(input["world_version"], "world_version");
        if (!staged.version_)
            throw new LuaException("invalid saved world version");
        staged.persistentIdentity = input["world_identity"].str;
        if (!staged.persistentIdentity.length)
            throw new LuaException("invalid saved world identity");
        session.data = data;
        session.actionLimit = cast(size_t) actions;
        session.eventLimit = cast(size_t) events;
        return session;
    } catch (LuaException error) {
        throw error;
    } catch (Exception error) {
        throw new LuaException("invalid narrative save: " ~ error.msg);
    }
}
