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
            LuaValue(template_.render(state, snapshot, bindings, &state.narrativeRegistry.display, selections))
        ];
    });
    state.setGlobal("narrative", LuaValue(library));
}
