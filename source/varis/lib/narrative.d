/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib.narrative;

import varis.types;
import varis.table;
import varis.state;
import varis.narrative.registry;
import varis.narrative.scenes;
import varis.narrative.codec;
import varis.narrative.templates;
import varis.narrative.session;
import varis.narrative.persistence;
import varis.narrative.profile;
import varis.narrative.text : markupSpans, escapeMarkup;
import varis.narrative.observe;
import varis.narrative.diagnostics;
import varis.narrative.analysis;
import varis.vm : VM;
import varis.logic.world;
import varis.logic.model : RelTuple;
import varis.exception : LuaException;

private LuaValue[] fail(void* pointer, LuaException error) {
    return raise(cast(LuaState) pointer, error);
}

private string symbolName(LuaValue value) {
    return value.match!((Symbol symbol) => symbol.name, _ => "");
}

/// The name of the symbol argument; reports the error and returns false when it is not one.
private bool symbolArg(void* pointer, LuaValue value, out string name) {
    if (!isSymbol(value)) {
        raise(cast(LuaState) pointer, new LuaException("narrative identifier must be a symbol"));
        return false;
    }
    name = symbolName(value);
    return true;
}

void openNarrativeLib(LuaState state) {
    if (state.narrativeRegistry is null)
        state.narrativeRegistry = new ContentRegistry(state);
    auto library = new LuaTable();
    library.rawset(LuaValue("registry"), LuaValue(new LuaUserData(state.narrativeRegistry)));
    void add(string name, LuaNativeFunction.NativeDelegate function_) {
        library.rawset(LuaValue(name), LuaValue(new LuaNativeFunction(function_, "narrative." ~ name)));
    }

    void addSceneRegistration(string registrationKind) {
        add(registrationKind, (void* pointer, LuaValue[] arguments) {
            if (arguments.length != 2 || !arguments[0].isSymbol)
                return fail(pointer, new LuaException(registrationKind ~ " requires an identifier and a table"));
            auto registry = (cast(LuaState) pointer).narrativeRegistry;
            registry.requireOpen();
            auto id = nameOf(arguments[0]);
            LuaValue frozen;
            auto error = freeze(arguments[1], frozen);
            if (error.length)
                return fail(pointer, new LuaException(registrationKind ~ " '" ~ id ~ "': " ~ error));
            if (registrationKind == "character") {
                if (registry.character(id) !is null)
                    return fail(pointer, new LuaException("duplicate character '" ~ id ~ "'"));
                registry.characters ~= CharacterDefinition(id, frozen);
            } else {
                if (registry.scene(id) !is null)
                    return fail(pointer, new LuaException("duplicate scene '" ~ id ~ "'"));
                auto beats = sequence(frozen).dup;
                if (!beats.length)
                    return fail(pointer, new LuaException("scene '" ~ id ~ "' requires beats"));
                foreach (ref beat; beats) {
                    auto text = field(beat, "text");
                    if (text.isString)
                        beat = replaceField(beat, "text", LuaValue(registry.expandFragments(text.asString)));
                }
                registry.scenes ~= SceneDefinition(id, beats);
            }
            return cast(LuaValue[])[];
        });
    }

    // narrative.meta(:storylet [, :choice], record): presentation data passed through to the
    // storylet's (or choice's) `meta` field: icon, tags, shortcut, style. Frozen at registration;
    // never part of the content identity, so changing it never invalidates a save.
    add("meta", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 2 || arguments.length > 3 || !arguments[0].isSymbol || (arguments.length == 3 && !arguments[1]
            .isSymbol))
            return fail(pointer, new LuaException(
                "narrative.meta requires a storylet symbol, an optional choice symbol and a table"));
        auto registry = (cast(LuaState) pointer).narrativeRegistry;
        registry.requireOpen();
        auto key = nameOf(arguments[0]);
        if (arguments.length == 3)
            key ~= "." ~ nameOf(arguments[1]);
        if (key in registry.metadata)
            return fail(pointer, new LuaException("duplicate narrative.meta for '" ~ key ~ "'"));
        if (!isTable(arguments[$ - 1]))
            return fail(pointer, new LuaException("narrative.meta requires a table of fields"));
        LuaValue frozen;
        auto error = freeze(arguments[$ - 1], frozen);
        if (error.length)
            return fail(pointer, new LuaException("narrative.meta '" ~ key ~ "': " ~ error));
        registry.metadata[key] = frozen;
        return cast(LuaValue[])[];
    });
    // narrative.visited(:storylet) / narrative.last_chosen(:storylet): the same answers as the
    // session methods, readable from an effect (they see its tentative state).
    add("visited", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException("visited requires a storylet symbol"));
        return [LuaValue(cast(long) requireEffectSession().visitCount(nameOf(arguments[0])))];
    });
    add("last_chosen", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException("last_chosen requires a storylet symbol"));
        ulong turn;
        if (!requireEffectSession().lastChosen(nameOf(arguments[0]), turn))
            return [luaNil()];
        return [LuaValue(cast(long) turn)];
    });
    // narrative.fragment(:name, "text"): reusable template text, included with {>name}. Define a
    // fragment before the storylets and scenes that use it; it is expanded where it is used.
    add("fragment", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !arguments[0].isSymbol || !isString(arguments[1]))
            return fail(pointer, new LuaException("narrative.fragment requires a name symbol and a text"));
        auto registry = (cast(LuaState) pointer).narrativeRegistry;
        registry.requireOpen();
        auto name = nameOf(arguments[0]);
        if (name in registry.fragments)
            return fail(pointer, new LuaException("duplicate template fragment '" ~ name ~ "'"));
        registry.fragments[name] = registry.expandFragments(arguments[1].match!((string s) => s, _ => ""));
        return cast(LuaValue[])[];
    });
    // narrative.var(:name, value) (the `var name = value` statement): a story variable, one row of
    // the keyed relation var(name, value). Read it in a text as {$name}, in rules and effects as
    // var(:name, ?v), write it with `set var(:name, v)` or `adjust var(:name) by n`.
    add("var", (void* pointer, LuaValue[] arguments) {
        auto state = cast(LuaState) pointer;
        if (arguments.length != 2 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException("var requires a name and an initial value"));
        encodeValue(arguments[1], "var");
        auto world = state.globalWorld;
        auto relation = world.getRelation("var");
        if (relation is null)
            relation = world.declareNamedRelation("var", ["name", "value"], ["name"]);
        auto name = arguments[0];
        if (RelTuple([name]) in relation.keyIndex)
            return fail(pointer, new LuaException("duplicate story variable '" ~ nameOf(name) ~ "'"));
        relation.setFact(RelTuple([name, arguments[1]]));
        return cast(LuaValue[])[];
    });
    addSceneRegistration("scene");
    addSceneRegistration("character");
    add("play", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException("play requires a scene symbol"));
        requireEffectSession().playScene(nameOf(arguments[0]));
        return cast(LuaValue[])[];
    });
    // narrative.has_scene(:name): whether a scene is registered; hosts use it to refuse a battle
    // setup whose moment names a scene that does not exist.
    add("has_scene", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException("has_scene requires a scene symbol"));
        auto registry = (cast(LuaState) pointer).narrativeRegistry;
        return [LuaValue(registry.scene(nameOf(arguments[0])) !is null)];
    });
    add("analyze", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 1 || arguments.length > 2)
            return fail(pointer, new LuaException("analyze requires session and optional options table"));
        AnalysisOptions options;
        if (arguments.length == 2) {
            auto fields = diagnosticBindings(arguments[1]);
            // A `return` inside a foreach over an associative array is awkward for the compiler: record the problem.
            string problem;
            foreach (name, value; fields) {
                if (problem !is null)
                    break;
                if (!isInteger(value)) {
                    problem = "analysis option must be an integer: " ~ name;
                    continue;
                }
                long count = value.match!((long n) => n, _ => -1L);
                if (count < 0) {
                    problem = "analysis option must be nonnegative: " ~ name;
                    continue;
                }
                switch (name) {
                case "depth":
                    options.depth = cast(size_t) count;
                    break;
                case "max_nodes":
                    options.maxNodes = cast(size_t) count;
                    break;
                case "max_steps":
                    options.maxSteps = cast(size_t) count;
                    break;
                case "max_objects":
                    options.maxObjects = cast(size_t) count;
                    break;
                default:
                    problem = "unknown analysis option '" ~ name ~ "'";
                }
            }
            if (problem !is null)
                return fail(pointer, new LuaException(problem));
        }
        return [analyzeSession(unwrapSession(arguments[0]), options)];
    });
    add("explain", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 2 || arguments.length > 3)
            return fail(pointer, new LuaException("explain requires session, content symbol and optional bindings"));
        string content;
        if (!symbolArg(pointer, arguments[1], content))
            return null;
        return [
            explainContent(unwrapSession(arguments[0]), content, diagnosticBindings(
                arguments.length > 2 ? arguments[2] : luaNil()))
        ];
    });
    add("observe", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 3)
            return fail(pointer, new LuaException("observe requires world, relation name and callbacks"));
        string name;
        if (isSymbol(arguments[1]))
            name = symbolName(arguments[1]);
        else if (isString(arguments[1]))
            name = arguments[1].match!((string s) => s, _ => "");
        else
            return fail(pointer, new LuaException("observed relation name must be a string or symbol"));
        return [
            observeRelation(cast(LuaState) pointer, unwrapWorld(arguments[0]), name, arguments[2])
        ];
    });
    add("enqueue", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            return fail(pointer, new LuaException("enqueue requires a callback"));
        enqueueObserverCommand(arguments[0]);
        return cast(LuaValue[])[];
    });
    add("flush", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 1 || arguments.length > 2)
            return fail(pointer, new LuaException("flush requires a world and optional positive limit"));
        long limit = 1000;
        if (arguments.length == 2) {
            if (!isInteger(arguments[1]))
                return fail(pointer, new LuaException("observer queue limit must be an integer"));
            limit = arguments[1].match!((long n) => n, _ => 0L);
        }
        if (limit <= 0)
            return fail(pointer, new LuaException("observer queue limit must be positive"));
        flushObserverCommands(unwrapWorld(arguments[0]), cast(size_t) limit);
        return cast(LuaValue[])[];
    });
    add("program", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[1]))
            return fail(pointer, new LuaException("narrative.program requires a world and authored version string"));
        declareAuthoredProgram(unwrapWorld(arguments[0]), arguments[1].match!((string s) => s, _ => ""));
        return cast(LuaValue[])[];
    });
    // Cross-save data owned by the host (see varis.narrative.profile).
    auto profile = new Profile;
    bool profileKey(LuaValue value, out string result) {
        if (!isString(value) || !value.match!((string s) => s.length != 0, _ => false)) {
            raise(state, new LuaException("profile key must be a non-empty string"));
            return false;
        }
        result = value.match!((string s) => s, _ => "");
        return true;
    }

    bool requireProfileRead() {
        import varis.fiber : isReadOnlyEvaluation;

        if (currentTransaction() !is null || isReadOnlyEvaluation()) {
            raise(state, new LuaException("the profile is not readable during effects, rules or templates"));
            return false;
        }
        return true;
    }

    add("profile_set", (void* pointer, LuaValue[] arguments) {
        import varis.fiber : isReadOnlyEvaluation;

        if (arguments.length != 2)
            return fail(pointer, new LuaException("profile_set requires a key and a portable value (nil removes it)"));
        string key;
        if (!profileKey(arguments[0], key))
            return null;
        if (isReadOnlyEvaluation())
            return fail(pointer, new LuaException("profile writes are prohibited during read-only evaluation"));
        auto value = arguments[1];
        if (!isNil(value))
            encodeValue(value, "profile." ~ key);
        void apply() {
            if (isNil(value))
                profile.values.remove(key);
            else
                profile.values[key] = value;
        }

        if (auto transaction = currentTransaction())
            transaction.afterCommit ~= &apply;
        else
            apply();
        return cast(LuaValue[])[];
    });
    add("profile_get", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            return fail(pointer, new LuaException("profile_get requires a key"));
        string key;
        if (!requireProfileRead() || !profileKey(arguments[0], key))
            return null;
        auto found = key in profile.values;
        return [found is null ? luaNil() : *found];
    });
    add("profile_keys", (void* pointer, LuaValue[] arguments) {
        if (!requireProfileRead())
            return null;
        LuaValue[] names;
        foreach (name; profile.keys)
            names ~= LuaValue(name);
        return [immutableSequence(names)];
    });
    add("profile_save", (void* pointer, LuaValue[] arguments) {
        if (!requireProfileRead())
            return null;
        return [LuaValue(profile.save())];
    });
    add("profile_load", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("profile_load requires saved profile text"));
        if (!requireProfileRead())
            return null;
        profile.load(arguments[0].match!((string s) => s, _ => ""));
        return cast(LuaValue[])[];
    });
    // Save slots: one file per slot, `directory/name.json`, holding the save text.
    bool slotPath(LuaValue directory, LuaValue name, out string result) {
        import std.path : buildPath;

        if (!isString(directory) || !isString(name)) {
            raise(state, new LuaException("a slot needs a directory and a name (strings)"));
            return false;
        }
        auto slot = name.match!((string s) => s, _ => "");
        bool valid = slot.length != 0;
        foreach (c; slot)
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
                valid = false;
        if (!valid) {
            raise(state, new LuaException("slot name must be letters, digits, '_' or '-'"));
            return false;
        }
        result = buildPath(directory.match!((string s) => s, _ => ""), slot ~ ".json");
        return true;
    }

    add("save_slot", (void* pointer, LuaValue[] arguments) {
        import std.file : mkdirRecurse, write;
        import std.path : dirName;

        if (arguments.length < 3 || arguments.length > 4)
            return fail(pointer, new LuaException(
                "save_slot requires a session, a directory, a name and optional {label=, meta=}"));
        string path;
        if (!slotPath(arguments[1], arguments[2], path))
            return null;
        auto text = saveWithOptions(unwrapSession(arguments[0]), arguments.length == 4 ? arguments[3] : luaNil());
        mkdirRecurse(dirName(path));
        write(path, text);
        return cast(LuaValue[])[];
    });
    add("load_slot", (void* pointer, LuaValue[] arguments) {
        import std.file : exists, readText;

        if (arguments.length != 3)
            return fail(pointer, new LuaException("load_slot requires a directory, a name and a world factory"));
        string path;
        if (!slotPath(arguments[0], arguments[1], path))
            return null;
        if (!exists(path))
            return fail(pointer, new LuaException("no such save slot"));
        return [wrapSession(loadSession(cast(LuaState) pointer, readText(path), arguments[2]))];
    });
    add("list_slots", (void* pointer, LuaValue[] arguments) {
        import std.file : dirEntries, exists, readText, SpanMode;
        import std.path : baseName, stripExtension;
        import std.algorithm : sort;

        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("list_slots requires a directory"));
        auto directory = arguments[0].match!((string s) => s, _ => "");
        LuaValue[] rows;
        if (exists(directory)) {
            string[] files;
            foreach (entry; dirEntries(directory, "*.json", SpanMode.shallow))
                files ~= entry.name;
            files.sort;
            foreach (file; files) {
                try {
                    auto info = saveInfo(readText(file));
                    auto fields = (cast(ImmutableRecord) info.asUserData.payload).fields.dup;
                    fields["name"] = LuaValue(baseName(stripExtension(file)));
                    rows ~= immutableRecord(fields);
                } catch (Exception) {
                    // Not a save (a profile, say): not a slot.
                }
            }
        }
        return [immutableSequence(rows)];
    });
    add("delete_slot", (void* pointer, LuaValue[] arguments) {
        import std.file : exists, remove;

        if (arguments.length != 2)
            return fail(pointer, new LuaException("delete_slot requires a directory and a name"));
        string path;
        if (!slotPath(arguments[0], arguments[1], path))
            return null;
        if (exists(path))
            remove(path);
        return cast(LuaValue[])[];
    });
    add("save_info", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("save_info requires saved session text"));
        return [saveInfo(arguments[0].match!((string s) => s, _ => ""))];
    });
    add("load", (void* pointer, LuaValue[] arguments) {
        if ((arguments.length != 2 && arguments.length != 3) || !isString(arguments[0]) || (arguments.length == 3 && !isFunction(
            arguments[2])))
            return fail(pointer, new LuaException(
                "narrative.load requires saved text, a world factory and optional migration function"));
        auto state = cast(LuaState) pointer;
        auto saved = arguments[0].match!((string s) => s, _ => "");
        try {
            return [wrapSession(loadSession(state, saved, arguments[1]))];
        } catch (LuaException error) {
            import std.string : indexOf;

            if (arguments.length != 3 || error.msg.indexOf("incompatible") < 0)
                return fail(pointer, error);
            auto target = immutableRecord([
                "runtime": LuaValue(narrativeRuntimeVersion),
                "content": LuaValue(state.narrativeRegistry.contentVersion)
            ]);
            auto migrated = VM.callValue(state, arguments[2], [arguments[0], target]);
            if (migrated.length != 1 || !isString(migrated[0]))
                return fail(pointer, new LuaException("migration must return exactly one saved-text string"));
            return [
                wrapSession(loadSession(state, migrated[0].match!((string s) => s, _ => ""), arguments[1]))
            ];
        }
    });
    add("new", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            return fail(pointer, new LuaException("narrative.new requires a world"));
        return [wrapSession(new Session(cast(LuaState) pointer, unwrapWorld(arguments[0])))];
    });
    add("push_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            return fail(pointer, new LuaException("push_deck requires a deck symbol"));
        string deck;
        if (!symbolArg(pointer, arguments[0], deck))
            return null;
        requireEffectSession().pushDeck(deck);
        return cast(LuaValue[])[];
    });
    // narrative.helper(name, value): expose a function (or table of functions) from an engine
    // script to content-tier files, which otherwise see only the content environment. The helper
    // is trusted code: it is responsible for respecting the save and replay rules.
    add("helper", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[0]) || !(isFunction(arguments[1]) || isTable(arguments[1])))
            return fail(pointer, new LuaException("narrative.helper requires a name and a function or table"));
        auto name = arguments[0].match!((string s) => s, _ => "");
        if (!name.length)
            return fail(pointer, new LuaException("narrative.helper requires a name"));
        (cast(LuaState) pointer).narrativeRegistry.helpers[name] = arguments[1];
        return cast(LuaValue[])[];
    });
    // narrative.return_deck(): go back to the deck that led here (pop; an error at the root).
    add("return_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length)
            return fail(pointer, new LuaException("return_deck takes no arguments"));
        requireEffectSession().popDeck();
        return cast(LuaValue[])[];
    });
    // narrative.set_period(:period, value): the executing session's period, in an effect or
    // handler. Transaction-aware like every other effect write.
    add("set_period", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException(
                "narrative.set_period requires a period symbol and a serializable value"));
        requireEffectSession().setPeriod(nameOf(arguments[0]), arguments[1]);
        return cast(LuaValue[])[];
    });
    // narrative.finish(:ending): record the ending of the session transactionally.
    add("finish", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !arguments[0].isSymbol)
            return fail(pointer, new LuaException("narrative.finish requires an ending symbol"));
        requireEffectSession().finish(nameOf(arguments[0]));
        return cast(LuaValue[])[];
    });
    add("replace_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            return fail(pointer, new LuaException("replace_deck requires a deck symbol"));
        string deck;
        if (!symbolArg(pointer, arguments[0], deck))
            return null;
        requireEffectSession().replaceDeck(deck);
        return cast(LuaValue[])[];
    });
    add("pop_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length)
            return fail(pointer, new LuaException("pop_deck takes no arguments"));
        requireEffectSession().popDeck();
        return cast(LuaValue[])[];
    });
    add("reset_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length)
            return fail(pointer, new LuaException("reset_deck takes no arguments"));
        requireEffectSession().resetDeck();
        return cast(LuaValue[])[];
    });
    add("emit", (void* pointer, LuaValue[] arguments) {
        if (!arguments.length)
            return fail(pointer, new LuaException("emit requires an event symbol"));
        string event;
        if (!symbolArg(pointer, arguments[0], event))
            return null;
        requireEffectSession().emit(event, arguments[1 .. $]);
        return cast(LuaValue[])[];
    });
    add("schedule", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 3 || !isInteger(arguments[2]))
            return fail(pointer, new LuaException("schedule requires event, immutable arguments and integer delay"));
        string event;
        if (!symbolArg(pointer, arguments[0], event))
            return null;
        requireEffectSession().schedule(event, arguments[1], arguments[2].match!((long n) => n, _ => 0L));
        return cast(LuaValue[])[];
    });
    add("defer", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isFunction(arguments[0]))
            return fail(pointer, new LuaException("defer requires a function"));
        auto session = requireEffectSession();
        auto callback = arguments[0];
        auto sessionWorld = session.world;
        currentTransaction().afterCommit ~= {
            callInSessionWorld(session.state, sessionWorld, callback, []);
        };
        return cast(LuaValue[])[];
    });
    add("seal", (void* pointer, LuaValue[] arguments) {
        auto registry = (cast(LuaState) pointer).narrativeRegistry;
        string authoredVersion;
        if (arguments.length) {
            if (!isString(arguments[0]))
                return fail(pointer, new LuaException("narrative content version must be a string"));
            authoredVersion = arguments[0].match!((string value) => value, _ => "");
        }
        bool wasSealed = registry.sealed;
        registry.seal(authoredVersion);
        if (!wasSealed) {
            import varis.narrative.fingerprint : warmSaveIdentity;

            warmSaveIdentity(registry);
        }
        return [LuaValue(registry.contentVersion)];
    });
    add("name", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[1]))
            return fail(pointer, new LuaException("narrative.name requires a symbol and a string"));
        string identifier;
        if (!symbolArg(pointer, arguments[0], identifier))
            return null;
        (cast(LuaState) pointer).narrativeRegistry.registerName(identifier, arguments[1].match!(
            (string value) => value, _ => ""));
        return cast(LuaValue[])[];
    });
    add("formatter", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 1 || arguments.length > 2)
            return fail(pointer, new LuaException("narrative.formatter requires a function, or a key and a function"));
        auto registry = (cast(LuaState) pointer).narrativeRegistry;
        if (arguments.length == 1) {
            registry.registerFormatter("default", arguments[0]);
        } else {
            string key;
            if (isSymbol(arguments[0]))
                key = symbolName(arguments[0]);
            else if (isString(arguments[0]))
                key = arguments[0].match!((string s) => s, _ => "");
            else
                return fail(pointer, new LuaException("narrative formatter key must be a symbol or string"));
            registry.registerFormatter(key, arguments[1]);
        }
        return cast(LuaValue[])[];
    });
    // narrative.translate(locale, {key = text, ...}): registers a language pack. All of it or none:
    // a message that does not parse rejects the pack, and the error lists each key.
    add("translate", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[0]) || !isTable(arguments[1]))
            return fail(pointer, new LuaException(
                "narrative.translate requires a language tag and a table of key = text"));
        string[string] messages;
        auto table = arguments[1].asTable;
        LuaValue previous, key, value;
        while (table.next(previous, key, value)) {
            previous = key;
            if (!isString(key) || !isString(value))
                return fail(pointer, new LuaException("narrative.translate: keys and texts must be strings"));
            messages[key.match!((string s) => s, _ => "")] = value.match!((string s) => s, _ => "");
        }
        auto problems = (cast(LuaState) pointer).narrativeRegistry.registerTranslations(
            arguments[0].match!((string s) => s, _ => ""), messages);
        if (problems.length) {
            string text = "language pack rejected:";
            foreach (problem; problems)
                text ~= "\n  " ~ problem;
            return fail(pointer, new LuaException(text));
        }
        return cast(LuaValue[])[];
    });
    // narrative.load_pack(directory): loads a language pack built by `varis l10n build` (a directory
    // holding pack.json) and returns its language tag. The pack is accepted or rejected as a whole;
    // the error names the language and each key that failed.
    add("load_pack", (void* pointer, LuaValue[] arguments) {
        import std.file : readText, isDir;
        import std.json : parseJSON, JSONType, JSONException;

        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.load_pack requires a directory"));
        string directory = arguments[0].match!((string s) => s, _ => "");
        string path = directory;
        try {
            if (isDir(directory))
                path = directory ~ "/pack.json";
        } catch (Exception) {
        }
        string text;
        try {
            text = readText(path);
        } catch (Exception) {
            return fail(pointer, new LuaException("language pack rejected: cannot read " ~ path));
        }
        string locale;
        string[string] messages;
        try {
            auto document = parseJSON(text);
            if (document.type != JSONType.object || "locale" !in document || document["locale"].type != JSONType
                .string
                || "messages" !in document || document["messages"].type != JSONType.object)
                return fail(pointer, new LuaException("language pack rejected: " ~ path ~ " is not a language pack"));
            if ("format" in document && document["format"].type == JSONType.integer && document["format"].integer != 1)
                return fail(pointer, new LuaException(
                    "language pack rejected: " ~ path ~ " has an unknown format version"));
            locale = document["locale"].str;
            string badKey;
            foreach (key, value; document["messages"].object) {
                if (value.type != JSONType.string) {
                    if (badKey is null)
                        badKey = key;
                    continue;
                }
                messages[key] = value.str;
            }
            if (badKey !is null)
                return fail(pointer, new LuaException(
                    "language pack rejected: " ~ locale ~ " " ~ badKey ~ ": the text is not a string"));
        } catch (JSONException) {
            return fail(pointer, new LuaException("language pack rejected: " ~ path ~ " is not valid JSON"));
        }
        auto problems = (cast(LuaState) pointer).narrativeRegistry.registerTranslations(locale, messages);
        if (problems.length) {
            string message = "language pack rejected:";
            foreach (problem; problems)
                message ~= "\n  " ~ problem;
            return fail(pointer, new LuaException(message));
        }
        return [LuaValue(locale)];
    });
    // narrative.source_language(tag): the language the authored text is written in; its plural
    // rules apply to `{#plural}` in source templates. Default "en".
    add("source_language", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.source_language requires a language tag"));
        (cast(LuaState) pointer).narrativeRegistry.sourceLanguage = arguments[0].match!((string s) => s, _ => "en");
        return cast(LuaValue[])[];
    });
    // Text rules a presentation layer needs and the engine can state (localization plan §4, §5).
    // narrative.particle(word, "은/는") -> the particle form; narrative.graphemes(text) -> count;
    // narrative.truncate(text, n) -> first n graphemes; narrative.line_breaks(text) -> sequence of
    // 1-based byte positions where a line may break; narrative.ruby(text) -> sequence of
    // {text=, reading=} spans (reading is nil for plain text).
    add("particle", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : koreanParticle;

        if (arguments.length != 2 || !isString(arguments[0]) || !isString(arguments[1]))
            return fail(pointer, new LuaException(
                "narrative.particle requires a word and a pair of forms such as \"은/는\""));
        return [
            LuaValue(koreanParticle(arguments[0].match!((string s) => s, _ => ""), arguments[1].match!((string s) => s,
                _ => "")))
        ];
    });
    add("graphemes", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : graphemeBoundaries;

        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.graphemes requires a string"));
        return [
            LuaValue(cast(long) graphemeBoundaries(arguments[0].match!((string s) => s, _ => "")).length - 1)
        ];
    });
    add("truncate", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : graphemeBoundaries;

        if (arguments.length != 2 || !isString(arguments[0]) || !isInteger(arguments[1]))
            return fail(pointer, new LuaException("narrative.truncate requires a string and a count"));
        auto text = arguments[0].match!((string s) => s, _ => "");
        long count = arguments[1].match!((long n) => n, _ => 0L);
        auto bounds = graphemeBoundaries(text);
        if (count < 0)
            count = 0;
        size_t last = cast(size_t) count < bounds.length ? bounds[cast(size_t) count] : text.length;
        return [LuaValue(text[0 .. last])];
    });
    add("line_breaks", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : lineBreakOpportunities;

        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.line_breaks requires a string"));
        LuaValue[] positions;
        foreach (offset; lineBreakOpportunities(arguments[0].match!((string s) => s, _ => "")))
            positions ~= LuaValue(cast(long) offset + 1);
        return [immutableSequence(positions)];
    });
    add("ruby", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : rubySpans;

        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.ruby requires a string"));
        LuaValue[] spans;
        foreach (span; rubySpans(arguments[0].match!((string s) => s, _ => ""))) {
            LuaValue[string] record = ["text": LuaValue(span.text)];
            if (span.reading.length)
                record["reading"] = LuaValue(span.reading);
            spans ~= immutableRecord(record);
        }
        return [immutableSequence(spans)];
    });
    // narrative.spans(text): the portable markup (**strong**, *emphasis*, [text](id) links, line
    // breaks) as an immutable sequence of span records; hosts never interpret markup themselves.
    add("spans", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.spans requires a string"));
        LuaValue[] spans;
        foreach (span; markupSpans(arguments[0].match!((string s) => s, _ => ""))) {
            LuaValue[string] record;
            if (span.lineBreak)
                record["break"] = LuaValue(true);
            else
                record["text"] = LuaValue(span.text);
            if (span.strong)
                record["strong"] = LuaValue(true);
            if (span.emphasis)
                record["emphasis"] = LuaValue(true);
            if (span.link.length)
                record["link"] = LuaValue(span.link);
            spans ~= immutableRecord(record);
        }
        return [immutableSequence(spans)];
    });
    add("escape_markup", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.escape_markup requires a string"));
        return [LuaValue(escapeMarkup(arguments[0].match!((string s) => s, _ => "")))];
    });
    add("languages", (void* pointer, LuaValue[] arguments) {
        LuaValue[] tags;
        foreach (tag; (cast(LuaState) pointer).narrativeRegistry.languages())
            tags ~= LuaValue(tag);
        return [immutableSequence(tags)];
    });
    add("display", (void* pointer, LuaValue[] arguments) {
        return [
            LuaValue((cast(LuaState) pointer).narrativeRegistry.display(arguments.length ? arguments[0] : luaNil()))
        ];
    });
    add("on", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2)
            return fail(pointer, new LuaException("narrative.on requires a symbol and a handler"));
        string event;
        if (!symbolArg(pointer, arguments[0], event))
            return null;
        (cast(LuaState) pointer).narrativeRegistry.registerHandler(event, arguments[1]);
        return cast(LuaValue[])[];
    });
    add("sequence", (void* pointer, LuaValue[] arguments) {
        foreach (value; arguments)
            encodeValue(value);
        return [immutableSequence(arguments)];
    });
    add("template", (void* pointer, LuaValue[] arguments) {
        auto state = cast(LuaState) pointer;
        if (arguments.length < 2 || !isString(arguments[0]))
            return fail(pointer, new LuaException("narrative.template requires text and bindings"));
        auto bindings = diagnosticBindings(arguments[1]);
        if (bindings is null && !isTable(arguments[1]) && arguments[1].typeOf() != LuaType.UserData)
            return fail(pointer, new LuaException("template bindings must be a table or record"));
        World world = (arguments.length > 2 && !isNil(arguments[2])) ? unwrapWorld(arguments[2]) : state.globalWorld;
        size_t[] selections;
        if (arguments.length > 3 && !isNil(arguments[3])) {
            if (isInteger(arguments[3])) {
                selections ~= cast(size_t) arguments[3].match!((long n) => n, _ => 0L);
            } else if (auto selTable = arguments[3].match!((LuaTable t) => t, _ => null)) {
                for (long i = 1; i <= selTable.rawLen(); ++i) {
                    auto val = selTable.rawget(LuaValue(i));
                    if (isInteger(val))
                        selections ~= cast(size_t) val.match!((long n) => n, _ => 0L);
                }
            }
        }
        auto snapshot = world.cloneSnapshot();
        auto template_ = new NarrativeTemplate(arguments[0].match!((string text) => text, _ => ""), bindings.keys);
        return [
            LuaValue(template_.render(state, snapshot, bindings, &state.narrativeRegistry.display, selections, null,
                state.narrativeRegistry.sourceLanguage))
        ];
    });
    state.setGlobal("narrative", LuaValue(library));
}
