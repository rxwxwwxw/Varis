/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.fiber;

import dlua.types;
import dlua.state : CallInfo;
import dlua.logic.world : isReadOnlyEvaluation, isNotificationDispatch, isNoYieldScope;
import dlua.exception : LuaException;
import core.thread : Fiber;
import dlua.logic.world : World;

// Internal unwinding signal bypasses Lua protected calls when a thread is closed.
class CoroutineClose : Throwable {
    LuaValue errorObject;
    bool failed;
    this(LuaValue error = LuaValue.init, bool failed = false) {
        super("coroutine close");
        this.errorObject = error;
        this.failed = failed;
    }
}

/// The Lua coroutine currently executing, or null on the main interpreter fiber. Maintained by
/// `callFiber` around every resume, so lookups avoid thread-local access and class casts.
__gshared DluaFiber activeLuaFiber;

pragma(inline, true)
DluaFiber currentLuaFiber() {
    return activeLuaFiber;
}

/// Runs `fiber` until it yields or finishes, tracking it as the active Lua coroutine.
void callFiber(DluaFiber fiber) {
    auto previous = activeLuaFiber;
    activeLuaFiber = fiber;
    scope (exit)
        activeLuaFiber = previous;
    fiber.call();
}

/// Coroutine runner wrapping D's core.thread.Fiber
class DluaFiber : Fiber {
    LuaFunction targetFunction;
    LuaThread thread;
    CallInfo[] callStack;
    CallInfo[] callStackStorage; // capacity retained across calls; inactive records are cleared
    World callWorld; // lexical world of the call in progress (see VM.doCall)
    void* luaStatePtr;

    LuaValue[] resumeArgs;
    LuaValue[] yieldResults;
    LuaValue[] returnResults;
    string errorMessage;
    LuaValue errorObject;
    bool hasError;
    bool isYieldAllowed = true;
    bool started;
    bool closing;
    size_t protectedDepth;

    private size_t fiberStackSize;

    this(LuaFunction fn, void* luaState, size_t stackSize = 256UL * 1024 * 1024) {
        super(&run, stackSize);
        fiberStackSize = stackSize;
        this.targetFunction = fn;
        this.luaStatePtr = luaState;
        this.hasError = false;
        this.isYieldAllowed = true;
    }

    private void run() {
        started = true;
        size_t marker;
        if (thread !is null) {
            thread.nativeStackLimit = cast(size_t)&marker - fiberStackSize + 512 * 1024;
            thread.nativeSoftLimit = cast(size_t)&marker - fiberStackSize + 16UL * 1024 * 1024;
        }
        try {
            import dlua.vm : VM;
            import dlua.state : LuaState;

            returnResults = VM.callValue(cast(LuaState) luaStatePtr, LuaValue(targetFunction), resumeArgs, false, "", "", true);
        } catch (CoroutineClose signal) {
            hasError = signal.failed;
            errorObject = signal.errorObject;
        } catch (LuaException e) {
            hasError = true;
            errorMessage = e.msg;
            errorObject = e.errorObject;
            if (!closing)
                Fiber.yield();
        } catch (Exception e) {
            hasError = true;
            errorMessage = e.msg;
            errorObject = LuaValue(e.msg);
            if (!closing)
                Fiber.yield();
        }
    }

    // Keep an unprotected Lua error's frames live until explicit close.
    void suspendError(LuaValue error) {
        hasError = true;
        errorObject = error;
        Fiber.yield();
    }

    LuaValue[] closeThread() {
        closing = true;
        isYieldAllowed = false;
        if (thread !is null)
            thread.status = "running";
        if (started && state != Fiber.State.TERM)
            callFiber(this);
        if (thread !is null)
            thread.status = "dead";
        auto result = hasError ? [LuaValue(false), errorObject] : [LuaValue(true)];
        hasError = false;
        errorObject = luaNil();
        resumeArgs = [];
        yieldResults = [];
        returnResults = [];
        closing = false;
        isYieldAllowed = true;
        return result;
    }

    /// Yield from inside the running fiber
    void yieldExecution(LuaValue[] results) {
        if (!isYieldAllowed || isNoYieldScope() || isReadOnlyEvaluation() || isNotificationDispatch()) {
            throw new LuaException("attempt to yield across a C-call boundary");
        }
        this.yieldResults = results;
        Fiber.yield();
        if (closing)
            throw new CoroutineClose();
    }
}
