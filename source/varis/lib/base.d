/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib.base;

import varis.types;
import varis.table;
import varis.state;
import varis.vm;
import varis.fiber : VarisFiber, currentLuaFiber;
import core.thread : Fiber;
import varis.exception : LuaException;
import varis.lib.auxlib;
import std.conv : to;
import std.format : format;

/// Reads a whole file; returns false and sets `error` when it cannot be opened.
bool readWholeFile(string filename, out string content, out string error) {
    import core.stdc.stdio : fopen, fclose, fread, ferror, FILE;
    import core.stdc.errno : errno;
    import core.stdc.string : strerror;
    import std.string : toStringz, fromStringz;

    FILE* handle = fopen(filename.toStringz, "rb");
    if (handle is null) {
        error = (cast(string) strerror(errno).fromStringz).idup;
        return false;
    }
    scope (exit)
        fclose(handle);
    ubyte[] data;
    ubyte[65536] block;
    while (true) {
        auto got = fread(block.ptr, 1, block.length, handle);
        if (got == 0)
            break;
        data ~= block[0 .. got];
    }
    content = cast(string) data;
    return true;
}

/// Skips a UTF-8 BOM and a leading '#' line (luaL_loadfilex's skipcomment).
string skipFilePrefix(string content) {
    if (content.length >= 3 && content[0 .. 3] == "\xEF\xBB\xBF")
        content = content[3 .. $];
    if (content.length && content[0] == '#') {
        size_t i = 0;
        while (i < content.length && content[i] != '\n')
            ++i;
        // Keep the newline so line numbers stay correct (not before a binary chunk).
        content = content[i .. $];
        if (content.length > 1 && content[1] == '\x1b')
            content = content[1 .. $];
    }
    return content;
}

/// Loads the chunk of a source file read from disk, as the project's tiers require: a content
/// file is vetted and runs in the restricted environment the tier hook returns.
LuaFunction loadSourceFile(LuaState state, string filename, string content, string chunkName, string mode) {
    LuaValue environment;
    if (state.fileTierHook !is null) {
        auto problem = state.fileTierHook(filename, content, environment);
        if (problem.length)
            throw new LuaException(problem);
    }
    auto fn = loadChunk(state, skipFilePrefix(content), chunkName, mode);
    if (!isNil(environment)) {
        auto closure = cast(LuaClosure) fn;
        if (closure !is null && closure.upvalues.length)
            closure.upvalues[0].set(environment);
    }
    return fn;
}

/// Loads a chunk of text or binary code. Returns the function or throws LuaException.
LuaFunction loadChunk(LuaState state, string code, string chunkName, string mode) {
    import std.string : indexOf;

    bool binary = code.length && code[0] == '\x1b';
    if (mode.indexOf(binary ? 'b' : 't') < 0)
        throw new LuaException("attempt to load a " ~ (binary ? "binary" : "text") ~ " chunk (mode is '" ~ mode ~ "')");
    if (binary) {
        import varis.dump : undumpFunction;

        return undumpFunction(state, code, chunkName);
    }
    return state.loadString(code, chunkName);
}

private string shortChunkId(string chunkName) {
    import varis.exception : shortSourceName;

    return shortSourceName(chunkName);
}

/// Computes the textual form used by tostring/print (luaL_tolstring).
string tostringValue(LuaState state, LuaValue value) {
    auto mt = state.getMetatable(value);
    if (mt !is null) {
        auto meta = mt.rawget(LuaValue("__tostring"));
        if (!isNil(meta)) {
            auto results = VM.callValue(state, meta, [value]);
            auto result = results.length ? results[0] : luaNil();
            if (!isString(result) && !isNumber(result))
                throw new LuaException("'__tostring' must return a string");
            return toLuaString(result);
        }
    }
    if (isTable(value) || value.typeOf() == LuaType.UserData) {
        string tag = typeName(value);
        if (mt !is null) {
            auto name = mt.rawget(LuaValue("__name"));
            if (isString(name))
                tag = toLuaString(name);
        }
        auto text = toLuaString(value);
        auto colon = text.length ? text.length : 0;
        import std.string : indexOf;

        auto at = text.indexOf(": ");
        return at >= 0 ? tag ~ text[at .. $] : text;
    }
    return toLuaString(value);
}

private bool str2int(string s, int base, out long result) {
    import std.ascii : isAlphaNum, isDigit, toUpper;

    size_t i = 0;
    ulong n = 0;
    bool neg = false;
    while (i < s.length && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')))
        ++i;
    if (i < s.length && s[i] == '-') {
        ++i;
        neg = true;
    } else if (i < s.length && s[i] == '+')
        ++i;
    if (i >= s.length || !isAlphaNum(s[i]))
        return false;
    do {
        int digit = isDigit(s[i]) ? s[i] - '0' : (toUpper(s[i]) - 'A') + 10;
        if (digit >= base)
            return false;
        n = n * base + digit;
        ++i;
    }
    while (i < s.length && isAlphaNum(s[i]));
    while (i < s.length && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')))
        ++i;
    if (i != s.length)
        return false;
    result = cast(long)(neg ? 0UL - n : n);
    return true;
}

/// `true` followed by `results`, in a single allocation.
private LuaValue[] successResults(LuaValue[] results) {
    auto all = new LuaValue[results.length + 1];
    all[0] = LuaValue(true);
    all[1 .. $] = results[];
    return all;
}

void openBaseLib(LuaState state) {
    auto G = state.globals;
    string gcMode = "incremental";
    long gcPause = 200, gcStepMul = 100;

    // D owns collection; Lua collector modes and tuning only keep their parameters.
    G.registerDelegate("collectgarbage", (LuaState s, LuaValue[] a) {
        import core.memory : GC;
        import varis.gc : stackHygiene;

        static immutable options = [
            "stop", "restart", "collect", "count", "step", "setpause", "setstepmul",
            "isrunning", "generational", "incremental"
        ];
        immutable choice = checkOption(s, a, 1, "collect", options);
        // Mode and tuning calls (lua.c issues one at startup) do not observe collection; only
        // calls that do enable the per-call dead-stack scrub, which is costly for every Lua call.
        if (options[choice] != "generational" && options[choice] != "incremental" &&
            options[choice] != "setpause" && options[choice] != "setstepmul")
            stackHygiene = true;
        switch (options[choice]) {
        case "collect":
            if (s.inFinalizer)
                return [luaNil()];
            // Unreferenced files are flushed/closed by C Lua's collector; flush all streams instead.
            import core.stdc.stdio : fflush;

            fflush(null);
            s.pendingCollect = true; // executed by the interpreter loop once this call returns
            return [LuaValue(0L)];
        case "count":
            return [LuaValue(GC.stats().usedSize / 1024.0)];
        case "isrunning":
            return [LuaValue(s.gcRunning)];
        case "stop":
            if (s.gcRunning)
                GC.disable();
            s.gcRunning = false;
            return [LuaValue(0L)];
        case "restart":
            if (!s.gcRunning)
                GC.enable();
            s.gcRunning = true;
            return [LuaValue(0L)];
        case "step": {
                // Emulates an incremental collector: a cycle completes after an amount of work
                // proportional to the heap; larger steps finish it sooner.
                long stepSize = optInteger(s, a, 2, 0);
                if (s.inFinalizer)
                    return [luaNil()];
                if (gcMode == "generational") {
                    s.pendingCollect = true;
                    return [LuaValue(true)];
                }
                double cost = GC.stats().usedSize / 1024.0;
                if (cost < 64)
                    cost = 64;
                s.gcStepProgress += stepSize > 0 ? cast(double) stepSize : 1.0;
                if (s.gcStepProgress < cost)
                    return [LuaValue(false)];
                s.gcStepProgress = 0;
                s.pendingCollect = true;
                return [LuaValue(true)];
            }
        case "setpause": {
                auto old = gcPause;
                gcPause = optInteger(s, a, 2, 0);
                return [LuaValue(old)];
            }
        case "setstepmul": {
                auto old = gcStepMul;
                gcStepMul = optInteger(s, a, 2, 0);
                return [LuaValue(old)];
            }
        case "generational": {
                auto old = gcMode;
                gcMode = "generational";
                return [LuaValue(old)];
            }
        case "incremental": {
                auto old = gcMode;
                gcMode = "incremental";
                return [LuaValue(old)];
            }
        default:
            return [luaNil()];
        }
    });

    G.registerDelegate("print", (LuaState s, LuaValue[] a) {
        import core.stdc.stdio : fwrite, stdout, fflush;

        foreach (size_t i, arg; a) {
            auto text = tostringValue(s, arg);
            if (i > 0)
                fwrite("\t".ptr, 1, 1, stdout);
            fwrite(text.ptr, 1, text.length, stdout);
        }
        fwrite("\n".ptr, 1, 1, stdout);
        fflush(stdout);
        return cast(LuaValue[])[];
    });

    G.registerDelegate("warn", (LuaState s, LuaValue[] a) {
        checkString(s, a, 1);
        foreach (i; 2 .. a.length + 1)
            checkString(s, a, cast(int) i);
        foreach (i; 1 .. a.length + 1)
            s.warning(checkString(s, a, cast(int) i), i < a.length);
        return cast(LuaValue[])[];
    });

    G.register("type", (LuaState s, LuaValue[] a) {
        checkAny(a, 1);
        return [LuaValue(typeName(a[0]))];
    });

    G.register("tostring", (LuaState s, LuaValue[] a) {
        checkAny(a, 1);
        return [LuaValue(tostringValue(s, a[0]))];
    });

    G.register("tonumber", (LuaState s, LuaValue[] a) {
        if (isNoneOrNil(a, 2)) {
            if (a.length && isNumber(a[0]))
                return [a[0]];
            if (a.length && isString(a[0])) {
                LuaValue number;
                if (parseLuaNumber(a[0].match!((string text) => text, _ => ""), number))
                    return [number];
            }
            checkAny(a, 1);
        } else {
            long base = checkInteger(s, a, 2);
            if (a.length < 1 || !isString(a[0]))
                typeError(s, a, 1, "string");
            if (!(2 <= base && base <= 36))
                argError(2, "base out of range");
            long n;
            if (str2int(a[0].match!((string text) => text, _ => ""), cast(int) base, n))
                return [LuaValue(n)];
        }
        return [luaNil()];
    });

    G.register("assert", delegate LuaValue[](LuaState s, LuaValue[] a) {
        if (a.length && isTruthy(a[0]))
            return a;
        checkAny(a, 1);
        LuaValue message = a.length > 1 ? a[1] : LuaValue("assertion failed!");
        if (isString(message))
            message = LuaValue(s.locationPrefix(1) ~ toLuaString(message));
        throw new LuaException(message);
    });

    G.register("error", delegate LuaValue[](LuaState s, LuaValue[] a) {
        LuaValue errObj = a.length ? a[0] : luaNil();
        long level = optInteger(s, a, 2, 1);
        if (isString(errObj) && level > 0)
            errObj = LuaValue(s.locationPrefix(cast(int) level) ~ toLuaString(errObj));
        auto failure = new LuaException(errObj);
        failure.needsLocation = false;
        throw failure;
    });

    state.errorFunction = G.rawget(LuaValue("error")).asFunction;

    G.registerDelegate("pcall", (LuaState s, LuaValue[] a) {
        auto fiber = currentLuaFiber();
        if (fiber !is null)
            fiber.protectedDepth++;
        scope (exit)
            if (fiber !is null)
                fiber.protectedDepth--;
        checkAny(a, 1);
        auto thread = s.currentThread();
        if (thread !is null)
            thread.pushBoundary(false);
        scope (exit)
            if (thread !is null)
                thread.popBoundary();
        try {
            // `pcall(error, value [, level])`: the result is known without raising anything. The
            // error function's frame is pushed while the position prefix is computed, so the level
            // counts frames exactly as in a real call. Unusual arguments take the general path.
            if (a[0].isFunction && a[0].asFunction is s.errorFunction && (thread is null || thread.hookFunction is null)
                && (a.length <= 2 || a[2].isNil || a[2].isInteger)) {
                LuaValue errObj = a.length > 1 ? a[1] : luaNil();
                long level = a.length > 2 && a[2].isInteger ? a[2].asInteger : 1;
                if (isString(errObj) && level > 0) {
                    s.pushCall(s.errorFunction, "[C]", -1, false, "error", "global");
                    auto prefix = s.locationPrefix(cast(int) level);
                    s.popCall();
                    if (prefix.length)
                        errObj = LuaValue(prefix ~ toLuaString(errObj));
                }
                return [LuaValue(false), errObj];
            }
            LuaException protectedFailure;
            auto results = VM.callProtected(s, a[0], a.length > 1 ? a[1 .. $] : [], protectedFailure);
            if (protectedFailure !is null)
                return [LuaValue(false), protectedFailure.errorObject];
            return successResults(results);
        } catch (LuaException e) {
            return [LuaValue(false), e.errorObject];
        } catch (Exception e) {
            return [LuaValue(false), LuaValue(e.msg)];
        }
    });

    G.registerDelegate("xpcall", (LuaState s, LuaValue[] a) {
        auto fiber = currentLuaFiber();
        if (fiber !is null)
            fiber.protectedDepth++;
        scope (exit)
            if (fiber !is null)
                fiber.protectedDepth--;
        if (a.length < 2 || !isFunction(a[1]))
            typeError(s, a, 2, "function");
        auto thread = s.currentThread();
        if (thread !is null)
            thread.pushBoundary(true, a[1]);
        scope (exit)
            if (thread !is null)
                thread.popBoundary();
        try {
            LuaException protectedFailure;
            auto results = VM.callProtected(s, a[0], a.length > 2 ? a[2 .. $] : [], protectedFailure);
            if (protectedFailure !is null) {
                s.dispatchError(protectedFailure);
                return [LuaValue(false), protectedFailure.errorObject];
            }
            return successResults(results);
        } catch (LuaException error) {
            s.dispatchError(error);
            return [LuaValue(false), error.errorObject];
        } catch (Exception failure) {
            auto error = new LuaException(LuaValue(failure.msg));
            s.dispatchError(error);
            return [LuaValue(false), error.errorObject];
        }
    });

    G.register("next", (LuaState s, LuaValue[] a) {
        auto t = checkTable(s, a, 1);
        LuaValue nextK, nextV;
        if (t.next(argAt(a, 2), nextK, nextV))
            return [nextK, nextV];
        return [luaNil()];
    });
    auto nextFunction = G.rawget(LuaValue("next"));
    state.fastNext = nextFunction.asFunction;

    G.registerDelegate("pairs", (LuaState s, LuaValue[] a) {
        checkAny(a, 1);
        auto mt = s.getMetatable(a[0]);
        auto meta = mt is null ? luaNil() : mt.rawget(LuaValue("__pairs"));
        if (isNil(meta))
            return [nextFunction, a[0], luaNil()];
        auto results = VM.callValue(s, meta, [a[0]]);
        while (results.length < 3)
            results ~= luaNil();
        return results[0 .. 3];
    });

    auto ipairsIterator = LuaValue(new LuaNativeFunction((void* sp, LuaValue[] a) {
            auto s = cast(LuaState) sp;
            long i = checkInteger(s, a, 2);
            i = cast(long)(cast(ulong) i + 1);
            auto item = VM.getTable(s, argAt(a, 1), LuaValue(i));
            if (isNil(item))
                return [luaNil()];
            return [LuaValue(i), item];
        }, "ipairs_aux"));
    state.fastIpairsIter = ipairsIterator.asFunction;
    G.register("ipairs", (LuaState s, LuaValue[] a) {
        checkAny(a, 1);
        return [ipairsIterator, a[0], LuaValue(0L)];
    });

    G.register("select", (LuaState s, LuaValue[] a) {
        long n = cast(long) a.length;
        if (a.length && isString(a[0]) && a[0].match!((string t) => t.length && t[0] == '#', _ => false))
            return [LuaValue(n - 1)];
        long i = checkInteger(s, a, 1);
        if (i < 0)
            i = n + i;
        else if (i > n)
            i = n;
        if (!(1 <= i))
            argError(1, "index out of range");
        return a[cast(size_t) i .. $];
    });

    G.register("rawequal", (LuaState s, LuaValue[] a) {
        checkAny(a, 1);
        checkAny(a, 2);
        return [LuaValue(luaRawEqual(a[0], a[1]))];
    });

    G.register("rawget", (LuaState s, LuaValue[] a) {
        auto t = checkTable(s, a, 1);
        checkAny(a, 2);
        return [t.rawget(a[1])];
    });

    G.register("rawset", (LuaState s, LuaValue[] a) {
        auto t = checkTable(s, a, 1);
        checkAny(a, 2);
        checkAny(a, 3);
        t.rawset(a[1], a[2]);
        return [a[0]];
    });

    G.register("rawlen", delegate LuaValue[](LuaState s, LuaValue[] a) {
        if (a.length && isTable(a[0]))
            return [LuaValue(a[0].match!((LuaTable t) => t, _ => null).rawLen())];
        if (a.length && isString(a[0]))
            return [LuaValue(cast(long) a[0].match!((string t) => t.length, _ => 0UL))];
        typeError(s, a, 1, "table or string");
        return [];
    });

    G.register("getmetatable", (LuaState s, LuaValue[] a) {
        checkAny(a, 1);
        auto mt = s.getMetatable(a[0]);
        if (mt is null)
            return [luaNil()];
        auto prot = mt.rawget(LuaValue("__metatable"));
        if (!isNil(prot))
            return [prot];
        return [LuaValue(mt)];
    });

    G.register("setmetatable", (LuaState s, LuaValue[] a) {
        auto t = checkTable(s, a, 1);
        if (a.length < 2 || !(isNil(a[1]) || isTable(a[1])))
            typeError(s, a, 2, "nil or table");
        if (t.metatable !is null && !isNil(t.metatable.rawget(LuaValue("__metatable"))))
            throw new LuaException("cannot change a protected metatable");
        t.metatable = isNil(a[1]) ? null : a[1].match!((LuaTable tbl) => tbl, _ => null);
        if (t.metatable !is null && !isNil(t.metatable.rawget(LuaValue("__gc"))))
            s.markForFinalization(a[0]);
        import varis.gc : registerWeakIfNeeded;

        registerWeakIfNeeded(t);
        return [a[0]];
    });

    foreach (name; ["pcall", "xpcall"]) {
        // They only read their arguments and hand a view of them to the protected call.
        auto protectedCall = G.rawget(LuaValue(name));
        if (protectedCall.isFunction)
            protectedCall.asFunction.borrowsArgs = true;
    }

    G.registerDelegate("load", (LuaState s, LuaValue[] a) {
        string mode = optString(s, a, 3, "bt");
        string code, chunkName;
        if (a.length && (isString(a[0]) || isNumber(a[0]))) {
            code = toLuaString(a[0]);
            chunkName = optString(s, a, 2, code);
        } else {
            chunkName = optString(s, a, 2, "=(load)");
            if (a.length < 1 || !isFunction(a[0]))
                typeError(s, a, 1, "function");
            import std.array : appender;

            auto source = appender!string();
            try {
                while (true) {
                    auto piece = VM.callValue(s, a[0], []);
                    if (!piece.length || isNil(piece[0]))
                        break;
                    if (!isString(piece[0]) && !isNumber(piece[0]))
                        return [luaNil(), LuaValue("reader function must return a string")];
                    string fragment = toLuaString(piece[0]);
                    if (!fragment.length)
                        break;
                    source.put(fragment);
                }
            } catch (LuaException e) {
                return [luaNil(), e.errorObject];
            }
            code = source.data;
        }
        try {
            auto fn = loadChunk(s, code, chunkName, mode);
            if (a.length > 3) {
                auto closure = cast(LuaClosure) fn;
                if (closure !is null && closure.upvalues.length)
                    closure.upvalues[0].set(a[3]);
            }
            return [LuaValue(fn)];
        } catch (LuaException e) {
            return [luaNil(), e.errorObject];
        }
    });

    G.registerDelegate("loadfile", (LuaState s, LuaValue[] a) {
        string filename = optString(s, a, 1, null);
        string mode = optString(s, a, 2, "bt");
        string content, error;
        string chunkName;
        if (filename is null) {
            import std.stdio : stdin, KeepTerminator;
            import std.array : appender;

            auto all = appender!string();
            foreach (line; stdin.byLine(KeepTerminator.yes))
                all.put(line);
            content = all.data;
            chunkName = "=stdin";
        } else {
            if (!readWholeFile(filename, content, error))
                return [luaNil(), LuaValue("cannot open " ~ filename ~ ": " ~ error)];
            chunkName = "@" ~ filename;
        }
        try {
            auto fn = filename is null ? loadChunk(s, skipFilePrefix(content), chunkName, mode) : loadSourceFile(s, filename, content, chunkName, mode);
            if (a.length > 2) {
                auto closure = cast(LuaClosure) fn;
                if (closure !is null && closure.upvalues.length)
                    closure.upvalues[0].set(a[2]);
            }
            return [LuaValue(fn)];
        } catch (LuaException e) {
            return [luaNil(), e.errorObject];
        }
    });

    G.registerDelegate("dofile", (LuaState s, LuaValue[] a) {
        string filename = optString(s, a, 1, null);
        string content, error;
        string chunkName = "=stdin";
        if (filename !is null) {
            if (!readWholeFile(filename, content, error))
                throw new LuaException("cannot open " ~ filename ~ ": " ~ error);
            chunkName = "@" ~ filename;
        } else {
            import std.stdio : stdin, KeepTerminator;
            import std.array : appender;

            auto all = appender!string();
            foreach (line; stdin.byLine(KeepTerminator.yes))
                all.put(line);
            content = all.data;
        }
        auto fn = filename is null ? loadChunk(s, skipFilePrefix(content), chunkName, "bt") : loadSourceFile(s, filename, content, chunkName, "bt");
        return VM.callValue(s, LuaValue(fn), []);
    });
}
