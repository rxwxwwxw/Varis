/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.fiber;

import varis.types;
import varis.state : CallInfo;
import varis.exception : LuaException;
import core.thread : Fiber;

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
// Execution scopes. They are core concepts (where a coroutine may yield, where state may be
// written); the world model and the narrative runtime open and close them.
private __gshared size_t readOnlyEvaluations; // one interpreter thread; thread-local access is slow on macOS
private __gshared size_t notificationDepth; // one interpreter thread; thread-local access is slow on macOS
// Dynamic no-yield scopes include helpers and synchronously resumed coroutines.
private __gshared size_t noYieldDepth; // one interpreter thread; thread-local access is slow on macOS
void beginNoYieldScope() {
    noYieldDepth++;
}

void endNoYieldScope() {
    assert(noYieldDepth);
    noYieldDepth--;
}

bool isNoYieldScope() {
    return noYieldDepth != 0;
}

void beginNotificationDispatch() {
    notificationDepth++;
}

void endNotificationDispatch() {
    assert(notificationDepth);
    notificationDepth--;
}

bool isNotificationDispatch() {
    return notificationDepth != 0;
}

void beginReadOnlyEvaluation() {
    readOnlyEvaluations++;
}

void endReadOnlyEvaluation() {
    assert(readOnlyEvaluations > 0);
    readOnlyEvaluations--;
}

bool isReadOnlyEvaluation() {
    return readOnlyEvaluations != 0;
}

__gshared VarisFiber activeLuaFiber;

pragma(inline, true)
VarisFiber currentLuaFiber() {
    return activeLuaFiber;
}

/// Runs `fiber` until it yields or finishes, tracking it as the active Lua coroutine.
void callFiber(VarisFiber fiber) {
    auto previous = activeLuaFiber;
    activeLuaFiber = fiber;
    scope (exit)
        activeLuaFiber = previous;
    fiber.call();
}

/// Coroutine runner wrapping D's core.thread.Fiber
class VarisFiber : Fiber {
    LuaFunction targetFunction;
    LuaThread thread;
    CallInfo[] callStack;
    CallInfo[] callStackStorage; // capacity retained across calls; inactive records are cleared
    Object callWorld; // lexical world of the call in progress (see VM.doCall); a logic.world.World
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
            import varis.vm : VM;
            import varis.state : LuaState;

            auto owner = cast(LuaState) luaStatePtr;
            auto results = VM.callValue(owner, LuaValue(targetFunction), resumeArgs, false, "", "", true, true);
            if (owner.raisedError !is null) {
                // The body failed: its error came back as a value.
                auto e = owner.takeRaised();
                hasError = true;
                errorMessage = e.msg;
                errorObject = e.errorObject;
                if (!closing)
                    Fiber.yield();
            } else
                returnResults = results;
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
    /// False, with nothing yielded, when the running code may not yield (the caller reports the
    /// "attempt to yield across a C-call boundary" error). A close request still unwinds by
    /// `CoroutineClose`: it must cross the native frames of this fiber.
    bool yieldExecution(LuaValue[] results) {
        if (!isYieldAllowed || isNoYieldScope() || isReadOnlyEvaluation() || isNotificationDispatch())
            return false;
        this.yieldResults = results;
        Fiber.yield();
        if (closing)
            throw new CoroutineClose();
        return true;
    }
}
