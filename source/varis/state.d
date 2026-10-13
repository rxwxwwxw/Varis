/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.state;

import varis.types;
import varis.opcode : Instruction;
import varis.table;
import varis.exception;
import core.thread : Fiber;

import varis.vm : LuaClosure;

/// A scope a frame opened and must close when control leaves it (a `transaction ... do` block).
/// Defined here so the executor can hold one without importing the world model.
interface FrameScope {
    void finish(bool commit);
}

/// Called with every new state, so upper layers can attach their per-state objects (registered
/// from module constructors; the core does not import those layers).
__gshared void function(LuaState)[] stateCreatedHooks;

struct CallInfo {
    LuaFunction fn;
    string source;
    int currentLine;
    bool tailCall;
    string name;
    string nameKind;
    // Values transferred by the call/return being hooked (debug.getinfo "r").
    LuaValue[] transfer;
    int ftransfer;
    bool transferIsReturn;

    // Execution context for active Lua frames (null for C functions)
    LuaValue[]* registers;
    LuaValue[]* varargs;
    const(Instruction)** pc; // address of the frame's instruction pointer (next to execute)
    int* debugLimit;

    // For C functions
    LuaValue[] cArgs;

    /// Index of the next instruction of an active Lua frame (0 when unknown).
    int pcValue() {
        if (pc is null)
            return 0;
        auto closure = cast(LuaClosure) fn;
        if (closure is null)
            return 0;
        return cast(int)(*pc - closure.proto.execCode.ptr);
    }

    /// Line being executed: derived from the live program counter for active Lua frames, so the
    /// interpreter loop does not have to publish it on every instruction.
    int line() {
        if (pc !is null && registers !is null) {
            auto closure = cast(LuaClosure) fn;
            if (closure !is null) {
                int position = pcValue();
                auto code = closure.proto.execCode;
                size_t index = position > 0 ? position - 1 : 0;
                if (index < code.length && code[index].line > 0)
                    return code[index].line;
                if (code.length == 0)
                    return 1;
            }
        }
        return currentLine;
    }

    string getLocal(long index, out LuaValue value) {
        if (registers is null) {
            if (index <= 0 || index > cArgs.length)
                return null;
            value = cArgs[cast(size_t)(index - 1)];
            return "(C temporary)";
        }
        auto closure = cast(LuaClosure) fn;
        if (closure is null)
            return null;
        auto proto = closure.proto;
        int curPc = pcValue();
        int limit = debugLimit !is null ? *debugLimit : proto.maxStackSize;
        int targetPc = curPc > 0 ? curPc - 1 : 0;
        if (index < 0) {
            if (!proto.isVararg || varargs is null || index < -cast(long)(*varargs).length)
                return null;
            size_t slot = cast(size_t)(-index - 1);
            value = (*varargs)[slot];
            return "(vararg)";
        }
        if (index == 0)
            return null;
        long remaining = index;
        foreach (local; proto.debugLocals) {
            if (local.startPC <= targetPc && targetPc < local.endPC && (local.name.length == 0 || local.name[0] != '@')) {
                if (--remaining == 0) {
                    value = (*registers)[local.register];
                    return local.name;
                }
            }
        }
        if (index <= limit) {
            int slot = cast(int) index - 1;
            foreach (local; proto.debugLocals) {
                if (local.register == slot && local.name.length && local.name[0] == '@' &&
                        local.startPC <= targetPc && targetPc < local.endPC)
                    return null;
            }
            value = (*registers)[slot];
            return "(temporary)";
        }
        return null;
    }

    string setLocal(long index, LuaValue value) {
        if (registers is null) {
            if (index <= 0 || index > cArgs.length)
                return null;
            cArgs[cast(size_t)(index - 1)] = value;
            return "(C temporary)";
        }
        auto closure = cast(LuaClosure) fn;
        if (closure is null)
            return null;
        auto proto = closure.proto;
        int curPc = pcValue();
        int limit = debugLimit !is null ? *debugLimit : proto.maxStackSize;
        int targetPc = curPc > 0 ? curPc - 1 : 0;
        if (index < 0) {
            if (!proto.isVararg || varargs is null || index < -cast(long)(*varargs).length)
                return null;
            size_t slot = cast(size_t)(-index - 1);
            (*varargs)[slot] = value;
            return "(vararg)";
        }
        if (index == 0)
            return null;
        long remaining = index;
        foreach (local; proto.debugLocals) {
            if (local.startPC <= targetPc && targetPc < local.endPC && (local.name.length == 0 || local.name[0] != '@')) {
                if (--remaining == 0) {
                    if (local.readOnly)
                        throw new LuaException("attempt to modify read-only narrative parameter '" ~ local.name ~ "'");
                    (*registers)[local.register] = value;
                    return local.name;
                }
            }
        }
        if (index <= limit) {
            int slot = cast(int) index - 1;
            foreach (local; proto.debugLocals) {
                if (local.register == slot && local.name.length && local.name[0] == '@' &&
                        local.startPC <= targetPc && targetPc < local.endPC)
                    return null;
            }
            (*registers)[slot] = value;
            return "(temporary)";
        }
        return null;
    }

    void clearDead() {
        if (registers is null)
            return;
        auto closure = cast(LuaClosure) fn;
        if (closure is null)
            return;
        auto proto = closure.proto;
        int curPc = pcValue();
        int limit = curPc > 0 && curPc <= proto.liveTop.length ? proto.liveTop[curPc - 1] : int.max;
        if (limit == int.max)
            return;
        foreach (i; limit .. (*registers).length)
            (*registers)[i] = luaNil();
    }
}

/// Shared only among isolated analysis branches, never with the live state.
class AnalysisBudget {
    size_t remaining;
    size_t remainingObjects = 200_000;
    string[] blockedEffects;
    this(size_t instructions) {
        remaining = instructions;
    }
}

/// Set whenever the interpreter loop has something unusual to look at before the next
/// instruction (pending collection, interrupt, hooks, analysis budget). The loop tests this one
/// flag per instruction and does the detailed checks only when it is set.
__gshared bool vmAttention;

/// Some hook or instruction budget may be active, so the instrumented loop stays on. It is set
/// by `enterSlowMode` and cleared by `leaveSlowModeIfIdle` once nothing asks for it any more.
__gshared bool vmSlowMode;

/// What keeps slow mode on: threads that have a hook mask (counted once each, see
/// `syncThreadHook`), analyses in progress, and a debugger request made from another thread that
/// the executing thread has not consumed yet.
__gshared int vmHookedThreads;
/// ditto
__gshared int vmActiveAnalyses;
/// ditto
__gshared bool vmDebuggerHold;

/// Reports `error` as the result of the running native function: `return raise(state, error);`.
/// The returned (empty) result is never looked at.
LuaValue[] raise(LuaState state, LuaException error) nothrow @nogc {
    state.raisedError = error;
    return null;
}

/// ditto
LuaValue[] raise(LuaState state, string message) {
    return raise(state, new LuaException(message));
}

void enterSlowMode() @nogc nothrow {
    vmSlowMode = true;
    vmAttention = true;
}

/// Running frames notice at their next instruction and go back to the fast loop.
void leaveSlowModeIfIdle() @nogc nothrow {
    if (vmHookedThreads == 0 && vmActiveAnalyses == 0 && !vmDebuggerHold)
        vmSlowMode = false;
}

/// Call after changing a thread's hook mask (from the thread that runs the interpreter). A
/// thread collected while it still has a mask stays counted, which only keeps slow mode on.
void syncThreadHook(LuaThread thread) @nogc nothrow {
    bool hooked = thread.hookMask != 0;
    if (hooked != thread.hookCounted) {
        vmHookedThreads += hooked ? 1 : -1;
        thread.hookCounted = hooked;
    }
    if (hooked)
        enterSlowMode();
    else
        leaveSlowModeIfIdle();
}

/// Central runtime state for Lua execution
/// The tier policy of a project (milestone 26), installed by a host that read its manifest. Called
/// with each source file about to be loaded from disk (`require`, `dofile`, `loadfile`). Returns
/// the reason the file may not be loaded, or "" to allow it; sets `environment` to the table the
/// chunk must run with (its `_ENV`), or leaves it nil for the full language.
alias FileTierHook = string delegate(string path, string source, ref LuaValue environment);

class LuaState {
    bool gcRunning = true;
    FileTierHook fileTierHook;
    LuaFunction errorFunction; // the builtin `error`, raised directly by the interpreter
    LuaFunction fastNext; // the builtin `next`, recognized by the generic-for fast path
    LuaFunction fastIpairsIter; // the iterator function returned by `ipairs`
    LuaThread mainThread;
    string[LuaFunction] standardNativePaths;
    LuaFunction[string] standardNativeFunctions;
    AnalysisBudget analysisBudget;
    Object logicCache; // owned by varis.logic.evaluate (derived relations per closure)
    // Per-Fiber so a suspended ordinary coroutine cannot leak its call context.
    Object mainCallWorld;

    /// Errors as values (performance plan, stage L1). A native reports an error by storing it
    /// here and returning (`return raise(state, error)`); whoever called the native takes it
    /// before doing anything else. The executor turns it into the frame's error without a D
    /// throw; `LuaNativeFunction.call` throws it for callers that still expect exceptions.
    LuaException raisedError;

    final LuaException takeRaised() {
        import varis.exception : ExitSignal, ExitRequest;

        auto error = raisedError;
        raisedError = null;
        if (auto exit = cast(ExitSignal) error)
            throw new ExitRequest(exit.status);
        return error;
    }
    /// Called once per raised Lua error, in the innermost Lua frame, while the frame and its
    /// callers are still alive (before unwinding). Tools use it to stop on errors; it must not
    /// change execution state other than by running to completion.
    void delegate(LuaState, LuaException) errorStopHook;

    /// The lexical world of the call in progress, as an opaque reference: the core carries it
    /// from call sites to natives without knowing its type (varis.logic.world gives it one).
    final Object callWorldObject() {
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        return fiber is null ? mainCallWorld : fiber.callWorld;
    }

    /// ditto
    final void callWorldObject(Object world) {
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        if (fiber is null)
            mainCallWorld = world;
        else
            fiber.callWorld = world;
    }

    LuaTable globals;
    LuaTable registry;
    LuaTable stringMetatable;
    LuaTable numberMetatable;

    // Finalizers (__gc) run at state close; D's collector cannot call back into Lua.
    LuaValue[] finalizers;
    bool[size_t] finalizerMarked; // keyed by hidden references (a plain pointer key would keep the object alive)
    bool closing;
    bool inFinalizer;
    bool inGcCycle;
    private bool pendingCollectFlag;
    @property bool pendingCollect() const {
        return pendingCollectFlag;
    }

    @property void pendingCollect(bool value) {
        pendingCollectFlag = value;
        if (value)
            vmAttention = true;
    }

    double gcStepProgress; // work done towards the current emulated collection cycle (KB)
    LuaValue[] stashedResults; // call results waiting for the register array to grow
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
            if (message == "@on")
                warnOn = true;
            else if (message == "@off")
                warnOn = false;
            return;
        }
        if (warnOn) {
            if (!warnContinued)
                fputs("Lua warning: ", stderr);
            fwrite(message.ptr, 1, message.length, stderr);
            if (!tocont)
                fputs("\n", stderr);
            fflush(stderr);
        }
        warnContinued = tocont;
    }

    /// Counts allocations; periodically runs a collection cycle so weak tables and
    /// finalizers behave as with an incremental collector.
    pragma(inline, true)
    void allocationTick() {
        if (++allocTicks >= gcThreshold) {
            import varis.gc : gcTick;

            gcTick(this);
        }
    }

    /// Registers an object whose metatable defines __gc.
    void markForFinalization(LuaValue object) {
        if (closing)
            return;
        Object target = object.match!((LuaTable t) => cast(Object) t, (LuaUserData u) => cast(Object) u, _ => cast(
                Object) null);
        if (target is null)
            return;
        size_t key = hideReference(target);
        if (key in finalizerMarked)
            return;
        finalizerMarked[key] = true;
        import varis.gc : stackHygiene;

        stackHygiene = true;
        finalizers ~= object;
    }

    /// Runs pending finalizers in reverse order of marking (lua_close).
    void close() {
        import varis.vm : VM;

        closing = true;
        inFinalizer = true;
        while (finalizers.length) {
            auto object = finalizers[$ - 1];
            finalizers.length--;
            auto mt = getMetatable(object);
            auto gc = mt is null ? luaNil() : mt.rawget(LuaValue("__gc"));
            if (!isFunction(gc))
                continue;
            try {
                VM.callValue(this, gc, [object]);
            } catch (LuaException e) {
                string text = isString(e.errorObject) ? toLuaString(e.errorObject) : "error object is not a string";
                warning("error in ", true);
                warning("__gc", true);
                warning(" (", true);
                warning(text, true);
                warning(")", false);
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
    private CallInfo[] mainCallStackStorage;
    final @property ref CallInfo[] callStack() {
        import varis.fiber : VarisFiber, currentLuaFiber;

        if (auto fiber = currentLuaFiber())
            return fiber.callStack;
        return mainCallStack;
    }

    CallInfo[] mainStack() {
        return mainCallStack;
    }

    final LuaThread currentThread() {
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        return fiber is null ? mainThread : fiber.thread;
    }

    void dispatchError(LuaException error) {
        auto thread = currentThread();
        if (thread is null || !thread.errorBoundaries.length)
            return;
        auto boundary = thread.errorBoundaries[$ - 1];
        if (!boundary.handlesErrors || boundary.active || error.processedBy is boundary)
            return;
        import varis.vm : VM;
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        bool previous = fiber !is null && fiber.isYieldAllowed;
        if (fiber !is null)
            fiber.isYieldAllowed = false;
        boundary.active = true;
        scope (exit) {
            boundary.active = false;
            if (fiber !is null)
                fiber.isYieldAllowed = previous && !fiber.closing;
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
        long index = cast(long) frames.length - 1 - level;
        if (level < 0 || index < 0 || index >= frames.length || frames[index].line <= 0)
            return "";
        import std.conv : to;

        return shortSourceName(frames[index].source) ~ ":" ~ frames[index].line.to!string ~ ": ";
    }

    void debugHook(string event, int line = -1, LuaValue[] transfer = null, bool hasTransfer = false) {
        auto thread = currentThread();
        if (thread is null || thread.hookFunction is null || thread.hookActive)
            return;
        int mask = event == "call" || event == "tail call" ? 1 : event == "return" ? 2 : event == "line" ? 4 : 8;
        if (!(thread.hookMask & mask))
            return;
        import varis.vm : VM;
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        bool previous = fiber !is null && fiber.isYieldAllowed;
        thread.hookActive = true;
        size_t hookedDepth = callStack.length;
        if (hasTransfer && hookedDepth > 0) {
            callStack[hookedDepth - 1].transfer = transfer;
            callStack[hookedDepth - 1].ftransfer = 1;
            callStack[hookedDepth - 1].transferIsReturn = event == "return";
        }
        scope (exit)
            if (hasTransfer && hookedDepth > 0 && callStack.length >= hookedDepth) {
                callStack[hookedDepth - 1].transfer = null;
                callStack[hookedDepth - 1].ftransfer = 0;
            }
        if (fiber !is null)
            fiber.isYieldAllowed = false;
        scope (exit) {
            thread.hookActive = false;
            if (fiber !is null)
                fiber.isYieldAllowed = previous && !fiber.closing;
        }
        VM.callValue(this, LuaValue(thread.hookFunction), [
            LuaValue(event), line >= 0 ? LuaValue(line) : luaNil()
        ], false, "?", "hook");
    }

    final void pushCall(LuaFunction fn, string source = "", int line = 1, bool tailCall = false, string name = "", string nameKind = "",
            LuaValue[]* registers = null, LuaValue[]* varargs = null, const(Instruction)** pc = null, int* debugLimit = null) {
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        auto active = fiber is null ? &mainCallStack : &fiber.callStack;
        auto storage = fiber is null ? &mainCallStackStorage : &fiber.callStackStorage;
        size_t depth = (*active).length;
        if (depth == (*storage).length) {
            // Explicit capacity avoids D append's alias-preserving allocation
            // after popCall shortens the active slice. No inactive record roots
            // Lua objects or frame delegates.
            (*storage).length = depth ? depth * 2 : 16;
        }
        // Inactive records are always CallInfo.init (see popCall), so fields are set in place.
        auto ci = &(*storage)[depth];
        ci.fn = fn;
        ci.source = source;
        ci.currentLine = line;
        ci.tailCall = tailCall;
        ci.name = name;
        ci.nameKind = nameKind;
        ci.registers = registers;
        ci.varargs = varargs;
        ci.pc = pc;
        ci.debugLimit = debugLimit;
        *active = (*storage)[0 .. depth + 1];
    }

    final void popCall() {
        auto active = &callStack();
        if ((*active).length > 0) {
            // Inactive records must not root Lua objects. Strings, the line and the flags are
            // plain data that pushCall overwrites, so only references are cleared here.
            auto ci = &(*active)[$ - 1];
            ci.fn = null;
            ci.registers = null;
            ci.varargs = null;
            ci.pc = null;
            ci.debugLimit = null;
            ci.transfer = null;
            ci.ftransfer = 0;
            ci.transferIsReturn = false;
            ci.cArgs = null;
            *active = (*active)[0 .. $ - 1];
        }
    }

    // Per-state objects of the layers above the core, kept as opaque references. Their typed
    // accessors are free functions in the owning modules (varis.logic.world: globalWorld,
    // callWorld, configureWorld; varis.narrative.registry: narrativeRegistry).
    Object globalWorldObject;
    Object worldConfigurationObject;
    Object narrativeRegistryObject;

    this() {
        this.mainThread = new LuaThread();
        this.mainThread.status = "running";
        guardOperatingSystemStack();
        this.globals = new LuaTable();
        this.registry = new LuaTable();
        foreach (hook; stateCreatedHooks)
            hook(this);

        // Standard self-reference _G = _G
        this.globals.rawset(LuaValue("_G"), LuaValue(globals));
        this.globals.rawset(LuaValue("_VERSION"), LuaValue("Lua 5.4"));
    }

    /// When running on a plain OS thread (not a fiber), derive stack limits from the
    /// stack size so deep recursion raises a Lua error instead of overflowing.
    private void guardOperatingSystemStack() {
        if (Fiber.getThis() !is null)
            return;
        import core.sys.posix.sys.resource : getrlimit, rlimit, RLIMIT_STACK, RLIM_INFINITY;

        size_t marker;
        rlimit limit;
        size_t size = 8UL * 1024 * 1024;
        if (getrlimit(RLIMIT_STACK, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur > 1024 * 1024)
            size = cast(size_t) limit.rlim_cur;
        if (size > 1UL << 30)
            size = 1UL << 30;
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
        if (stack.length == 0)
            return luaNil();
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
        case LuaType.Table:
            return val.match!((LuaTable t) => t.metatable, _ => cast(LuaTable) null);
        case LuaType.UserData:
            return val.match!((LuaUserData u) => u.metatable, _ => cast(LuaTable) null);
        case LuaType.String:
            return stringMetatable;
        case LuaType.Number:
            return numberMetatable;
        case LuaType.Nil:
            return nilMetatable;
        case LuaType.Boolean:
            return booleanMetatable;
        case LuaType.Function:
            return functionMetatable;
        case LuaType.Thread:
            return threadMetatable;
        case LuaType.LightUserData:
            return lightUserDataMetatable;
        case LuaType.Symbol:
            return null;
        }
    }

    /// Set metatable for a given value
    void setMetatable(LuaValue val, LuaTable mt) {
        final switch (val.typeOf()) {
        case LuaType.Table:
            val.match!((LuaTable t) { t.metatable = mt; }, (_) {});
            break;
        case LuaType.UserData:
            val.match!((LuaUserData u) { u.metatable = mt; }, (_) {});
            break;
        case LuaType.String:
            stringMetatable = mt;
            break;
        case LuaType.Number:
            numberMetatable = mt;
            break;
        case LuaType.Nil:
            nilMetatable = mt;
            break;
        case LuaType.Boolean:
            booleanMetatable = mt;
            break;
        case LuaType.Function:
            functionMetatable = mt;
            break;
        case LuaType.Thread:
            threadMetatable = mt;
            break;
        case LuaType.LightUserData:
            lightUserDataMetatable = mt;
            break;
        case LuaType.Symbol:
            throw new LuaException("cannot set metatable on this type");
        }
    }

    /// Perform a protected call (pcall) on a function
    struct PCallResult {
        bool success;
        LuaValue[] results;
        LuaValue error;
    }

    PCallResult pcall(LuaFunction fn, LuaValue[] args) {
        import varis.fiber : VarisFiber, currentLuaFiber;

        auto fiber = currentLuaFiber();
        if (fiber !is null)
            fiber.protectedDepth++;
        scope (exit)
            if (fiber !is null)
                fiber.protectedDepth--;
        auto thread = currentThread();
        if (thread !is null)
            thread.pushBoundary(false);
        scope (exit)
            if (thread !is null)
                thread.popBoundary();
        if (fn is null) {
            return PCallResult(false, [], LuaValue("attempt to call a nil value"));
        }

        try {
            auto res = fn.call(cast(void*) this, args);
            return PCallResult(true, res, luaNil());
        } catch (LuaException e) {
            return PCallResult(false, [], e.errorObject);
        } catch (Exception e) {
            return PCallResult(false, [], LuaValue(e.msg));
        }
    }

    /// Parse, compile, and return a callable Lua function from source code
    LuaFunction loadString(string code, string sourceName = "=stdin") {
        import varis.parser : Parser;
        import varis.compiler : Compiler;
        import varis.vm : LuaClosure, UpValue;

        auto parser = new Parser(code, sourceName);
        auto ast = parser.parse();
        auto compiler = new Compiler(null, "main");
        import varis.opcode : Prototype;

        Prototype proto;
        try {
            proto = compiler.compileChunk(ast, sourceName);
        } catch (LuaException error) {
            error.locate(sourceName, compiler.currentLine);
            throw error;
        }
        auto environment = new UpValue(null, -1);
        environment.closedVal = LuaValue(globals);
        environment.isClosed = true;
        return new LuaClosure(proto, [environment]);
    }

    /// Load and immediately execute Lua source code
    LuaValue[] doString(string code, string sourceName = "=stdin") {
        auto fn = loadString(code, sourceName);
        return fn.call(cast(void*) this, []);
    }
}
