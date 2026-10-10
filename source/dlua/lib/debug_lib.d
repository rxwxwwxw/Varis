/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.lib.debug_lib;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.exception : LuaException, shortSourceName;
import dlua.vm : LuaClosure, VM;
import dlua.lib.auxlib;

private LuaClosure closureArgument(LuaValue[] args, size_t index, string name) {
    if (index >= args.length || !isFunction(args[index]))
        throw new LuaException("bad argument to '" ~ name ~ "' (function expected)");
    return cast(LuaClosure)args[index].match!((LuaFunction fn) => fn, _ => null);
}

private long upvalueIndex(LuaValue[] args, size_t index, string name) {
    long result;
    LuaValue number;
    if (index >= args.length || !VM.toCoercedNumber(args[index], number))
        throw new LuaException("bad argument to '" ~ name ~ "' (integer expected)");
    if (isInteger(number)) return number.match!((long value) => value, _ => 0L);
    if (!floatToInteger(number.match!((double value) => value, _ => double.nan), result))
        throw new LuaException("bad argument to '" ~ name ~ "' (number has no integer representation)");
    return result;
}

private CallInfo[] threadFrames(LuaState state, LuaThread thread) {
    if (thread is state.currentThread()) return state.callStack;
    if (thread is state.mainThread) return state.mainStack();
    import dlua.fiber : DluaFiber;
    auto fiber = cast(DluaFiber)thread.fiber;
    return fiber is null ? null : fiber.callStack;
}

private string findFunctionName(LuaTable table, LuaFunction fn, int depth) {
    foreach (entry; table.hashEntries) {
        auto key = entry.key; auto value = entry.value;
        if (!isString(key)) continue;
        auto name = toLuaString(key);
        if (isFunction(value) && value.match!((LuaFunction candidate) => candidate is fn, _ => false)) return name;
        if (depth > 1 && isTable(value) && name != "_G") {
            auto nested = findFunctionName(value.match!((LuaTable table) => table, _ => null), fn, depth - 1);
            if (nested.length) return name ~ "." ~ nested;
        }
    }
    return "";
}

void openDebugLib(LuaState state) {
    auto dbgTable = new LuaTable();
    {
        // Registry table of hooks keyed by thread (weak keys), as created by debug.sethook in C Lua.
        auto hookTable = new LuaTable();
        hookTable.metatable = hookTable;
        hookTable.rawset(LuaValue("__mode"), LuaValue("k"));
        state.registry.rawset(LuaValue("_HOOKKEY"), LuaValue(hookTable));
    }

    dbgTable.register("getupvalue", (LuaState L, LuaValue[] a) {
        long index = checkInteger(L, a, 2);
        if (a.length < 1 || !isFunction(a[0])) typeError(L, a, 1, "function");
        auto closure = cast(LuaClosure)a[0].match!((LuaFunction fn) => fn, _ => null);
        if (closure is null) {
            auto native = cast(LuaNativeFunction)a[0].match!((LuaFunction fn) => fn, _ => null);
            if (native !is null && index >= 1 && index <= native.debugUpvalues.length) return [LuaValue(""), native.debugUpvalues[cast(size_t)index - 1]];
            return cast(LuaValue[])[];
        }
        if (index <= 0 || index > closure.upvalues.length) return cast(LuaValue[])[];
        auto upvalueName = closure.proto.upvalues[index - 1].name;
        return [LuaValue(upvalueName.length ? upvalueName : "(no name)"), closure.upvalues[index - 1].get()];
    });

    dbgTable.register("setupvalue", (LuaState L, LuaValue[] a) {
        checkAny(a, 3);
        long index = checkInteger(L, a, 2);
        if (a.length < 1 || !isFunction(a[0])) typeError(L, a, 1, "function");
        auto closure = cast(LuaClosure)a[0].match!((LuaFunction fn) => fn, _ => null);
        if (closure is null || index <= 0 || index > closure.upvalues.length) return cast(LuaValue[])[];
        closure.upvalues[index - 1].set(a[2]);
        auto setName = closure.proto.upvalues[index - 1].name;
        return [LuaValue(setName.length ? setName : "(no name)")];
    });

    dbgTable.register("upvalueid", (LuaState L, LuaValue[] a) {
        long index = checkInteger(L, a, 2);
        if (a.length < 1 || !isFunction(a[0])) typeError(L, a, 1, "function");
        auto closure = cast(LuaClosure)a[0].match!((LuaFunction fn) => fn, _ => null);
        if (closure is null) {
            auto native = cast(LuaNativeFunction)a[0].match!((LuaFunction fn) => fn, _ => null);
            if (native !is null && index >= 1 && index <= native.debugUpvalues.length)
                return [LuaValue(LightUserData(cast(void*)&native.debugUpvalues[cast(size_t)index - 1]))];
            return [luaNil()];
        }
        if (index <= 0 || index > closure.upvalues.length) return [luaNil()];
        return [LuaValue(LightUserData(cast(void*)closure.upvalues[index - 1]))];
    });

    dbgTable.register("upvaluejoin", (LuaState L, LuaValue[] a) {
        long i = checkInteger(L, a, 2);
        if (a.length < 1 || !isFunction(a[0])) typeError(L, a, 1, "function");
        auto first = cast(LuaClosure)a[0].match!((LuaFunction fn) => fn, _ => null);
        if (first is null || i <= 0 || i > first.upvalues.length) throw new ArgError(2, "invalid upvalue index");
        long j = checkInteger(L, a, 4);
        if (a.length < 3 || !isFunction(a[2])) typeError(L, a, 3, "function");
        auto second = cast(LuaClosure)a[2].match!((LuaFunction fn) => fn, _ => null);
        if (second is null || j <= 0 || j > second.upvalues.length) throw new ArgError(4, "invalid upvalue index");
        first.upvalues[i - 1] = second.upvalues[j - 1];
        return cast(LuaValue[])[];
    });

    dbgTable.register("getregistry", (LuaState L, LuaValue[] a) => [LuaValue(L.registry)]);

    dbgTable.register("getuservalue", (LuaState L, LuaValue[] a) {
        long n = optInteger(L, a, 2, 1);
        if (a.length < 1 || a[0].typeOf() != LuaType.UserData) return [luaNil()];
        auto u = a[0].match!((LuaUserData x) => x, _ => null);
        if (n < 1 || n > u.userValues.length) return [luaNil()];
        return [u.userValues[n - 1], LuaValue(true)];
    });

    dbgTable.register("setuservalue", (LuaState L, LuaValue[] a) {
        long n = optInteger(L, a, 3, 1);
        if (a.length < 1 || a[0].typeOf() != LuaType.UserData) typeError(L, a, 1, "userdata");
        checkAny(a, 2);
        auto u = a[0].match!((LuaUserData x) => x, _ => null);
        if (n < 1 || n > 1000) return [luaNil()];
        if (n > u.userValues.length) return [luaNil()];
        u.userValues[n - 1] = a[1];
        return [a[0]];
    });

    dbgTable.register("setcstacklimit", (LuaState L, LuaValue[] a) {
        checkInteger(L, a, 1);
        return [LuaValue(0L)];
    });

    LuaNativeFunction localAccessor(bool setter) {
        string operation = setter ? "setlocal" : "getlocal";
        return new LuaNativeFunction((void* sPtr, LuaValue[] args) {
            auto s = cast(LuaState)sPtr;
            auto thread = s.currentThread();
            if (args.length && args[0].typeOf() == LuaType.Thread) {
                thread = args[0].match!((LuaThread thread) => thread, _ => null); args = args[1 .. $];
            }
            long index = cast(int)upvalueIndex(args, 1, operation);
            if (!setter && args.length && isFunction(args[0])) {
                auto closure = cast(LuaClosure)args[0].match!((LuaFunction fn) => fn, _ => null);
                if (closure is null || index <= 0) return [luaNil()];
                foreach (local; closure.proto.debugLocals) if (local.register < closure.proto.numParams &&
                    (!local.name.length || local.name[0] != '@') && --index == 0) return [LuaValue(local.name)];
                return [luaNil()];
            }
            long level = cast(int)upvalueIndex(args, 0, operation);
            auto frames = threadFrames(s, thread);
            if (level < 0 || level >= frames.length) throw new LuaException("bad argument to '" ~ operation ~ "' (level out of range)");
            auto frame = frames[$ - 1 - level];
            string name;
            if (setter) {
                if (args.length < 3) throw new LuaException("bad argument #3 to 'setlocal' (value expected)");
                name = frame.setLocal(index, args[2]);
                return [name is null ? luaNil() : LuaValue(name)];
            }
            LuaValue value;
            bool inTransfer = frame.ftransfer > 0 && index >= frame.ftransfer && index - frame.ftransfer < cast(long)frame.transfer.length;
            name = frame.getLocal(index, value);
            if (inTransfer) {
                // Transferred values (call parameters, returned values) override the frame's slots.
                bool named = name !is null && name != "(temporary)" && name != "(C temporary)" && !frame.transferIsReturn;
                string label = named ? name : cast(LuaClosure)frame.fn is null ? "(C temporary)" : "(temporary)";
                return [LuaValue(label), frame.transfer[cast(size_t)(index - frame.ftransfer)]];
            }
            if (name !is null) return [LuaValue(name), value];
            return [luaNil()];
        }, operation);
    }
    dbgTable.rawset(LuaValue("getlocal"), LuaValue(localAccessor(false)));
    dbgTable.rawset(LuaValue("setlocal"), LuaValue(localAccessor(true)));

    dbgTable.rawset(LuaValue("sethook"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
        auto s = cast(LuaState)sPtr;
        size_t offset;
        auto thread = s.currentThread();
        if (args.length && args[0].typeOf() == LuaType.Thread) {
            thread = args[0].match!((LuaThread thread) => thread, _ => null); offset = 1;
        }
        if (args.length <= offset || isNil(args[offset])) {
            thread.hookFunction = null; thread.hookMask = 0; thread.hookCount = 0; thread.hookRemaining = 0;
            return cast(LuaValue[])[];
        }
        if (args.length <= offset + 1 || (!isString(args[offset + 1]) && !isNumber(args[offset + 1])))
            throw new LuaException("bad argument to 'sethook' (string expected)");
        if (!isFunction(args[offset])) throw new LuaException("bad argument to 'sethook' (function expected)");
        string mask = toLuaString(args[offset + 1]);
        int count = args.length > offset + 2 && !isNil(args[offset + 2]) ? cast(int)upvalueIndex(args, offset + 2, "sethook") : 0;
        import std.string : indexOf;
        thread.hookFunction = args[offset].match!((LuaFunction fn) => fn, _ => null);
        thread.hookMask = (mask.indexOf('c') >= 0 ? 1 : 0) | (mask.indexOf('r') >= 0 ? 2 : 0) |
            (mask.indexOf('l') >= 0 ? 4 : 0) | (count > 0 ? 8 : 0);
        thread.hookCount = count; thread.hookRemaining = count;
        if (thread.hookMask != 0) {
            import dlua.state : vmAttention, vmSlowMode;
            vmSlowMode = true; vmAttention = true;
        }
        return cast(LuaValue[])[];
    }, "sethook")));

    dbgTable.rawset(LuaValue("gethook"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
        auto thread = (cast(LuaState)sPtr).currentThread();
        if (args.length && args[0].typeOf() == LuaType.Thread)
            thread = args[0].match!((LuaThread thread) => thread, _ => null);
        if (!thread.hookMask) return [luaNil()];
        string mask;
        if (thread.hookMask & 1) mask ~= 'c';
        if (thread.hookMask & 2) mask ~= 'r';
        if (thread.hookMask & 4) mask ~= 'l';
        return [thread.hookFunction is null ? luaNil() : LuaValue(thread.hookFunction), LuaValue(mask), LuaValue(thread.hookCount)];
    }, "gethook")));

    // debug.traceback([thread,] [message [, level]])
    dbgTable.rawset(LuaValue("traceback"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
        auto s = cast(LuaState)sPtr;
        auto thread = s.currentThread();
        if (args.length && args[0].typeOf() == LuaType.Thread) {
            thread = args[0].match!((LuaThread thread) => thread, _ => null); args = args[1 .. $];
        }
        string trace;
        if (args.length && !isNil(args[0])) {
            if (!isString(args[0]) && !isNumber(args[0])) return [args[0]];
            string message = toLuaString(args[0]);
            import std.string : indexOf;
            auto nul = message.indexOf('\0');
            if (nul >= 0) message = message[0 .. nul];
            trace = message ~ "\n";
        }
        long level = args.length > 1 && !isNil(args[1]) ? upvalueIndex(args, 1, "traceback") : thread is s.currentThread() ? 1 : 0;
        trace ~= "stack traceback:";
        auto frames = threadFrames(s, thread);
        long last = cast(long)frames.length - 1;
        int limit = last - level > 21 ? 10 : -1;
        import std.conv : to;
        while (level >= 0 && level <= last) {
            auto frame = frames[last - level++];
            if (limit-- == 0) {
                long skip = last - level - 11 + 1;
                trace ~= "\n\t...\t(skipping " ~ skip.to!string ~ " levels)";
                level += skip;
                continue;
            }
            auto closure = cast(LuaClosure)frame.fn;
            string source = closure is null ? "[C]" : shortSourceName(frame.source);
            trace ~= "\n\t" ~ source;
            if (frame.line > 0) trace ~= ":" ~ frame.line.to!string;
            trace ~= ": in ";
            string name = VM.globalFunctionName(s, frame.fn);
            if (name.length) trace ~= "function '" ~ name ~ "'";
            else if (frame.nameKind.length) trace ~= frame.nameKind ~ " '" ~ frame.name ~ "'";
            else if (closure is null) trace ~= "?";
            else if (closure.proto.lineDefined == 0) trace ~= "main chunk";
            else trace ~= "function <" ~ source ~ ":" ~ closure.proto.lineDefined.to!string ~ ">";
            if (frame.tailCall) trace ~= "\n\t(...tail calls...)";
        }
        return [LuaValue(trace)];
    }, "traceback")));

    dbgTable.register("getmetatable", (LuaState L, LuaValue[] a) {
        checkAny(a, 1);
        auto mt = L.getMetatable(a[0]);
        if (mt is null) return [luaNil()];
        return [LuaValue(mt)];
    });

    dbgTable.register("setmetatable", (LuaState L, LuaValue[] a) {
        if (a.length < 2 || !(isNil(a[1]) || isTable(a[1]))) typeError(L, a, 2, "nil or table");
        auto mt = isTable(a[1]) ? a[1].match!((LuaTable t) => t, _ => null) : null;
        L.setMetatable(a[0], mt);
        if (mt !is null && !isNil(mt.rawget(LuaValue("__gc")))) L.markForFinalization(a[0]);
        if (a[0].typeOf() == LuaType.Table) {
            import dlua.gc : registerWeakIfNeeded;
            registerWeakIfNeeded(a[0].match!((LuaTable t) => t, _ => null));
        }
        return [a[0]];
    });

    // debug.getinfo([thread,] f [, what])
    dbgTable.rawset(LuaValue("getinfo"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
        if (args.length == 0) return [luaNil()];
        auto s = cast(LuaState)sPtr;
        auto target = s.currentThread();
        if (args[0].typeOf() == LuaType.Thread) {
            target = args[0].match!((LuaThread thread) => thread, _ => null);
            args = args[1 .. $];
            if (!args.length) throw new LuaException("bad argument to 'getinfo' (function or level expected)");
        }
        auto frames = threadFrames(s, target);

        string options = "flnSrtu";
        if (args.length > 1 && !isNil(args[1])) {
            if (!isString(args[1])) throw new LuaException("bad argument #2 to 'getinfo' (string expected)");
            options = args[1].match!((string value) => value, _ => "");
        }
        import std.string : indexOf, startsWith;
        foreach (option; options) if ("nSlutfLr".indexOf(option) < 0)
            throw new LuaException("bad argument #2 to 'getinfo' (invalid option)");
        CallInfo ci;
        bool byFunction = isFunction(args[0]);
        if (byFunction) {
            ci.fn = args[0].match!((LuaFunction fn) => fn, _ => null);
            auto closure = cast(LuaClosure)ci.fn;
            ci.source = closure is null ? "=[C]" : closure.proto.sourceName;
            ci.currentLine = -1;
        } else {
            long level = upvalueIndex(args, 0, "getinfo");
            ptrdiff_t stackIdx = cast(ptrdiff_t)frames.length - 1 - level;
            if (level < 0 || stackIdx < 0 || stackIdx >= frames.length) return [luaNil()];
            ci = frames[stackIdx];
        }
        auto resTbl = new LuaTable();
        auto clos = (ci.fn !is null) ? cast(LuaClosure)ci.fn : null;
        foreach (option; options) switch (option) {
            case 'S':
                string source = clos is null ? "=[C]" : ci.source;
                string shortName = shortSourceName(source);
                resTbl.rawset(LuaValue("source"), LuaValue(source));
                resTbl.rawset(LuaValue("short_src"), LuaValue(shortName));
                resTbl.rawset(LuaValue("linedefined"), LuaValue(clos is null ? -1L : cast(long)clos.proto.lineDefined));
                resTbl.rawset(LuaValue("lastlinedefined"), LuaValue(clos is null ? -1L : cast(long)clos.proto.lastLineDefined));
                resTbl.rawset(LuaValue("what"), LuaValue(clos is null ? "C" : clos.proto.lineDefined == 0 ? "main" : "Lua"));
                break;
            case 'l': resTbl.rawset(LuaValue("currentline"), LuaValue(cast(long)ci.line)); break;
            case 'n':
                if (!byFunction && ci.name.length) resTbl.rawset(LuaValue("name"), LuaValue(ci.name));
                resTbl.rawset(LuaValue("namewhat"), LuaValue(byFunction ? "" : ci.nameKind));
                break;
            case 'u':
                auto nativeFn = cast(LuaNativeFunction)ci.fn;
                resTbl.rawset(LuaValue("nups"), LuaValue(clos ? cast(long)clos.upvalues.length : nativeFn !is null ? cast(long)nativeFn.debugUpvalues.length : 0L));
                resTbl.rawset(LuaValue("nparams"), LuaValue(clos ? cast(long)clos.proto.numParams : 0L));
                resTbl.rawset(LuaValue("isvararg"), LuaValue(clos is null || clos.proto.isVararg));
                break;
            case 'f': resTbl.rawset(LuaValue("func"), LuaValue(ci.fn)); break;
            case 'L':
                if (clos !is null) {
                    auto lines = new LuaTable();
                    foreach (instruction; clos.proto.code) if (instruction.line > 0)
                        lines.rawset(LuaValue(cast(long)instruction.line), LuaValue(true));
                    resTbl.rawset(LuaValue("activelines"), LuaValue(lines));
                }
                break;
            case 't': resTbl.rawset(LuaValue("istailcall"), LuaValue(ci.tailCall)); break;
            case 'r':
                resTbl.rawset(LuaValue("ftransfer"), LuaValue(cast(long)(ci.transfer.length ? ci.ftransfer : 0)));
                resTbl.rawset(LuaValue("ntransfer"), LuaValue(cast(long)ci.transfer.length));
                break;
            default: break;
        }

        return [LuaValue(resTbl)];
    }, "getinfo")));

    // debug.debug(): reads commands from stdin until "cont".
    dbgTable.rawset(LuaValue("debug"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
        import core.stdc.stdio : fgets, fputs, fflush, stdin, stderr, fwrite;
        import std.string : fromStringz;
        auto s = cast(LuaState)sPtr;
        char[250] buffer;
        while (true) {
            fputs("lua_debug> ", stderr);
            fflush(stderr);
            if (fgets(buffer.ptr, cast(int)buffer.length, stdin) is null) return cast(LuaValue[])[];
            auto line = fromStringz(buffer.ptr).idup;
            if (line == "cont\n") return cast(LuaValue[])[];
            try {
                auto fn = s.loadString(line, "=(debug command)");
                VM.callValue(s, LuaValue(fn), []);
            } catch (LuaException failure) {
                auto text = toLuaString(failure.errorObject) ~ "\n";
                fwrite(text.ptr, 1, text.length, stderr);
                fflush(stderr);
            }
        }
    }, "debug")));

    state.setGlobal("debug", LuaValue(dbgTable));
}
