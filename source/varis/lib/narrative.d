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
import varis.narrative.observe;
import varis.narrative.diagnostics;
import varis.narrative.analysis;
import varis.vm : VM;
import varis.logic.world;
import varis.exception : LuaException;

private string symbolName(LuaValue value) {
    if (!isSymbol(value))
        throw new LuaException("narrative identifier must be a symbol");
    return value.match!((Symbol symbol) => symbol.name, _ => "");
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
                throw new LuaException(registrationKind ~ " requires an identifier and a table");
            auto registry = (cast(LuaState) pointer).narrativeRegistry;
            registry.requireOpen();
            auto id = nameOf(arguments[0]);
            LuaValue frozen;
            auto error = freeze(arguments[1], frozen);
            if (error.length)
                throw new LuaException(registrationKind ~ " '" ~ id ~ "': " ~ error);
            if (registrationKind == "character") {
                if (registry.character(id) !is null)
                    throw new LuaException("duplicate character '" ~ id ~ "'");
                registry.characters ~= CharacterDefinition(id, frozen);
            } else {
                if (registry.scene(id) !is null)
                    throw new LuaException("duplicate scene '" ~ id ~ "'");
                auto beats = sequence(frozen);
                if (!beats.length)
                    throw new LuaException("scene '" ~ id ~ "' requires beats");
                registry.scenes ~= SceneDefinition(id, beats);
            }
            return cast(LuaValue[])[];
        });
    }

    addSceneRegistration("scene");
    addSceneRegistration("character");
    add("play", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !arguments[0].isSymbol)
            throw new LuaException("play requires a scene symbol");
        requireEffectSession().playScene(nameOf(arguments[0]));
        return cast(LuaValue[])[];
    });
    add("analyze", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 1 || arguments.length > 2)
            throw new LuaException("analyze requires session and optional options table");
        AnalysisOptions options;
        if (arguments.length == 2) {
            auto fields = diagnosticBindings(arguments[1]);
            foreach (name, value; fields) {
                if (!isInteger(value))
                    throw new LuaException("analysis option must be an integer: " ~ name);
                long count = value.match!((long n) => n, _ => -1L);
                if (count < 0)
                    throw new LuaException("analysis option must be nonnegative: " ~ name);
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
                    throw new LuaException("unknown analysis option '" ~ name ~ "'");
                }
            }
        }
        return [analyzeSession(unwrapSession(arguments[0]), options)];
    });
    add("explain", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 2 || arguments.length > 3)
            throw new LuaException("explain requires session, content symbol and optional bindings");
        return [
            explainContent(unwrapSession(arguments[0]), symbolName(arguments[1]), diagnosticBindings(
                arguments.length > 2 ? arguments[2] : luaNil()))
        ];
    });
    add("observe", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 3)
            throw new LuaException("observe requires world, relation name and callbacks");
        string name;
        if (isSymbol(arguments[1]))
            name = symbolName(arguments[1]);
        else if (isString(arguments[1]))
            name = arguments[1].match!((string s) => s, _ => "");
        else
            throw new LuaException("observed relation name must be a string or symbol");
        return [
            observeRelation(cast(LuaState) pointer, unwrapWorld(arguments[0]), name, arguments[2])
        ];
    });
    add("enqueue", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            throw new LuaException("enqueue requires a callback");
        enqueueObserverCommand(arguments[0]);
        return cast(LuaValue[])[];
    });
    add("flush", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 1 || arguments.length > 2)
            throw new LuaException("flush requires a world and optional positive limit");
        long limit = 1000;
        if (arguments.length == 2) {
            if (!isInteger(arguments[1]))
                throw new LuaException("observer queue limit must be an integer");
            limit = arguments[1].match!((long n) => n, _ => 0L);
        }
        if (limit <= 0)
            throw new LuaException("observer queue limit must be positive");
        flushObserverCommands(unwrapWorld(arguments[0]), cast(size_t) limit);
        return cast(LuaValue[])[];
    });
    add("program", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[1]))
            throw new LuaException("narrative.program requires a world and authored version string");
        declareAuthoredProgram(unwrapWorld(arguments[0]), arguments[1].match!((string s) => s, _ => ""));
        return cast(LuaValue[])[];
    });
    add("load", (void* pointer, LuaValue[] arguments) {
        if ((arguments.length != 2 && arguments.length != 3) || !isString(arguments[0]) || (arguments.length == 3 && !isFunction(
            arguments[2])))
            throw new LuaException(
                "narrative.load requires saved text, a world factory and optional migration function");
        auto state = cast(LuaState) pointer;
        auto saved = arguments[0].match!((string s) => s, _ => "");
        try {
            return [wrapSession(loadSession(state, saved, arguments[1]))];
        } catch (LuaException error) {
            import std.string : indexOf;

            if (arguments.length != 3 || error.msg.indexOf("incompatible") < 0)
                throw error;
            auto target = immutableRecord([
                "runtime": LuaValue(narrativeRuntimeVersion),
                "content": LuaValue(state.narrativeRegistry.contentVersion)
            ]);
            auto migrated = VM.callValue(state, arguments[2], [arguments[0], target]);
            if (migrated.length != 1 || !isString(migrated[0]))
                throw new LuaException("migration must return exactly one saved-text string");
            return [
                wrapSession(loadSession(state, migrated[0].match!((string s) => s, _ => ""), arguments[1]))
            ];
        }
    });
    add("new", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            throw new LuaException("narrative.new requires a world");
        return [wrapSession(new Session(cast(LuaState) pointer, unwrapWorld(arguments[0])))];
    });
    add("push_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            throw new LuaException("push_deck requires a deck symbol");
        requireEffectSession().pushDeck(symbolName(arguments[0]));
        return cast(LuaValue[])[];
    });
    add("replace_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1)
            throw new LuaException("replace_deck requires a deck symbol");
        requireEffectSession().replaceDeck(symbolName(arguments[0]));
        return cast(LuaValue[])[];
    });
    add("pop_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length)
            throw new LuaException("pop_deck takes no arguments");
        requireEffectSession().popDeck();
        return cast(LuaValue[])[];
    });
    add("reset_deck", (void* pointer, LuaValue[] arguments) {
        if (arguments.length)
            throw new LuaException("reset_deck takes no arguments");
        requireEffectSession().resetDeck();
        return cast(LuaValue[])[];
    });
    add("emit", (void* pointer, LuaValue[] arguments) {
        if (!arguments.length)
            throw new LuaException("emit requires an event symbol");
        requireEffectSession().emit(symbolName(arguments[0]), arguments[1 .. $]);
        return cast(LuaValue[])[];
    });
    add("schedule", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 3 || !isInteger(arguments[2]))
            throw new LuaException("schedule requires event, immutable arguments and integer delay");
        requireEffectSession().schedule(symbolName(arguments[0]), arguments[1], arguments[2].match!((long n) => n, _ => 0L));
        return cast(LuaValue[])[];
    });
    add("defer", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isFunction(arguments[0]))
            throw new LuaException("defer requires a function");
        auto session = requireEffectSession();
        auto callback = arguments[0];
        currentTransaction().afterCommit ~= { VM.callValue(session.state, callback, []); };
        return cast(LuaValue[])[];
    });
    add("seal", (void* pointer, LuaValue[] arguments) {
        auto registry = (cast(LuaState) pointer).narrativeRegistry;
        string authoredVersion;
        if (arguments.length) {
            if (!isString(arguments[0]))
                throw new LuaException("narrative content version must be a string");
            authoredVersion = arguments[0].match!((string value) => value, _ => "");
        }
        registry.seal(authoredVersion);
        return [LuaValue(registry.contentVersion)];
    });
    add("name", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[1]))
            throw new LuaException("narrative.name requires a symbol and a string");
        (cast(LuaState) pointer).narrativeRegistry.registerName(symbolName(arguments[0]), arguments[1].match!(
            (string value) => value, _ => ""));
        return cast(LuaValue[])[];
    });
    add("formatter", (void* pointer, LuaValue[] arguments) {
        if (arguments.length < 1 || arguments.length > 2)
            throw new LuaException("narrative.formatter requires a function, or a key and a function");
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
                throw new LuaException("narrative formatter key must be a symbol or string");
            registry.registerFormatter(key, arguments[1]);
        }
        return cast(LuaValue[])[];
    });
    // narrative.translate(locale, {key = text, ...}): registers a language pack. All of it or none:
    // a message that does not parse rejects the pack, and the error lists each key.
    add("translate", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 2 || !isString(arguments[0]) || !isTable(arguments[1]))
            throw new LuaException("narrative.translate requires a language tag and a table of key = text");
        string[string] messages;
        auto table = arguments[1].asTable;
        LuaValue previous, key, value;
        while (table.next(previous, key, value)) {
            previous = key;
            if (!isString(key) || !isString(value))
                throw new LuaException("narrative.translate: keys and texts must be strings");
            messages[key.match!((string s) => s, _ => "")] = value.match!((string s) => s, _ => "");
        }
        auto problems = (cast(LuaState) pointer).narrativeRegistry.registerTranslations(
            arguments[0].match!((string s) => s, _ => ""), messages);
        if (problems.length) {
            string text = "language pack rejected:";
            foreach (problem; problems)
                text ~= "\n  " ~ problem;
            throw new LuaException(text);
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
            throw new LuaException("narrative.load_pack requires a directory");
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
            throw new LuaException("language pack rejected: cannot read " ~ path);
        }
        string locale;
        string[string] messages;
        try {
            auto document = parseJSON(text);
            if (document.type != JSONType.object || "locale" !in document || document["locale"].type != JSONType
                .string
                || "messages" !in document || document["messages"].type != JSONType.object)
                throw new LuaException("language pack rejected: " ~ path ~ " is not a language pack");
            if ("format" in document && document["format"].type == JSONType.integer && document["format"].integer != 1)
                throw new LuaException("language pack rejected: " ~ path ~ " has an unknown format version");
            locale = document["locale"].str;
            foreach (key, value; document["messages"].object) {
                if (value.type != JSONType.string)
                    throw new LuaException("language pack rejected: " ~ locale ~ " " ~ key ~ ": the text is not a string");
                messages[key] = value.str;
            }
        } catch (JSONException) {
            throw new LuaException("language pack rejected: " ~ path ~ " is not valid JSON");
        }
        auto problems = (cast(LuaState) pointer).narrativeRegistry.registerTranslations(locale, messages);
        if (problems.length) {
            string message = "language pack rejected:";
            foreach (problem; problems)
                message ~= "\n  " ~ problem;
            throw new LuaException(message);
        }
        return [LuaValue(locale)];
    });
    // narrative.source_language(tag): the language the authored text is written in; its plural
    // rules apply to `{#plural}` in source templates. Default "en".
    add("source_language", (void* pointer, LuaValue[] arguments) {
        if (arguments.length != 1 || !isString(arguments[0]))
            throw new LuaException("narrative.source_language requires a language tag");
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
            throw new LuaException("narrative.particle requires a word and a pair of forms such as \"은/는\"");
        return [
            LuaValue(koreanParticle(arguments[0].match!((string s) => s, _ => ""), arguments[1].match!((string s) => s,
                _ => "")))
        ];
    });
    add("graphemes", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : graphemeBoundaries;

        if (arguments.length != 1 || !isString(arguments[0]))
            throw new LuaException("narrative.graphemes requires a string");
        return [
            LuaValue(cast(long) graphemeBoundaries(arguments[0].match!((string s) => s, _ => "")).length - 1)
        ];
    });
    add("truncate", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : graphemeBoundaries;

        if (arguments.length != 2 || !isString(arguments[0]) || !isInteger(arguments[1]))
            throw new LuaException("narrative.truncate requires a string and a count");
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
            throw new LuaException("narrative.line_breaks requires a string");
        LuaValue[] positions;
        foreach (offset; lineBreakOpportunities(arguments[0].match!((string s) => s, _ => "")))
            positions ~= LuaValue(cast(long) offset + 1);
        return [immutableSequence(positions)];
    });
    add("ruby", (void* pointer, LuaValue[] arguments) {
        import varis.narrative.text : rubySpans;

        if (arguments.length != 1 || !isString(arguments[0]))
            throw new LuaException("narrative.ruby requires a string");
        LuaValue[] spans;
        foreach (span; rubySpans(arguments[0].match!((string s) => s, _ => ""))) {
            LuaValue[string] record = ["text": LuaValue(span.text)];
            if (span.reading.length)
                record["reading"] = LuaValue(span.reading);
            spans ~= immutableRecord(record);
        }
        return [immutableSequence(spans)];
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
            throw new LuaException("narrative.on requires a symbol and a handler");
        (cast(LuaState) pointer).narrativeRegistry.registerHandler(symbolName(arguments[0]), arguments[1]);
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
            throw new LuaException("narrative.template requires text and bindings");
        auto bindings = diagnosticBindings(arguments[1]);
        if (bindings is null && !isTable(arguments[1]) && arguments[1].typeOf() != LuaType.UserData)
            throw new LuaException("template bindings must be a table or record");
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
