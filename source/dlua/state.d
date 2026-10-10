/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.state;

import dlua.types;
import dlua.table;
import dlua.exception;
import std.sumtype;
import core.thread : Fiber;
import dlua.logic.world : World;

struct CallInfo {
    LuaFunction fn;
    string source;
    int currentLine;
    bool tailCall;
    string name;
    string nameKind;
    string delegate(long, out LuaValue) getLocal;
    string delegate(long, LuaValue) setLocal;
    // Values transferred by the call/return being hooked (debug.getinfo "r").
    LuaValue[] transfer;
    int ftransfer;
    bool transferIsReturn;
    void delegate() clearDead;  // nils the frame's registers that hold no live values
}

/// Shared only among isolated analysis branches, never with the live state.
class AnalysisBudget {
    size_t remaining;
    size_t remainingObjects = 200_000;
    string[] blockedEffects;
    this(size_t instructions) { remaining = instructions; }
}

/// Central runtime state for Lua execution
class LuaState {
    bool gcRunning = true;
    LuaThread mainThread;
    string[LuaFunction] standardNativePaths;
    LuaFunction[string] standardNativeFunctions;
    AnalysisBudget analysisBudget;
    // Per-Fiber so a suspended ordinary coroutine cannot leak its call context.
    World mainCallWorld;

    World callWorld() {
        import dlua.fiber : DluaFiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
        return fiber is null ? mainCallWorld : fiber.callWorld;
    }

    void callWorld(World world) {
        import dlua.fiber : DluaFiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
        if (fiber is null) mainCallWorld = world; else fiber.callWorld = world;
    }
    LuaTable globals;
    LuaTable registry;
    LuaTable stringMetatable;
    LuaTable numberMetatable;

    // Finalizers (__gc) run at state close; D's collector cannot call back into Lua.
    LuaValue[] finalizers;
    bool[size_t] finalizerMarked;  // keyed by hidden references (a plain pointer key would keep the object alive)
    bool closing;
    bool inFinalizer;
    bool inGcCycle;
    bool pendingCollect;
    double gcStepProgress;  // work done towards the current emulated collection cycle (KB)
    LuaValue[] stashedResults;  // call results waiting for the register array to grow
    size_t allocTicks;
    size_t gcThreshold = 50_000;
    int resumeDepth;

    // Warning system state (lauxlib warnf)
    bool warnOn;
    bool warnContinued;
    bool warnControlPending = true;

    /// Emits a warning piece; `tocont` signals that more pieces follow.
    void warning(string message, bool tocont) {
        import core.stdc.stdio : fputs, fwrite, stderr, fflush;
        if (!warnContinued && !tocont && message.length && message[0] == '@' && warnControlPending) {
            // control message
            if (message == "@on") warnOn = true;
            else if (message == "@off") warnOn = false;
            return;
        }
        if (warnOn) {
            if (!warnContinued) fputs("Lua warning: ", stderr);
            fwrite(message.ptr, 1, message.length, stderr);
            if (!tocont) fputs("\n", stderr);
            fflush(stderr);
        }
        warnContinued = tocont;
    }

    /// Counts allocations; periodically runs a collection cycle so weak tables and
    /// finalizers behave as with an incremental collector.
    pragma(inline, true)
    void allocationTick() {
        if (++allocTicks >= gcThreshold) {
            import dlua.gc : gcTick;
            gcTick(this);
        }
    }

    /// Registers an object whose metatable defines __gc.
    void markForFinalization(LuaValue object) {
        if (closing) return;
        Object target = object.match!((LuaTable t) => cast(Object)t, (LuaUserData u) => cast(Object)u, _ => cast(Object)null);
        if (target is null) return;
        size_t key = hideReference(target);
        if (key in finalizerMarked) return;
        finalizerMarked[key] = true;
        import dlua.gc : stackHygiene;
        stackHygiene = true;
        finalizers ~= object;
    }

    /// Runs pending finalizers in reverse order of marking (lua_close).
    void close() {
        import dlua.vm : VM;
        closing = true;
        inFinalizer = true;
        while (finalizers.length) {
            auto object = finalizers[$ - 1];
            finalizers.length--;
            auto mt = getMetatable(object);
            auto gc = mt is null ? luaNil() : mt.rawget(LuaValue("__gc"));
            if (!isFunction(gc)) continue;
            try { VM.callValue(this, gc, [object]); }
            catch (LuaException e) {
                string text = isString(e.errorObject) ? toLuaString(e.errorObject) : "error object is not a string";
                warning("error in ", true); warning("__gc", true); warning(" (", true); warning(text, true); warning(")", false);
            }
        }
        inFinalizer = false;
    }

    // Symbol interning pool shared across state
    string[string] symbolPool;

    LuaValue getSymbol(string name) {
        if (auto p = name in symbolPool) {
            return LuaValue(Symbol(*p));
        }
        symbolPool[name] = name;
        return LuaValue(Symbol(name));
    }

    // Call stack for arguments / results
    LuaValue[] stack;
    private CallInfo[] mainCallStack;
    @property ref CallInfo[] callStack() {
        import dlua.fiber : DluaFiber;
        if (auto fiber = cast(DluaFiber)Fiber.getThis()) return fiber.callStack;
        return mainCallStack;
    }

    CallInfo[] mainStack() { return mainCallStack; }

    LuaThread currentThread() {
        import dlua.fiber : DluaFiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
        return fiber is null ? mainThread : fiber.thread;
    }

    void dispatchError(LuaException error) {
        auto thread = currentThread();
        if (thread is null || !thread.errorBoundaries.length) return;
        auto boundary = thread.errorBoundaries[$ - 1];
        if (!boundary.handlesErrors || boundary.active || error.processedBy is boundary) return;
        import dlua.vm : VM;
        import dlua.fiber : DluaFiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
        bool previous = fiber !is null && fiber.isYieldAllowed;
        if (fiber !is null) fiber.isYieldAllowed = false;
        boundary.active = true;
        scope(exit) {
            boundary.active = false;
            if (fiber !is null) fiber.isYieldAllowed = previous && !fiber.closing;
        }
        try {
            auto results = VM.callValue(this, boundary.handler, [error.errorObject]);
            error.errorObject = results.length ? results[0] : luaNil();
        } catch (Exception) {
            error.errorObject = LuaValue("error in error handling");
        }
        error.msg = toLuaString(error.errorObject);
        error.needsLocation = false;
        error.processedBy = boundary;
    }

    string locationPrefix(int level) {
        auto frames = callStack;
        long index = cast(long)frames.length - 1 - level;
        if (level < 0 || index < 0 || index >= frames.length || frames[index].currentLine <= 0) return "";
        import std.conv : to;
        return shortSourceName(frames[index].source) ~ ":" ~ frames[index].currentLine.to!string ~ ": ";
    }

    void debugHook(string event, int line = -1, LuaValue[] transfer = null, bool hasTransfer = false) {
        auto thread = currentThread();
        if (thread is null || thread.hookFunction is null || thread.hookActive) return;
        int mask = event == "call" || event == "tail call" ? 1 : event == "return" ? 2 : event == "line" ? 4 : 8;
        if (!(thread.hookMask & mask)) return;
        import dlua.vm : VM;
        import dlua.fiber : DluaFiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
        bool previous = fiber !is null && fiber.isYieldAllowed;
        thread.hookActive = true;
        size_t hookedDepth = callStack.length;
        if (hasTransfer && hookedDepth > 0) {
            callStack[hookedDepth - 1].transfer = transfer;
            callStack[hookedDepth - 1].ftransfer = 1;
            callStack[hookedDepth - 1].transferIsReturn = event == "return";
        }
        scope(exit) if (hasTransfer && hookedDepth > 0 && callStack.length >= hookedDepth) {
            callStack[hookedDepth - 1].transfer = null;
            callStack[hookedDepth - 1].ftransfer = 0;
        }
        if (fiber !is null) fiber.isYieldAllowed = false;
        scope(exit) {
            thread.hookActive = false;
            if (fiber !is null) fiber.isYieldAllowed = previous && !fiber.closing;
        }
        VM.callValue(this, LuaValue(thread.hookFunction), [LuaValue(event), line >= 0 ? LuaValue(line) : luaNil()], false, "?", "hook");
    }

    void pushCall(LuaFunction fn, string source = "", int line = 1, bool tailCall = false, string name = "", string nameKind = "") {
        callStack ~= CallInfo(fn, source, line, tailCall, name, nameKind);
    }

    void popCall() {
        if (callStack.length > 0) {
            callStack[$ - 1] = CallInfo.init;
            callStack = callStack[0 .. $ - 1];
        }
    }

    import dlua.logic.world : World, wrapWorld;
    World globalWorld;
    void delegate(World) configureWorld;
    import dlua.narrative.registry : ContentRegistry;
    ContentRegistry narrativeRegistry;

    this() {
        this.mainThread = new LuaThread();
        this.mainThread.status = "running";
        guardOperatingSystemStack();
        this.globals = new LuaTable();
        this.registry = new LuaTable();
        this.globalWorld = new World();

        // Standard self-reference _G = _G
        this.globals.rawset(LuaValue("_G"), LuaValue(globals));
        this.globals.rawset(LuaValue("_VERSION"), LuaValue("Lua 5.4"));
    }

    /// When running on a plain OS thread (not a fiber), derive stack limits from the
    /// stack size so deep recursion raises a Lua error instead of overflowing.
    private void guardOperatingSystemStack() {
        if (Fiber.getThis() !is null) return;
        import core.sys.posix.sys.resource : getrlimit, rlimit, RLIMIT_STACK, RLIM_INFINITY;
        size_t marker;
        rlimit limit;
        size_t size = 8UL * 1024 * 1024;
        if (getrlimit(RLIMIT_STACK, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur > 1024 * 1024)
            size = cast(size_t)limit.rlim_cur;
        if (size > 1UL << 30) size = 1UL << 30;
        mainThread.nativeStackLimit = cast(size_t)&marker - size + 256 * 1024;
        mainThread.nativeSoftLimit = mainThread.nativeStackLimit + 1024 * 1024;
    }

    /// Set a global variable
    void setGlobal(string name, LuaValue val) {
        globals.rawset(LuaValue(name), val);
    }

    /// Get a global variable
    LuaValue getGlobal(string name) {
        return globals.rawget(LuaValue(name));
    }

    /// Register a native D function as a global
    void registerGlobal(string name, LuaNativeFunction.NativeDelegate fn) {
        globals.rawset(LuaValue(name), LuaValue(new LuaNativeFunction(fn, name)));
    }

    /// Push value onto the evaluation stack
    void push(LuaValue val) {
        stack ~= val;
    }

    /// Pop value from the evaluation stack
    LuaValue pop() {
        if (stack.length == 0) return luaNil();
        auto val = stack[$ - 1];
        stack = stack[0 .. $ - 1];
        return val;
    }

    /// Get the number of elements on the stack
    size_t getTop() const {
        return stack.length;
    }

    /// Set stack top
    void setTop(size_t newTop) {
        if (newTop < stack.length) {
            stack = stack[0 .. newTop];
        } else {
            while (stack.length < newTop) {
                stack ~= luaNil();
            }
        }
    }

    LuaTable nilMetatable, booleanMetatable, functionMetatable, threadMetatable, lightUserDataMetatable;

    /// Get metatable for a given value, respecting type-level metatables
    LuaTable getMetatable(LuaValue val) {
        final switch (val.typeOf()) {
            case LuaType.Table: return val.match!((LuaTable t) => t.metatable, _ => cast(LuaTable)null);
            case LuaType.UserData: return val.match!((LuaUserData u) => u.metatable, _ => cast(LuaTable)null);
            case LuaType.String: return stringMetatable;
            case LuaType.Number: return numberMetatable;
            case LuaType.Nil: return nilMetatable;
            case LuaType.Boolean: return booleanMetatable;
            case LuaType.Function: return functionMetatable;
            case LuaType.Thread: return threadMetatable;
            case LuaType.LightUserData: return lightUserDataMetatable;
            case LuaType.Symbol: return null;
        }
    }

    /// Set metatable for a given value
    void setMetatable(LuaValue val, LuaTable mt) {
        final switch (val.typeOf()) {
            case LuaType.Table: val.match!((LuaTable t) { t.metatable = mt; }, (_) {}); break;
            case LuaType.UserData: val.match!((LuaUserData u) { u.metatable = mt; }, (_) {}); break;
            case LuaType.String: stringMetatable = mt; break;
            case LuaType.Number: numberMetatable = mt; break;
            case LuaType.Nil: nilMetatable = mt; break;
            case LuaType.Boolean: booleanMetatable = mt; break;
            case LuaType.Function: functionMetatable = mt; break;
            case LuaType.Thread: threadMetatable = mt; break;
            case LuaType.LightUserData: lightUserDataMetatable = mt; break;
            case LuaType.Symbol: throw new LuaException("cannot set metatable on this type");
        }
    }

    /// Perform a protected call (pcall) on a function
    struct PCallResult {
        bool success;
        LuaValue[] results;
        LuaValue error;
    }

    PCallResult pcall(LuaFunction fn, LuaValue[] args) {
        import dlua.fiber : DluaFiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
        if (fiber !is null) fiber.protectedDepth++;
        scope(exit) if (fiber !is null) fiber.protectedDepth--;
        auto thread = currentThread();
        if (thread !is null) thread.errorBoundaries ~= new ErrorBoundary(false);
        scope(exit) if (thread !is null) { thread.errorBoundaries[$ - 1] = null; thread.errorBoundaries.length--; }
        if (fn is null) {
            return PCallResult(false, [], LuaValue("attempt to call a nil value"));
        }

        try {
            auto res = fn.call(cast(void*)this, args);
            return PCallResult(true, res, luaNil());
        } catch (LuaException e) {
            return PCallResult(false, [], e.errorObject);
        } catch (Exception e) {
            return PCallResult(false, [], LuaValue(e.msg));
        }
    }

    /// Parse, compile, and return a callable Lua function from source code
    LuaFunction loadString(string code, string sourceName = "=stdin") {
        import dlua.parser : Parser;
        import dlua.compiler : Compiler;
        import dlua.vm : LuaClosure, UpValue;

        auto parser = new Parser(code, sourceName);
        auto ast = parser.parse();
        auto compiler = new Compiler(null, "main");
        import dlua.opcode : Prototype;
        Prototype proto;
        try { proto = compiler.compileChunk(ast, sourceName); }
        catch (LuaException error) { error.locate(sourceName, compiler.currentLine); throw error; }
        auto environment = new UpValue(null, -1);
        environment.closedVal = LuaValue(globals);
        environment.isClosed = true;
        return new LuaClosure(proto, [environment]);
    }

    /// Load and immediately execute Lua source code
    LuaValue[] doString(string code, string sourceName = "=stdin") {
        auto fn = loadString(code, sourceName);
        return fn.call(cast(void*)this, []);
    }
}
